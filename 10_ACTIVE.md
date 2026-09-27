# iac-ct-technitium
This file contains the active tasks for the iac-ct-technitium project.

## Tasks
These are the tasks that are currently in progress.

- [ ] Manual deploy on LXC 109: `./configure-iac-ct-technitium.sh` then `./deploy-iac-ct-technitium.sh` (deploy auto-configures if config missing). Image `technitium/dns-server:latest` was lost in the 2026-09-25 prune; the `192.168.1.2` alias is gone.
- [ ] After deploy: reconcile live zone with the current IP table in `docs/README.md` (add hlh-docker .9 and engines .11/.12/.13, drop legacy `hlh-ai-engine` record if unused).

## Notes
Any additional notes about the project will be listed here.
