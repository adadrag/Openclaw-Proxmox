# OpenClaw on Proxmox — One Script, Full AI Assistant

Deploy your own **[OpenClaw](https://openclaw.ai/) AI assistant** on any Proxmox server in minutes. One command, zero manual setup.

## Why use this?

- **Self-hosted AI assistant** — OpenClaw runs entirely on your hardware, under your control
- **One command to deploy** — no manual package installation, no config file editing, no guesswork
- **Full remote desktop** — access a graphical LXQt desktop from any browser via noVNC
- **Ready-to-use browser** — Google Chrome with developer mode for OpenClaw browser extension
- **Lightweight container** — runs in a privileged LXC (not a full VM), so it's fast and resource-efficient
- **Auto-starts on boot** — all services (gateway, VNC, noVNC) are systemd-managed
- **Onboarding made easy** — desktop shortcut walks you through OpenClaw setup step by step
- **Homebrew included** — install OpenClaw skills right away

## Quick Start

SSH into your Proxmox host and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/adadrag/Openclaw-Proxmox/main/setup-openclaw-lxc.sh)
```

That's it. The script will ask for a password, pick sensible defaults for everything else, and print your connection URLs when done.

### Alternative install methods

**Download first, then run:**
```bash
wget -O setup-openclaw-lxc.sh https://raw.githubusercontent.com/adadrag/Openclaw-Proxmox/main/setup-openclaw-lxc.sh
chmod +x setup-openclaw-lxc.sh
./setup-openclaw-lxc.sh
```

**Clone the repo:**
```bash
git clone https://github.com/adadrag/Openclaw-Proxmox.git
cd Openclaw-Proxmox
chmod +x setup-openclaw-lxc.sh
./setup-openclaw-lxc.sh
```

## What you get

After the script finishes, you'll have a fully configured LXC container with:

| What | How to access |
|------|---------------|
| **OpenClaw Dashboard** | `http://<container-ip>:18789/#token=<your-token>` |
| **Remote Desktop** | `http://<container-ip>:6080/vnc.html` |
| **SSH** | `ssh root@<container-ip>` |

The script prints all of this (including the token) at the end.

## Desktop Shortcuts

Once you open the remote desktop via noVNC, you'll find two shortcuts ready to go:

| Shortcut | What it does |
|----------|-------------|
| **OpenClaw Setup Wizard** | Opens the interactive onboarding wizard (`openclaw onboard`) to configure your channels, workspace, and skills |
| **OpenClaw Dashboard** | Opens Chrome with the dashboard URL and auth token pre-filled — no manual token entry needed |

## Requirements

- Proxmox VE 8.x+
- Root access on the Proxmox host
- Internet connectivity (for downloading packages)

## Configuration

The script prompts you interactively (all optional except password):

| Option | Default | Description |
|--------|---------|-------------|
| Password | *(required)* | Container root password (also used for VNC) |
| Disk size | 32 GB | Container root filesystem size |
| Memory | 4096 MB | RAM allocation |
| CPU cores | 4 | Number of CPU cores |
| VNC resolution | 1920x1080 | Remote desktop resolution |

Everything else is auto-detected — VMID, storage, networking (DHCP).

## What the script installs

All inside the container (nothing is installed on the Proxmox host):

- **Debian 13** LXC (privileged)
- **Node.js 22** + **OpenClaw**
- **Homebrew** (for OpenClaw skills)
- **LXQt** desktop + **TigerVNC** + **noVNC**
- **Google Chrome** (with OpenClaw browser extension)
- **Noto Color Emoji** font (for proper terminal rendering)
- Three **systemd services**: `openclaw-gateway`, `vncserver`, `novnc`

## Container Management

```bash
pct enter <VMID>       # Shell into the container
pct stop <VMID>        # Stop the container
pct start <VMID>       # Start the container
pct status <VMID>      # Check container status
```

## Notes on the onboarding wizard

When you run the **OpenClaw Setup Wizard** from the desktop shortcut, you may see two messages that look like errors but are perfectly normal:

**"Gateway service install failed"** — The wizard tries to create its own systemd service for the gateway, but our script already set up `openclaw-gateway.service` and it's already running. This is safe to ignore.

**"SECURITY ERROR: ws:// to a non-loopback address"** — This is a warning that the gateway uses unencrypted WebSocket over LAN. This is expected for a local setup. If you're on a trusted home or office network, it's completely fine.

As long as you see your **channels connected**, a **Control UI URL**, and an **agent workspace** listed at the end of the wizard, everything worked.

## Troubleshooting

**Service not starting?**
```bash
pct exec <VMID> -- systemctl status openclaw-gateway
pct exec <VMID> -- systemctl status vncserver
pct exec <VMID> -- systemctl status novnc
```

**Chrome extension not loading?**
Open Chrome, navigate to `chrome://extensions`, enable **Developer Mode** (top right toggle), then click **Load unpacked** and select the OpenClaw extension directory.

## License

MIT License. See [LICENSE](LICENSE) for details.
