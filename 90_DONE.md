# iac-ct-technitium
This file contains the completed tasks for the iac-ct-technitium project.

## Tasks
This is where completed tasks will be listed.

### [2026-08-06] Rebuild Technitium DNS Server on LXC 102 (hlh-docker)
- **Problem:** Previous deployment failed because `192.168.1.2` was not configured on the LXC's network interface. Docker bound ports to the LXC's primary IP (`192.168.1.13`) instead of the intended `192.168.1.2`. The container exited cleanly and was lost.
- **Fix applied:**
  1. Added `192.168.1.2/24` as a secondary IP alias on the LXC's eth0 interface
  2. Removed the old container (`docker rm -f ct-technitium`)
  3. Created `/srv/data/technitium` shared directory with correct UID (101234 for unprivileged LXC)
  4. Synced config files (Dns.conf, Settings.json, docker-compose.yml) from repo
  5. Deployed via `docker compose up -d`
  6. Verified DNS (port 53) and Web UI (port 5380) are listening on `192.168.1.2`
- **DNS records added:**
  - Forward zone `mizertech.net`: A records for udr7, dns, prox01, hlh-ai-engine, hlh-docker
  - Reverse zone `1.168.192.in-addr.arpa`: PTR records for all 5 hosts
- **Reference:** Full runbook in `docs/README.md` under "Troubleshooting / Runbook"
