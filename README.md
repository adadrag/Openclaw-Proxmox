# OpenClaw Proxmox LXC Setup

Automated setup script that deploys an [OpenClaw](https://openclaw.ai/) AI assistant inside a Proxmox LXC container, complete with a remote desktop (noVNC) and Chromium browser.

## What it does

A single Bash script that runs on your **Proxmox host** and:

1. Creates a Debian 13 unprivileged LXC container
2. Installs Node.js 22 and OpenClaw
3. Installs XFCE4 desktop with TigerVNC and noVNC
4. Installs Chromium (patched for LXC `--no-sandbox`)
5. Configures systemd services for everything (auto-start on boot)
6. Prints connection URLs when done

## Quick Start

```bash
# On your Proxmox host:
wget -O setup-openclaw-lxc.sh https://raw.githubusercontent.com/adadrag/Openclaw-Proxmox/main/setup-openclaw-lxc.sh
chmod +x setup-openclaw-lxc.sh
bash setup-openclaw-lxc.sh
```

## Requirements

- Proxmox VE 8.x+
- Root access on the Proxmox host
- Internet connectivity (for downloading packages)
- Available storage for container rootfs

## Configuration Options

The script prompts for the following (with defaults):

| Option | Default | Description |
|--------|---------|-------------|
| Password | *(required)* | Container root password (also used for VNC) |
| Disk size | 32 GB | Container root filesystem size |
| Memory | 4096 MB | Container RAM allocation |
| CPU cores | 4 | Number of CPU cores |
| VNC resolution | 1920x1080 | Remote desktop resolution |

Everything else is auto-detected:
- **VMID** — next available ID in the cluster
- **Storage** — auto-selects template and rootfs storage
- **Networking** — DHCP on `vmbr0`

## Services

The script creates and enables three systemd services inside the container:

| Service | Port | Description |
|---------|------|-------------|
| `openclaw-gateway` | 18789 | OpenClaw AI gateway (token auth) |
| `vncserver` | 5901 | TigerVNC server (localhost only) |
| `novnc` | 6080 | noVNC web proxy (exposes VNC via browser) |

## Access Points

After setup, the script prints all connection details:

- **OpenClaw Dashboard**: `http://<container-ip>:18789/`
- **Remote Desktop (noVNC)**: `http://<container-ip>:6080/vnc.html`
- **SSH**: `ssh root@<container-ip>`

## Container Management

```bash
pct enter <VMID>       # Shell into the container
pct stop <VMID>        # Stop the container
pct start <VMID>       # Start the container
pct status <VMID>      # Check container status
```

## Troubleshooting

**Service not starting?**
```bash
pct exec <VMID> -- systemctl status openclaw-gateway
pct exec <VMID> -- systemctl status vncserver
pct exec <VMID> -- systemctl status novnc
```

**Chromium won't launch?**
Chromium needs `--no-sandbox` inside LXC containers. The script patches this automatically, but if you installed Chromium separately, run:
```bash
sed -i 's|Exec=/usr/bin/chromium|Exec=/usr/bin/chromium --no-sandbox|g' /usr/share/applications/chromium.desktop
```

**"Unable to contact settings server" in XFCE?**
This means `dbus-x11` is missing. The script installs it, but if you see this error:
```bash
apt-get install -y dbus-x11
```

## License

MIT License. See [LICENSE](LICENSE) for details.
