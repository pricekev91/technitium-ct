#!/bin/bash
set -e

# =============================================================
# Technitium DNS Server - DEPLOY (hlh-docker LXC, VMID 109)
# KISS: plain docker run, no compose.
#   1. pre-flight (ssh, CT running, docker, port 53 free)
#   2. ensure 192.168.1.2/24 alias on eth0 (immediate + persistent unit)
#   3. config present? (auto-runs configure script if not)
#   4. image present? (pull if not)
#   5. docker rm -f + docker run
#   6. wait for running
#   7. health checks: inside LXC (ss) + end-to-end from laptop (dig/curl)
# Config sync lives in configure-iac-ct-technitium.sh.
# =============================================================

CONTAINER_NAME="technitium"
LXC_ID="109"                 # hlh-docker (was VMID 102 before re-provisioning)
PROX_HOST="192.168.1.10"     # prox01
CONTAINER_IP="192.168.1.2"   # dedicated Technitium IP (alias on LXC eth0)
IMAGE="technitium/dns-server:latest"
SHARED_DIR="/srv/data/technitium"
ALIAS_UNIT="technitium-ipalias.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Helper: run commands inside the LXC
lxc() { ssh root@${PROX_HOST} "pct exec ${LXC_ID} -- /bin/sh -c '$*'"; }
# Helper: run commands on the Proxmox host
prox() { ssh root@${PROX_HOST} "$*"; }

echo "============================================================"
echo "  Technitium DNS Server - Deploy"
echo "  LXC ${LXC_ID} (${CONTAINER_IP}) on ${PROX_HOST}"
echo "============================================================"

# ---------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------
echo ""
echo "--- Pre-flight ---"

echo "  [1/4] SSH to ${PROX_HOST} ..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@${PROX_HOST} "echo ok" >/dev/null 2>&1; then
    echo "ERROR: cannot reach ${PROX_HOST}."; exit 1
fi
echo "      OK"

echo "  [2/4] LXC ${LXC_ID} running ..."
if ! prox "pct status ${LXC_ID}" 2>/dev/null | grep -q running; then
    echo "ERROR: LXC ${LXC_ID} is not running. Start it first: pct start ${LXC_ID}"; exit 1
fi
echo "      OK"

echo "  [3/4] docker inside LXC ..."
if ! lxc "docker --version" >/dev/null 2>&1; then
    echo "ERROR: docker not available inside LXC ${LXC_ID}."; exit 1
fi
echo "      OK: $(lxc "docker --version")"

echo "  [4/4] port 53 on ${CONTAINER_IP} free ..."
if lxc "ss -tlnup 2>/dev/null" | grep -q "${CONTAINER_IP}:53 "; then
    echo "ERROR: ${CONTAINER_IP}:53 is already in use inside LXC ${LXC_ID}."
    exit 1
fi
echo "      OK"

# ---------------------------------------------------------------
# STEP 1: DEDICATED IP ALIAS (192.168.1.2/24 on eth0)
# ---------------------------------------------------------------
# Port bindings target ${CONTAINER_IP} only, so the alias must exist on the
# LXC's eth0. PVE rewrites the LXC network config from net0 (single IP
# 192.168.1.9/24) on every CT start, so the alias is applied now AND made
# persistent with a oneshot systemd unit that re-applies it at boot.
echo ""
echo "--- Step 1: Ensuring ${CONTAINER_IP}/24 alias on eth0 ---"
lxc "ip addr replace ${CONTAINER_IP}/24 dev eth0"
UNIT_B64=$(printf '%s\n' \
  '[Unit]' \
  "Description=Technitium secondary IP alias (${CONTAINER_IP}/24) on eth0" \
  'After=network-online.target' \
  'Wants=network-online.target' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'RemainAfterExit=yes' \
  "ExecStart=/bin/sh -c 'ip addr replace ${CONTAINER_IP}/24 dev eth0'" \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  | base64 -w0)
lxc "echo ${UNIT_B64} | base64 -d > /etc/systemd/system/${ALIAS_UNIT} && systemctl daemon-reload && systemctl enable --now ${ALIAS_UNIT}"
if lxc "ip -4 addr show eth0" | grep -q "${CONTAINER_IP}/"; then
    echo "  OK: alias present (persistent via ${ALIAS_UNIT})"
else
    echo "ERROR: could not add ${CONTAINER_IP}/24 to eth0 inside LXC ${LXC_ID}."; exit 1
fi

# ---------------------------------------------------------------
# STEP 2: CONFIG PRESENT?
# ---------------------------------------------------------------
echo ""
echo "--- Step 2: Checking config in ${SHARED_DIR} ---"
if ! lxc "test -f ${SHARED_DIR}/Dns.conf" 2>/dev/null; then
    echo "  No config found - running configure-iac-ct-technitium.sh ..."
    "${SCRIPT_DIR}/configure-iac-ct-technitium.sh"
