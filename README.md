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

That's it. The script will ask for a password, admin username, and SSH public key, then pick sensible defaults for everything else and print your connection URLs when done.

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
| **Remote Desktop** | `https://<container-ip>/vnc.html` (after HTTPS setup) |
| **SSH** | `ssh <admin-user>@<container-ip>` (key auth only) |

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
| Password | *(required)* | Container root + openclaw user password (also used for VNC) |
| Disk size | 32 GB | Container root filesystem size |
| Memory | 4096 MB | RAM allocation |
| CPU cores | 4 | Number of CPU cores |
| VNC resolution | 1920x1080 | Remote desktop resolution |
| Admin username | *(required)* | Linux user with full passwordless sudo (separate from `openclaw` service account) |
| SSH public key | *(required)* | Public key for the admin user; password SSH login is disabled |

Everything else is auto-detected — VMID, storage, networking (DHCP).

## What the script installs

All inside the container (nothing is installed on the Proxmox host):

- **Debian 13** LXC (unprivileged, nesting enabled)
- **Node.js 22** + **OpenClaw**
- **Homebrew** (for OpenClaw skills)
- **LXQt** desktop + **TigerVNC** + **noVNC**
- **Google Chrome** (with OpenClaw browser extension)
- **Noto Color Emoji** font (for proper terminal rendering)
- Three **systemd services**: `openclaw-gateway`, `vncserver`, `novnc`

## HTTPS Setup (recommended)

By default noVNC runs over plain HTTP. Modern browsers block clipboard access over HTTP, so **HTTPS is required** for full clipboard support. Follow these steps to set it up.

### 1. Generate an SSL certificate

If you have your own CA, generate a certificate signed by it:

```bash
mkdir -p ~/certs && cd ~/certs

# Generate private key and CSR
openssl genrsa -out openclaw.home.key 2048
openssl req -new -key openclaw.home.key \
  -out openclaw.home.csr \
  -subj "/CN=openclaw.home"

# Sign with your CA (adjust paths to your rootCA files)
openssl x509 -req -in openclaw.home.csr \
  -CA /path/to/rootCA.crt \
  -CAkey /path/to/rootCA.key \
  -CAcreateserial \
  -out openclaw.home.crt \
  -days 825 \
  -extfile <(printf "subjectAltName=DNS:openclaw.home,IP:<container-ip>")
```

Alternatively, generate a self-signed certificate (you will need to accept the browser warning or add it to your trusted roots manually):

```bash
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout ~/certs/openclaw.home.key \
  -out ~/certs/openclaw.home.crt \
  -subj "/CN=openclaw.home" \
  -addext "subjectAltName=DNS:openclaw.home,IP:<container-ip>"
```

### 2. Configure nginx as a reverse proxy

Install nginx if it isn't already installed:

```bash
sudo apt install nginx -y
```

Create a site configuration:

```bash
sudo nano /etc/nginx/sites-available/novnc
```

Paste the following (adjust certificate paths if needed):

```nginx
server {
    listen 443 ssl;
    server_name openclaw.home;

    ssl_certificate /home/<admin-user>/certs/openclaw.home.crt;
    ssl_certificate_key /home/<admin-user>/certs/openclaw.home.key;

    location / {
        proxy_pass http://localhost:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

Enable the site and restart nginx:

```bash
sudo ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

The remote desktop is now available at `https://openclaw.home/vnc.html` (or by IP).

### 3. Trust the certificate on Windows

If you used your own CA, install `rootCA.crt` into Windows **Trusted Root Certification Authorities**:

1. Copy `rootCA.crt` to your Windows machine
2. Double-click the file → **Install Certificate**
3. Select **Local Machine** → **Place all certificates in the following store**
4. Browse → **Trusted Root Certification Authorities** → Finish

After installing, restart your browser.

## Firewall Setup

Lock down the container so only SSH and HTTPS are reachable from the network:

```bash
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22    # SSH
sudo ufw allow 443   # HTTPS (nginx → noVNC)
sudo ufw enable
sudo ufw status
```

> **Note:** After enabling the firewall, the OpenClaw dashboard on port 18789 and raw noVNC on port 6080 are no longer directly accessible. Access the dashboard through the nginx proxy or via an SSH tunnel if needed.

## Clipboard Usage in noVNC

Browser security restricts direct clipboard access. There are two ways to copy and paste between your local machine and the remote desktop.

### Option A — noVNC clipboard panel (always works)

The noVNC interface has a built-in clipboard panel in the left-side control bar:

1. Click the **arrow icon** on the left edge of the screen to open the control bar
2. Click the **clipboard icon** (looks like a notepad)
3. To **paste into the remote desktop**: type or paste text into the clipboard panel, then right-click inside the remote desktop and choose Paste
4. To **copy from the remote desktop**: select text inside the remote desktop, then open the clipboard panel — the selected text appears there and can be copied to your local clipboard

### Option B — automatic clipboard sync (requires HTTPS)

When accessing noVNC over HTTPS with a trusted certificate, the browser can sync the clipboard automatically:

1. Open the noVNC control bar (left arrow)
2. Open **Settings** → enable **Clipboard** if it is not already on
3. The browser will ask for clipboard permission — click **Allow**
4. Copy/paste now works directly without using the clipboard panel

> **Tip:** If the browser does not ask for clipboard permission, make sure you are accessing noVNC over `https://` and that the certificate is trusted. HTTP blocks clipboard API entirely in modern browsers.

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

**Clipboard not working?**
Make sure you are accessing noVNC over HTTPS with a trusted certificate. HTTP blocks clipboard API in all modern browsers. See the [HTTPS Setup](#https-setup-recommended) and [Clipboard Usage](#clipboard-usage-in-novnc) sections above.

**nginx not starting?**
```bash
sudo nginx -t          # Check config syntax
sudo journalctl -u nginx --no-pager -n 50
```

## License

MIT License. See [LICENSE](LICENSE) for details.