# Technitium DNS Server Deployment Guide

This repository contains the Infrastructure as Code (IaC) for the Technitium DNS Server.

## Overview

Technitium runs as a single Docker container inside the `hlh-docker` LXC (VMID 109) on prox01 (192.168.1.10). It serves as the lab's secondary DNS and is bound to a dedicated IP only — never to the LXC's primary IP:

| Service | Address |
|---------|---------|
| DNS (TCP/UDP) | `192.168.1.2:53` |
| Web UI | `http://192.168.1.2/` (host port 80 → container port 5380) |
| API | `http://192.168.1.2/api/` |
| Config dir | `/srv/data/technitium` (LXC, ZFS mount) → `/etc/dns` in container |

## Two-file workflow (KISS, no compose)

| Script | Purpose |
|--------|---------|
| `configure-iac-ct-technitium.sh` | Shared dir + ownership + baseline config sync (`config/Dns.conf`, `config/Settings.json`). Backs up the dir first. Does NOT touch zone data. |
| `deploy-iac-ct-technitium.sh` | Ensures the `192.168.1.2/24` alias (immediate + persistent systemd unit), pulls the image if missing, `docker run`s the container, waits, and health-checks end-to-end. Auto-runs configure if no config is present yet. |

Typical run:

```bash
./configure-iac-ct-technitium.sh   # only when baseline config changes
./deploy-iac-ct-technitium.sh      # (re)deploys; auto-configures on first run
```

What deploy does, by hand:

```bash
# inside LXC 109
ip addr replace 192.168.1.2/24 dev eth0
docker pull technitium/dns-server:latest
docker rm -f technitium
docker run -d --name technitium --restart always --cap-add NET_ADMIN \
  -p 192.168.1.2:53:53/tcp -p 192.168.1.2:53:53/udp -p 192.168.1.2:80:5380/tcp \
  -v /srv/data/technitium:/etc/dns \
  technitium/dns-server:latest
```

## IP alias (192.168.1.2)

Port bindings target `192.168.1.2`, so that IP must exist on the LXC's eth0. Proxmox rewrites the LXC network config from `net0` (single IP `192.168.1.9/24`) on every CT start, so the deploy script:

1. Applies it immediately: `ip addr replace 192.168.1.2/24 dev eth0`
2. Installs a oneshot systemd unit `technitium-ipalias.service` that re-applies it at boot.

If DNS ports are not binding after a CT reboot:

```bash
# inside LXC 109
systemctl status technitium-ipalias.service
ip -4 addr show eth0
```

## Configuration

Baseline config is `config/Dns.conf` (server behavior) + `config/Settings.json` (application settings), synced by the configure script to `/srv/data/technitium` and mounted into the container at `/etc/dns`.

Zone data (`zones/`, `stats/`, `cache.bin`, `auth.config`, …) lives in `/srv/data/technitium` on the host and is **not** tracked in this repo. The configure script saves a tarball backup in `/srv/data/` before overwriting the baseline files.

## Adding DNS records via CLI

The Technitium API is available at `http://192.168.1.2/api/`. Authenticate by POSTing to `/api/user/login` with form data `user=admin&pass=<password>&includeInfo=true`. The response contains a `token` field — use it as `Authorization: Bearer <token>` on subsequent requests.

**Add an A record:**
```bash
curl -s "http://192.168.1.2/api/zones/records/add?node=" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "domain=hostname.mizertech.net&type=A&ipAddress=192.168.1.XXX"
```

**Create a reverse DNS zone:**
```bash
curl -s "http://192.168.1.2/api/zones/create?zone=1.168.192.in-addr.arpa" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "zoneName=1.168.192.in-addr.arpa&zoneType=Primary"
```

**Add a PTR record:**
```bash
curl -s "http://192.168.1.2/api/zones/records/add?node=" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "domain=1.1.168.192.in-addr.arpa&type=PTR&ptrName=udr7.mizertech.net"
```

**List zones:**
```bash
curl -s "http://192.168.1.2/api/zones/list?filterName=" \
  -H "Authorization: Bearer <token>"
```

**List records in a zone:**
```bash
curl -s "http://192.168.1.2/api/zones/records/get?domain=mizertech.net" \
  -H "Authorization: Bearer <token>"
```

## Current DNS records (target state)

**Forward zone (`mizertech.net`):**

| Name | Type | Value | Host |
|------|------|-------|------|
| udr7 | A | 192.168.1.1 | Router / gateway |
| dns | A | 192.168.1.2 | Technitium (LXC 109) |
| hlh-docker | A | 192.168.1.9 | Docker host (LXC 109) |
| prox01 | A | 192.168.1.10 | Proxmox VE |
| hlh-ai-engine-egpu | A | 192.168.1.11 | llama.cpp + CUDA (V100) |
| hlh-ai-engine-igpu | A | 192.168.1.12 | llama.cpp + ROCm (890M iGPU) |
| hlh-ai-engine-vllm | A | 192.168.1.13 | vLLM + Open WebUI (V100) |

**Reverse zone (`1.168.192.in-addr.arpa`):**

| Name | Type | Value |
|------|------|-------|
| 1.1.168.192.in-addr.arpa | PTR | udr7.mizertech.net |
| 2.1.168.192.in-addr.arpa | PTR | dns.mizertech.net |
| 9.1.168.192.in-addr.arpa | PTR | hlh-docker.mizertech.net |
| 10.1.168.192.in-addr.arpa | PTR | prox01.mizertech.net |
| 11.1.168.192.in-addr.arpa | PTR | hlh-ai-engine-egpu.mizertech.net |
| 12.1.168.192.in-addr.arpa | PTR | hlh-ai-engine-igpu.mizertech.net |
| 13.1.168.192.in-addr.arpa | PTR | hlh-ai-engine-vllm.mizertech.net |

Notes:
- The live zone files in `/srv/data/technitium/zones/` are authoritative — reconcile via the API after re-deploy (the legacy `hlh-ai-engine` → 192.168.1.12 record from the single-engine era may still be there).
- PBS4 (VM 100) is still configured for `192.168.1.9` in Proxmox, which conflicts with hlh-docker. Renumber PBS4 before starting it, then add its record here.