fi
echo "  OK: config present"

# ---------------------------------------------------------------
# STEP 3: IMAGE
# ---------------------------------------------------------------
echo ""
echo "--- Step 3: Image ${IMAGE} ---"
if lxc "docker image inspect ${IMAGE} >/dev/null 2>&1"; then
    echo "  OK: image present"
else
    echo "  Pulling ..."
    lxc "docker pull ${IMAGE}"
    echo "  OK: image pulled"
fi

# ---------------------------------------------------------------
# STEP 4: REMOVE OLD CONTAINER (IF ANY)
# ---------------------------------------------------------------
echo ""
echo "--- Step 4: Removing existing container (if any) ---"
lxc "docker rm -f ${CONTAINER_NAME} 2>/dev/null" || true
echo "  OK"

# ---------------------------------------------------------------
# STEP 5: DOCKER RUN (no compose)
# ---------------------------------------------------------------
echo ""
echo "--- Step 5: Starting container ---"
lxc "docker run -d --name ${CONTAINER_NAME} --restart always --cap-add NET_ADMIN -p ${CONTAINER_IP}:53:53/tcp -p ${CONTAINER_IP}:53:53/udp -p ${CONTAINER_IP}:80:5380/tcp -v ${SHARED_DIR}:/etc/dns ${IMAGE}"
echo "  OK: container created"

# ---------------------------------------------------------------
# STEP 6: WAIT FOR RUNNING
# ---------------------------------------------------------------
echo ""
echo "--- Step 6: Waiting for container to start ---"
IS_RUNNING=false
for i in $(seq 1 18); do
    RUNNING_ID=$(lxc "docker ps -q --filter name=${CONTAINER_NAME} --filter status=running" 2>/dev/null || true)
    if [ -n "${RUNNING_ID}" ]; then
        IS_RUNNING=true
        break
    fi
    sleep 5
done
if [ "${IS_RUNNING}" != "true" ]; then
    echo "ERROR: container not running after 90s. Logs:"
    lxc "docker logs ${CONTAINER_NAME} 2>&1 | tail -30"
    exit 1
fi
echo "  OK: running"

# ---------------------------------------------------------------
# STEP 7: HEALTH CHECKS
# ---------------------------------------------------------------
echo ""
echo "--- Step 7: Health checks ---"
DNS_OK=false
UI_OK=false
for i in $(seq 1 6); do
    # Inside the LXC: ports bound on the dedicated IP
    if [ "${DNS_OK}" = "false" ] && lxc "ss -tlnup 2>/dev/null" | grep -q "${CONTAINER_IP}:53 "; then
        DNS_OK=true
    fi
    if [ "${UI_OK}" = "false" ] && lxc "ss -tlnup 2>/dev/null" | grep -q "${CONTAINER_IP}:80 "; then
        UI_OK=true
    fi
    # End-to-end from this machine (crosses vmbr0 into the LXC netns)
    if [ "${DNS_OK}" = "false" ] && dig +time=2 +tries=1 @"${CONTAINER_IP}" mizertech.net SOA +short 2>/dev/null | grep -q .; then
        DNS_OK=true
    fi
    if [ "${UI_OK}" = "false" ]; then
        CODE=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' "http://${CONTAINER_IP}/" 2>/dev/null || true)
        case "${CODE}" in 2*|3*) UI_OK=true ;; esac
    fi
    if [ "${DNS_OK}" = "true" ] && [ "${UI_OK}" = "true" ]; then
        break
    fi
    sleep 5
done

echo "  [1/2] DNS (port 53 on ${CONTAINER_IP}):    $([ "${DNS_OK}" = "true" ] && echo OK || echo NOT RESPONDING)"
echo "  [2/2] Web UI (port 80 on ${CONTAINER_IP}): $([ "${UI_OK}" = "true" ] && echo OK || echo NOT RESPONDING)"

if [ "${DNS_OK}" != "true" ] || [ "${UI_OK}" != "true" ]; then
    echo ""
    echo "ERROR: health checks failed. Container logs:"
    lxc "docker logs ${CONTAINER_NAME} 2>&1 | tail -30"
    exit 1
fi

# ---------------------------------------------------------------
# STEP 8: STATUS
# ---------------------------------------------------------------
echo ""
echo "--- Container Status ---"
lxc "docker ps --filter name=${CONTAINER_NAME}"

echo ""
echo "============================================================"
echo "  Deploy complete!"
echo ""
echo "  DNS:    ${CONTAINER_IP}:53 (TCP/UDP)"
echo "  Web UI: http://${CONTAINER_IP}/  (API: http://${CONTAINER_IP}/api/)"
echo ""
echo "  Config: ${SHARED_DIR} (mounted to /etc/dns in container)"
echo "  Ports bound to ${CONTAINER_IP} only - no host conflict."
echo "============================================================"

exit 0
