# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

All communication, responses, code comments, commit messages, and documentation **must be in English only**, regardless of what language the user writes in.

## Project Overview

OpenClaw on Proxmox is a single-script deployment tool (`setup-openclaw-lxc.sh`) that automates creating a Proxmox LXC container with a fully configured OpenClaw AI assistant, LXQt desktop, Google Chrome, and VNC/noVNC remote access. It targets Proxmox VE 8.x+ hosts running as root.

## Architecture

The entire project is one ~460-line Bash script with this flow:

1. **Pre-flight** — Verify Proxmox CLI tools (`pct`, `pvesh`, `pveam`) and root access
2. **User prompts** — Collect container password, disk/memory/CPU/resolution settings
3. **Auto-detection** — Find next VMID and storage backends via `pvesh` JSON + Python parsing
4. **Template management** — Download Debian 13 template if missing
5. **Container creation** — Privileged LXC, DHCP networking
6. **Package installation** — Node.js 22, Homebrew (as non-root `brewuser`), OpenClaw (npm global), LXQt, TigerVNC, noVNC, Google Chrome, OpenClaw browser extension
7. **Configuration** — OpenClaw gateway settings, VNC password/xstartup, noVNC auto-scaling patch, Chrome as default browser
8. **Desktop integration** — Desktop shortcuts for onboarding wizard and dashboard
9. **Systemd services** — Three auto-starting services: `openclaw-gateway` (port 18789), `vncserver` (:1/5901), `novnc` (port 6080)
10. **Verification** — Check all services are active, print connection info

Key helper: `ct_exec()` wraps `pct exec $VMID -- bash -c` for all in-container commands.

## Development Notes

- No build system, test suite, or linter — this is a standalone Bash script
- Uses `set -euo pipefail` for strict error handling
- All in-container operations use heredoc-embedded config files (systemd units, desktop files, wrapper scripts)
- Colorized output via `info()`, `ok()`, `warn()`, `err()`, `fatal()` helper functions
- Homebrew is installed under a dedicated `brewuser` account (non-root requirement) with a symlink at `/usr/local/bin/brew` for root access
- The noVNC auto-scaling patch modifies `/usr/share/novnc/app/ui.js` in-place via `sed`
- Auth token is generated with `openssl rand -hex 16`

## Testing Changes

There is no automated test infrastructure. To test changes, run the script on a Proxmox host:

```bash
bash setup-openclaw-lxc.sh
```

Verify by checking: container creation, all three systemd services running, noVNC web access, and OpenClaw dashboard reachability.

## Changelog

All notable changes are documented in [`docs/changelog.md`](docs/changelog.md). Update it with every meaningful change to the script (date, short description, what changed and why).

## Shell Style

- Bash with `set -euo pipefail`
- Double-quoted variables throughout
- Heredocs for multi-line content (both quoted `'EOF'` and unquoted `EOF` depending on variable expansion needs)
- `grep -v` to suppress noisy apt/install output
- Python3 one-liners for JSON parsing of Proxmox API output
