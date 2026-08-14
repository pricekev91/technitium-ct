#!/bin/bash
set -e

# Configuration
CONTAINER_NAME="technitium"
LXC_ID="102"
PROX_HOST="192.168.1.10"
CONTAINER_IP="192.168.1.2"

# /srv/data is mounted into the LXC (mp0) — use it as the shared config bridge.
# Config files go here on the host; docker-compose mounts them into the container at /etc/dns.
SHARED_DIR="/srv/data/technitium"

# Detect repo path regardless of where script is run from
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PATH="$SCRIPT_DIR"

# Helper: run commands inside the LXC
lxc() { ssh root@${PROX_HOST} "pct exec ${LXC_ID} -- /bin/sh -c '$*'"; }

# Helper: run commands on the Proxmox host (not inside LXC)
prox() { ssh root@${PROX_HOST} "$*"; }

echo "============================================================"
echo "  Technitium DNS Server Deployment"
echo "  Target: LXC ${LXC_ID} on ${PROX_HOST}"
echo "============================================================"

# ---------------------------------------------------------------
# STEP 0: FREE PORT 53 (DISABLE SYSTEMD-RESOLVED)
# ---------------------------------------------------------------
echo ""
echo "--- Step 0: Ensuring port 53 is free ---"
echo "  Disabling systemd-resolved to free port 53..."
# Stop the service (masking prevents auto-restart)
lxc "systemctl stop systemd-resolved" 2>/dev/null || true
lxc "systemctl disable systemd-resolved" 2>/dev/null || true
lxc "systemctl mask systemd-resolved" 2>/dev/null || true
# Also disable the stub listener in config (belt and suspenders)
lxc "sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf" 2>/dev/null || true
lxc "systemctl daemon-reload" 2>/dev/null || true
sleep 2

# Verify port 53 is actually free
echo "  Verifying port 53 is free..."
if lxc "ss -tlnup | grep ':53 ' 2>/dev/null" | grep -qv 'docker\|technitium'; then
    # Port 53 still occupied — try harder
    echo "  WARNING: port 53 still occupied — attempting forced release..."
    lxc "pkill -9 -f systemd-resolved" 2>/dev/null || true
    lxc "systemctl stop systemd-resolved" 2>/dev/null || true
    sleep 3
    if lxc "ss -tlnup | grep ':53 ' 2>/dev/null" | grep -qv 'docker\|technitium'; then
        echo "  ERROR: port 53 is STILL occupied. Container will fail to start."
        echo "  Please manually stop systemd-resolved inside the LXC and retry."
        exit 1
    fi
fi
echo "  OK: port 53 is free"

# ---------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------
echo ""
echo "--- Running pre-flight checks ---"

# 1. Check docker is available inside the LXC
echo "  [1/4] Checking docker is available..."
if ! lxc "docker --version" >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not in PATH inside LXC ${LXC_ID}."
    echo "       Install docker first: https://docs.docker.com/engine/install/"
    exit 1
fi
echo "      OK: docker found"

# 2. Check docker compose is available
echo "  [2/4] Checking docker compose is available..."
if ! lxc "docker compose version" >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin is not available inside LXC ${LXC_ID}."
    echo "       Install it first."
    exit 1
fi
echo "      OK: docker compose found"

# 3. Check connectivity to the Proxmox host
echo "  [3/4] Checking connectivity to ${PROX_HOST}..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@${PROX_HOST} "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot reach ${PROX_HOST}. Check SSH connectivity."
    exit 1
fi
echo "      OK: SSH to ${PROX_HOST} successful"

# 4. Check that port 53 is not already bound to the container's dedicated IP
echo "  [4/4] Checking that port 53 is free on ${CONTAINER_IP}..."
if prox "ss -tlnup | grep '${CONTAINER_IP}:53 ' 2>/dev/null" | grep -q .; then
    echo "WARNING: Port 53 on ${CONTAINER_IP} is already in use."
    read -r -p "  Continue anyway? [y/N] " choice
    case "$choice" in
        [yY]*) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
else
    echo "      OK: port 53 on ${CONTAINER_IP} is free"
fi

# ---------------------------------------------------------------
# STEP 1: BACKUP EXISTING CONFIG
# ---------------------------------------------------------------
echo ""
echo "--- Step 1: Backing up existing Technitium config ---"
if lxc "test -d /etc/dns" 2>/dev/null; then
    BACKUP_DIR="/etc/dns_backup_$(date +%Y%m%d_%H%M%S)"
    echo "  Backing up /etc/dns to ${BACKUP_DIR} ..."
    lxc "cp -a /etc/dns ${BACKUP_DIR}"
    echo "  Backup complete: ${BACKUP_DIR}"
else
    echo "  No existing /etc/dns directory found. Skipping backup."
fi

# ---------------------------------------------------------------
# STEP 2: ENSURE SHARED CONFIG DIRECTORY EXISTS AND HAS CORRECT PERMISSIONS
# ---------------------------------------------------------------
echo ""
echo "--- Step 2: Ensuring shared config directory exists ---"
# Technitium runs as user 'dns' (UID 1234, GID 1234) inside the container.
# For unprivileged LXCs, the container's UID 1234 maps to host UID
# (base_mapping + 1234). Detect the base mapping from /etc/subuid so
# we chown correctly on the host regardless of whether the LXC is
# privileged or unprivileged.
UNPRIVILEGED=$(prox "pct config ${LXC_ID}" 2>/dev/null | grep -q '^unprivileged: 1' && echo 1 || echo 0)
if [ "$UNPRIVILEGED" = "1" ]; then
    # Unprivileged LXC: container UID maps through user ns
    # Container uid 1234 -> host uid = base_mapping + 1234
    # Base mapping is typically 100000 (from /etc/subuid on the host)
    HOST_UID=$((100000 + 1234))
    HOST_GID=$((100000 + 1234))
