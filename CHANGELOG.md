# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v1.2.0] - 2026-09-27

### Added
- `configure-iac-ct-technitium.sh` — KISS config phase: shared dir + ownership + baseline config sync (Dns.conf, Settings.json) with tarball backup
- Persistent `192.168.1.2/24` alias: deploy installs a `technitium-ipalias.service` oneshot unit inside the LXC (survives CT reboots and PVE network-config rewrites)
- End-to-end health checks from the laptop (dig @192.168.1.2 + curl http://192.168.1.2/); deploy hard-fails with container logs on failure

### Changed
- Target LXC 109 (hlh-docker was re-provisioned from VMID 102)
- Deploy uses plain `docker run` — docker compose removed (`docker-compose.yml` deleted)
- Backup step now targets `/srv/data/technitium` (previous code backed up `/etc/dns`, a path that never existed inside the LXC)
- Docs: current IP table (hlh-docker 192.168.1.9, AI engines .11/.12/.13), web UI/API on port 80 (was 5380), two-file workflow

## [v1.1.0] - 2026-06-30

### Added
- Pre-flight checks in deploy script (docker, docker compose, SSH connectivity, port 53)
- Service-level health checks (DNS on port 53, Web UI on port 5380)
- Automatic backup of existing /etc/dns config before deployment
- Proper Technitium config files: Dns.conf (INI format) and Settings.json (JSON format)
- Container IP lookup tip in deployment output
- Updated README with full documentation

### Changed
- Replaced YAML config (default.yaml) with native Technitium format (Dns.conf + Settings.json)
- Updated deploy script with 8-step process including backup, pre-flight, health checks
- Removed configure-iac-ct-technitium.sh (deploy script already handles config sync — no need for a separate script)
- Updated changelog with detailed version history

### Fixed
- Config format incompatible with Technitium DNS Server
- No backup of existing data before overwrite
- No service-level verification after container start

## [v1.0.1] - Previous
- Bug fix for deployment script

## [v1.0.0] - Previous
- Initial project setup
