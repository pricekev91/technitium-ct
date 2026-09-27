#!/bin/bash
set -e

# =============================================================
# Technitium DNS Server - CONFIGURE (hlh-docker LXC, VMID 109)
# KISS: shared dir + ownership + baseline config sync.
#   1. pre-flight (ssh, CT running)
#   2. ensure /srv/data/technitium with correct ownership
#      (container 'dns' user 1234 -> host 101234 in unprivileged LXC)
#   3. backup existing dir as tarball, then sync baseline config
#      (config/Dns.conf + config/Settings.json) from this repo
# Does NOT touch zone data (zones/, stats/, cache.bin, auth.config).
# Does NOT start or restart the container (that is the deploy script).
# =============================================================

LXC_ID="109"                 # hlh-docker (was VMID 102 before re-provisioning)
PROX_HOST="192.168.1.10"     # prox01
SHARED_DIR="/srv/data/technitium"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Helper: run commands inside the LXC
lxc() { ssh root@${PROX_HOST} "pct exec ${LXC_ID} -- /bin/sh -c '$*'"; }
# Helper: run commands on the Proxmox host
prox() { ssh root@${PROX_HOST} "$*"; }

echo "============================================================"
echo "  Technitium DNS Server - Configure"
echo "  LXC ${LXC_ID} on ${PROX_HOST}"
echo "============================================================"

# ---------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------
echo ""
echo "--- Pre-flight ---"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@${PROX_HOST} "echo ok" >/dev/null 2>&1; then
    echo "ERROR: cannot reach ${PROX_HOST}."; exit 1
fi
if ! prox "pct status ${LXC_ID}" 2>/dev/null | grep -q running; then
    echo "ERROR: LXC ${LXC_ID} is not running. Start it first: pct start ${LXC_ID}"; exit 1
fi
echo "  OK"

# Container 'dns' user is uid/gid 1234 inside the LXC; in an unprivileged
# LXC that maps to host uid/gid 100000+1234.
UNPRIVILEGED=$(prox "pct config ${LXC_ID}" | grep -q '^unprivileged: 1' && echo 1 || echo 0)
if [ "${UNPRIVILEGED}" = "1" ]; then
    HOST_UID=101234
    HOST_GID=101234
else
    HOST_UID=1234
    HOST_GID=1234
fi

# ---------------------------------------------------------------
# STEP 1: SHARED DIR + OWNERSHIP
# ---------------------------------------------------------------
echo ""
echo "--- Step 1: Shared dir ${SHARED_DIR} (host uid ${HOST_UID}:${HOST_GID}) ---"
prox "mkdir -p ${SHARED_DIR}"
prox "chown ${HOST_UID}:${HOST_GID} ${SHARED_DIR} && chmod 755 ${SHARED_DIR}"
echo "  OK"

# ---------------------------------------------------------------
# STEP 2: BACKUP + SYNC BASELINE CONFIG
# ---------------------------------------------------------------
echo ""
echo "--- Step 2: Syncing baseline config from repo ---"
if lxc "test -f ${SHARED_DIR}/Dns.conf" 2>/dev/null; then
    TS=$(date +%Y%m%d_%H%M%S)
    lxc "tar czf /srv/data/technitium-config-backup_${TS}.tar.gz -C /srv/data technitium"
    echo "  Backup: /srv/data/technitium-config-backup_${TS}.tar.gz"
fi
scp -o StrictHostKeyChecking=accept-new "${SCRIPT_DIR}/config/Dns.conf" "${SCRIPT_DIR}/config/Settings.json" root@${PROX_HOST}:${SHARED_DIR}/
# SCP files arrive as root:root - restore container ownership across the dir
prox "chown -R ${HOST_UID}:${HOST_GID} ${SHARED_DIR}"
echo "  OK: Dns.conf + Settings.json synced"

echo ""
echo "============================================================"
echo "  Configuration complete."
echo "  Config: ${SHARED_DIR} (mounted to /etc/dns in container)"
echo "  Run ./deploy-iac-ct-technitium.sh to (re)start the service."
echo "============================================================"

exit 0