else
    # Privileged LXC: host UID == container UID
    HOST_UID=1234
    HOST_GID=1234
fi

prox "mkdir -p ${SHARED_DIR}"
prox "chown ${HOST_UID}:${HOST_GID} ${SHARED_DIR}"
prox "chmod 755 ${SHARED_DIR}"
echo "  OK: ${SHARED_DIR} ready (host uid/gid ${HOST_UID}:${HOST_GID}, maps to container dns user)"

# ---------------------------------------------------------------
# STEP 3: SYNC CONFIG FILES
# ---------------------------------------------------------------
echo ""
echo "--- Step 3: Syncing configuration files ---"
# Copy config files to shared dir on host
scp -o StrictHostKeyChecking=accept-new "${REPO_PATH}"/config/Dns.conf root@${PROX_HOST}:${SHARED_DIR}/ 2>/dev/null || true
scp -o StrictHostKeyChecking=accept-new "${REPO_PATH}"/config/Settings.json root@${PROX_HOST}:${SHARED_DIR}/ 2>/dev/null || true
# Copy docker-compose.yml into shared dir for the LXC to read
scp -o StrictHostKeyChecking=accept-new "${REPO_PATH}"/docker-compose.yml root@${PROX_HOST}:${SHARED_DIR}/docker-compose.yml

# SCP files arrive as root:root — re-apply the correct ownership so the
# container's 'dns' user can read/write the mount (including creating
# subdirectories like /etc/dns/blocklists, /etc/dns/data, etc.).
prox "chown -R ${HOST_UID}:${HOST_GID} ${SHARED_DIR}"

echo "  OK: Config files synced"

# ---------------------------------------------------------------
# STEP 4: REMOVE EXISTING CONTAINER (IF ANY)
# ---------------------------------------------------------------
echo ""
echo "--- Step 4: Removing existing container (if any) ---"
lxc "docker rm -f ${CONTAINER_NAME}" 2>/dev/null || true

# ---------------------------------------------------------------
# STEP 5: DEPLOY VIA DOCKER-COMPOSE (INSIDE LXC)
# ---------------------------------------------------------------
echo ""
echo "--- Step 5: Deploying via Docker Compose ---"
# Run docker-compose inside the LXC.
# docker-compose.yml volume mount: /srv/data/technitium (host) -> /etc/dns (container)
# The LXC has /srv/data mounted from the host via mp0.
lxc "cd ${SHARED_DIR} && docker compose -f ${SHARED_DIR}/docker-compose.yml up -d"

# ---------------------------------------------------------------
# STEP 6: WAIT FOR CONTAINER TO START
# ---------------------------------------------------------------
echo ""
echo "--- Step 6: Waiting for container to start ---"
MAX_WAIT=90
ELAPSED=0
IS_RUNNING=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(lxc "docker ps -q --filter name=${CONTAINER_NAME}" 2>/dev/null || true)
    if [ -n "$STATUS" ]; then
        CONTAINER_STATE=$(lxc "docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME}" 2>/dev/null || true)
        if [ "$CONTAINER_STATE" = "running" ]; then
            echo "  Container is running."
            IS_RUNNING=true
            break
        fi
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$IS_RUNNING" = false ]; then
    echo "ERROR: Container ${CONTAINER_NAME} failed to start within ${MAX_WAIT} seconds."
    echo "--- Container Logs ---"
    lxc "docker logs ${CONTAINER_NAME} 2>&1 | tail -30"
    exit 1
fi

# ---------------------------------------------------------------
# STEP 7: SERVICE-LEVEL HEALTH CHECKS
# ---------------------------------------------------------------
echo ""
echo "--- Step 7: Service-level health checks ---"

# Wait a bit for DNS and web UI to be ready
sleep 10

# Check DNS port 53 is listening on the container's dedicated IP
echo "  [1/2] Checking DNS service (port 53 on ${CONTAINER_IP})..."
if prox "ss -tlnup | grep '${CONTAINER_IP}:53 ' 2>/dev/null" | grep -q .; then
    echo "      OK: DNS port 53 is listening on ${CONTAINER_IP}"
else
    echo "  WARNING: DNS port 53 on ${CONTAINER_IP} not yet listening. The service may still be starting."
fi

# Check web UI port 80 on the container's dedicated IP
echo "  [2/2] Checking Web UI (port 80 on ${CONTAINER_IP})..."
if prox "ss -tlnup | grep '${CONTAINER_IP}:80 ' 2>/dev/null" | grep -q .; then
    echo "      OK: Web UI port 80 is listening on ${CONTAINER_IP}"
else
    echo "  WARNING: Web UI port 80 on ${CONTAINER_IP} not yet listening. The service may still be starting."
fi

# ---------------------------------------------------------------
# STEP 8: SHOW STATUS
# ---------------------------------------------------------------
echo ""
echo "--- Container Status ---"
lxc "docker ps --filter name=${CONTAINER_NAME}"

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo ""
echo "  DNS:    ${CONTAINER_IP}:53 (TCP/UDP)"
echo "  Web UI: http://${CONTAINER_IP}:80"
echo ""
echo "  NOTE: Ports are bound to ${CONTAINER_IP} only — no host conflict."
echo "============================================================"
echo ""
echo "  Config files are in: ${SHARED_DIR}/ on the host"
echo "  (Mounted into the container at /etc/dns via docker-compose)"

exit 0
