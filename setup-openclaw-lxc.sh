#!/usr/bin/env bash
#
# setup-openclaw-lxc.sh — Automated OpenClaw AI assistant setup in an unprivileged Proxmox LXC container
#
# Run this script directly on the Proxmox host.
# It creates an UNPRIVILEGED Debian 13 LXC with nesting, installs OpenClaw + LXQt desktop +
# Google Chrome + VNC/noVNC, and prints connection info when done.
#
# Changes vs original:
#   - unprivileged=1 + nesting=1
#   - openclaw runs as dedicated non-root user 'openclaw'
#   - Chrome runs as 'openclaw' user (no root, no --no-sandbox needed)
#   - VNC runs as 'openclaw' user
#   - gateway systemd service runs as 'openclaw' with DISPLAY=:1
#   - brewuser sudo scope limited to brew binary only
#   - removed broken 'openclaw browser extension install' call
#

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal() { err "$@"; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
command -v pct  >/dev/null 2>&1 || fatal "pct not found — this script must run on a Proxmox host."
command -v pvesh >/dev/null 2>&1 || fatal "pvesh not found — this script must run on a Proxmox host."
command -v pveam >/dev/null 2>&1 || fatal "pveam not found — this script must run on a Proxmox host."
[[ $(id -u) -eq 0 ]] || fatal "This script must be run as root."

# ─── User prompts ────────────────────────────────────────────────────────────
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  OpenClaw LXC Setup for Proxmox (unprivileged)   ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo

read -rp "Container password (for root + openclaw user): " -s CT_PASSWORD
echo
[[ -n "$CT_PASSWORD" ]] || fatal "Password cannot be empty."

read -rp "Disk size in GB [32]: " DISK_SIZE
DISK_SIZE="${DISK_SIZE:-32}"

read -rp "Memory in MB [4096]: " MEMORY
MEMORY="${MEMORY:-4096}"

read -rp "CPU cores [4]: " CORES
CORES="${CORES:-4}"

read -rp "VNC resolution [1920x1080]: " VNC_RES
VNC_RES="${VNC_RES:-1920x1080}"

read -rp "Admin Linux username (full sudo, SSH key login): " ADMIN_USER
[[ -n "$ADMIN_USER" ]] || fatal "Admin username cannot be empty."

read -rp "SSH public key for ${ADMIN_USER} (paste full public key): " ADMIN_SSH_KEY
[[ -n "$ADMIN_SSH_KEY" ]] || fatal "SSH public key cannot be empty."

echo

# ─── Auto-detect next VMID ───────────────────────────────────────────────────
info "Detecting next available VMID..."
VMID=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
ids = [r["vmid"] for r in data if "vmid" in r]
print(max(ids) + 1 if ids else 100)
' 2>/dev/null || echo 100)
ok "Will use VMID: $VMID"

# ─── Auto-detect storage ─────────────────────────────────────────────────────
info "Detecting storage..."

TMPL_STORAGE=$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c '
import json, sys
stores = json.load(sys.stdin)
for s in stores:
    content = s.get("content", "")
    if "vztmpl" in content:
        print(s["storage"])
        break
' 2>/dev/null || echo "local")

ROOT_STORAGE=$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c '
import json, sys
stores = json.load(sys.stdin)
candidates = []
for s in stores:
    content = s.get("content", "")
    if "rootdir" in content or "images" in content:
        candidates.append(s["storage"])
if "local-lvm" in candidates:
    print("local-lvm")
elif candidates:
    print(candidates[0])
else:
    print("local-lvm")
' 2>/dev/null || echo "local-lvm")

ok "Template storage: $TMPL_STORAGE"
ok "Rootfs storage:   $ROOT_STORAGE"

# ─── Download Debian 13 template ─────────────────────────────────────────────
info "Checking for Debian 13 template..."
pveam update >/dev/null 2>&1 || true

TEMPLATE=$(pveam available --section system 2>/dev/null | grep -oP 'debian-13-standard_\S+' | head -1 || true)
if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE=$(pveam available 2>/dev/null | grep -oP 'debian-13-standard_\S+' | head -1 || true)
fi
[[ -n "$TEMPLATE" ]] || fatal "Could not find Debian 13 template. Check 'pveam available'."

if pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    ok "Template already downloaded: $TEMPLATE"
else
    info "Downloading $TEMPLATE to $TMPL_STORAGE..."
    pveam download "$TMPL_STORAGE" "$TEMPLATE"
    ok "Template downloaded."
fi

# ─── Create the LXC container ────────────────────────────────────────────────
info "Creating unprivileged LXC container $VMID with nesting..."
pct create "$VMID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname openclaw \
    --password "$CT_PASSWORD" \
    --rootfs "${ROOT_STORAGE}:${DISK_SIZE}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 1 \
    --features nesting=1 \
    --start 0
ok "Container $VMID created (unprivileged, nesting enabled)."

info "Starting container $VMID..."
pct start "$VMID"
ok "Container started."

info "Waiting for container to boot..."
sleep 5

# Helper: run a command inside the container as root
ct_exec() {
    pct exec "$VMID" -- bash -c "$1"
}

# Helper: run a command as the openclaw user
ct_exec_user() {
    pct exec "$VMID" -- su - openclaw -c "$1"
}

# ─── Wait for network ────────────────────────────────────────────────────────
info "Waiting for DHCP lease (up to 30s)..."
CT_IP=""
for i in $(seq 1 30); do
    CT_IP=$(ct_exec "hostname -I 2>/dev/null" | awk '{print $1}' || true)
    if [[ -n "$CT_IP" && "$CT_IP" != "127.0.0.1" ]]; then
        break
    fi
    CT_IP=""
    sleep 1
done
[[ -n "$CT_IP" ]] || warn "Could not detect container IP — continuing anyway."
ok "Container IP: ${CT_IP:-unknown}"

# ─── Install packages inside the container ────────────────────────────────────
info "Updating packages and installing prerequisites..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive

    apt-get update && apt-get install -y locales openssh-server 2>&1 | grep -v 'Failed to write'
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    apt-get upgrade -y 2>&1 | grep -v 'Failed to write'
    apt-get install -y curl ca-certificates gnupg git sudo 2>&1 | grep -v 'Failed to write'
"
ok "Prerequisites installed."

# ─── Create openclaw user ────────────────────────────────────────────────────
info "Creating 'openclaw' user..."
ct_exec "
    useradd -m -s /bin/bash openclaw 2>/dev/null || true
    echo 'openclaw:${CT_PASSWORD}' | chpasswd

    # Allow openclaw to run specific commands via sudo (no full root)
    cat > /etc/sudoers.d/openclaw << 'SUDOERS'
openclaw ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/sbin/service, /bin/systemctl
SUDOERS
    chmod 440 /etc/sudoers.d/openclaw
"
ok "User 'openclaw' created."

# ─── Create admin user ───────────────────────────────────────────────────────
info "Creating admin user '${ADMIN_USER}'..."
ct_exec "
    useradd -m -s /bin/bash '${ADMIN_USER}' 2>/dev/null || true
    echo '${ADMIN_USER}:${CT_PASSWORD}' | chpasswd

    # Full passwordless sudo
    cat > /etc/sudoers.d/${ADMIN_USER} << SUDOERS
${ADMIN_USER} ALL=(ALL) NOPASSWD: ALL
SUDOERS
    chmod 440 /etc/sudoers.d/${ADMIN_USER}

    # SSH public key
    mkdir -p /home/${ADMIN_USER}/.ssh
    chmod 700 /home/${ADMIN_USER}/.ssh
    printf '%s\n' '${ADMIN_SSH_KEY}' > /home/${ADMIN_USER}/.ssh/authorized_keys
    chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys
    chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh
"
ok "Admin user '${ADMIN_USER}' created with full sudo."

# ─── Configure SSH ───────────────────────────────────────────────────────────
info "Configuring SSH (disable password auth, enable key auth)..."
ct_exec "
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    # Ensure the directive exists if not already present
    grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    systemctl enable ssh
    systemctl restart ssh
"
ok "SSH configured (password login disabled)."

info "Installing Node.js 22..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
    apt-get install -y nodejs 2>&1 | grep -v 'Failed to write'
"
ok "Node.js installed."

info "Installing Homebrew (required for OpenClaw skills)..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y build-essential procps file 2>&1 | grep -v -E 'Failed to write|Permission denied'

    # Create brewuser with sudo limited to brew binary only
    useradd -m -s /bin/bash brewuser 2>/dev/null || true
    cat > /etc/sudoers.d/brewuser << 'SUDOERS'
brewuser ALL=(ALL) NOPASSWD: /home/linuxbrew/.linuxbrew/bin/brew
SUDOERS
    chmod 440 /etc/sudoers.d/brewuser

    su - brewuser -c 'NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' 2>&1 | tail -5

    # Make brew available system-wide
    echo '[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"' >> /home/openclaw/.bashrc
    echo '[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"' >> /root/.bashrc
    ln -sf /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew
"
ok "Homebrew installed."

info "Installing OpenClaw..."
ct_exec "npm install -g openclaw@latest 2>&1 | tail -5"
# Make openclaw binary accessible to openclaw user
ct_exec "ln -sf \$(which openclaw) /usr/local/bin/openclaw 2>/dev/null || true"
ok "OpenClaw installed."

info "Installing LXQt, TigerVNC, noVNC (this takes a few minutes)..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    apt-get install -y lxqt openbox lxterminal tigervnc-standalone-server novnc websockify dbus-x11 fonts-noto-color-emoji 2>&1 \
        | grep -v -E 'Failed to write|Failed to send reload|Permission denied|Cannot set LC_'
"
ok "Desktop environment installed."

info "Installing Google Chrome..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
    apt-get install -y /tmp/chrome.deb 2>&1 | grep -v -E 'Failed to write|Permission denied'
    rm -f /tmp/chrome.deb
"
ok "Google Chrome installed."

# ─── Configure Google Chrome ─────────────────────────────────────────────────
info "Configuring Google Chrome..."
ct_exec "
    mkdir -p /home/openclaw/Desktop
    cp /usr/share/applications/google-chrome.desktop /home/openclaw/Desktop/
    chown openclaw:openclaw /home/openclaw/Desktop/google-chrome.desktop

    # Make google-chrome available as a command (points to stable binary)
    ln -sf /usr/bin/google-chrome-stable /usr/local/bin/google-chrome 2>/dev/null || true

    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
    update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
"
ok "Google Chrome configured."

# ─── Configure OpenClaw ──────────────────────────────────────────────────────
info "Configuring OpenClaw..."
AUTH_TOKEN=$(openssl rand -hex 16)

# OpenClaw state lives in openclaw user's home
ct_exec "
    mkdir -p /home/openclaw/.openclaw
    chown -R openclaw:openclaw /home/openclaw/.openclaw
"

ct_exec_user "
    openclaw config set gateway.mode local
    openclaw config set gateway.bind lan
    openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
    openclaw config set gateway.auth.token '${AUTH_TOKEN}'
"
ok "OpenClaw configured (token: $AUTH_TOKEN)."

# ─── Configure VNC ───────────────────────────────────────────────────────────
info "Configuring VNC..."
ct_exec "
    mkdir -p /home/openclaw/.config/tigervnc
    echo '${CT_PASSWORD}' | vncpasswd -f > /home/openclaw/.config/tigervnc/passwd
    chmod 600 /home/openclaw/.config/tigervnc/passwd
    chown -R openclaw:openclaw /home/openclaw/.config/tigervnc
"

ct_exec "cat > /home/openclaw/.config/tigervnc/xstartup << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startlxqt
XSTARTUP
chmod +x /home/openclaw/.config/tigervnc/xstartup
chown openclaw:openclaw /home/openclaw/.config/tigervnc/xstartup"

# Configure lxterminal with dark theme
ct_exec "
    mkdir -p /home/openclaw/.config/lxterminal
    cat > /home/openclaw/.config/lxterminal/lxterminal.conf << 'CONF'
[general]
fontname=Monospace 12
bgcolor=#1e1e2e
fgcolor=#cdd6f4
palette_color_0=#45475a
palette_color_1=#f38ba8
palette_color_2=#a6e3a1
palette_color_3=#f9e2af
palette_color_4=#89b4fa
palette_color_5=#f5c2e7
palette_color_6=#94e2d5
palette_color_7=#bac2de
palette_color_8=#585b70
palette_color_9=#f38ba8
palette_color_10=#a6e3a1
palette_color_11=#f9e2af
palette_color_12=#89b4fa
palette_color_13=#f5c2e7
palette_color_14=#94e2d5
palette_color_15=#a6adc8
scrollback=10000
CONF
    chown -R openclaw:openclaw /home/openclaw/.config/lxterminal
"

# Set noVNC scaling to auto by default
ct_exec "sed -i \"s/UI.initSetting('resize', 'off')/UI.initSetting('resize', 'scale')/\" /usr/share/novnc/app/ui.js 2>/dev/null || true"
ok "VNC configured."

# ─── Disable LXC-incompatible LXQt components ───────────────────────────────
info "Disabling LXC-incompatible LXQt components..."
ct_exec "
    mkdir -p /home/openclaw/.config/autostart
    cat > /home/openclaw/.config/autostart/lxqt-powermanagement.desktop << 'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Power Management
Hidden=true
NOAUTO
    cat > /home/openclaw/.config/autostart/lxqt-xscreensaver-autostart.desktop << 'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Screen Saver
Hidden=true
NOAUTO
    chown -R openclaw:openclaw /home/openclaw/.config/autostart
"
ok "LXC-incompatible components disabled."

# ─── Configure LXQt default terminal ─────────────────────────────────────────
info "Setting lxterminal as default terminal..."
ct_exec "
    mkdir -p /home/openclaw/.config/lxqt
    cat > /home/openclaw/.config/lxqt/session.conf << 'CONF'
[General]
__userfile__=true

[Environment]
TERM=xterm-256color

[Preferred Applications]
terminal_emulator=lxterminal
CONF
    chown -R openclaw:openclaw /home/openclaw/.config/lxqt
"
ok "Default terminal configured."

# ─── Create desktop shortcuts ────────────────────────────────────────────────
info "Creating desktop shortcuts..."

ct_exec "
    mkdir -p /home/openclaw/Desktop

    cat > /home/openclaw/Desktop/terminal.desktop << 'SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open a terminal
Exec=lxterminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
StartupNotify=true
SHORTCUT

    cat > /home/openclaw/Desktop/openclaw-onboard.desktop << 'SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Setup Wizard
Comment=Run the OpenClaw onboarding wizard to configure your AI assistant
Exec=lxterminal --title='OpenClaw Onboarding' -e sh -c 'openclaw onboard; exec bash'
Icon=utilities-terminal
Terminal=false
Categories=Utility;
StartupNotify=true
SHORTCUT

    chown -R openclaw:openclaw /home/openclaw/Desktop
    chmod +x /home/openclaw/Desktop/*.desktop
"

# Dashboard shortcut (AUTH_TOKEN interpolated on host side)
ct_exec "cat > /home/openclaw/Desktop/openclaw-dashboard.desktop << SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Dashboard
Comment=Open the OpenClaw Control UI in Google Chrome
Exec=google-chrome http://127.0.0.1:18789/#token=${AUTH_TOKEN}
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
SHORTCUT
chmod +x /home/openclaw/Desktop/openclaw-dashboard.desktop
chown openclaw:openclaw /home/openclaw/Desktop/openclaw-dashboard.desktop"

# Mark desktop files as trusted — dbus-launch spawns a temporary bus and auto-activates
# gvfsd-metadata, so this works at install time without a running VNC session
ct_exec "su - openclaw -c 'for f in /home/openclaw/Desktop/*.desktop; do dbus-launch gio set \"\$f\" metadata::trust true; done' 2>/dev/null || true"
ok "Desktop shortcuts created and marked trusted."

# ─── Create systemd services ─────────────────────────────────────────────────
info "Creating systemd services..."

# Gateway service — runs as openclaw user, DISPLAY=:1 set for browser support
ct_exec "cat > /etc/systemd/system/openclaw-gateway.service << 'SVC'
[Unit]
Description=OpenClaw Gateway
After=network.target vncserver.service
Wants=vncserver.service

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=NODE_ENV=production
Environment=DISPLAY=:1
Environment=HOME=/home/openclaw
WorkingDirectory=/home/openclaw
ExecStart=/usr/local/bin/openclaw gateway run --bind lan --auth token
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC"

# VNC service — runs as openclaw user
ct_exec "cat > /etc/systemd/system/vncserver.service << SVC
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
ExecStartPre=/bin/sh -c \"/usr/bin/vncserver -kill :1 > /dev/null 2>&1 || :\"
ExecStart=/usr/bin/vncserver :1 -geometry ${VNC_RES} -depth 24 -localhost yes
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "cat > /etc/systemd/system/novnc.service << 'SVC'
[Unit]
Description=noVNC WebSocket Proxy
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
ExecStart=/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "
    systemctl daemon-reload
    systemctl enable --now vncserver.service
    sleep 3
    systemctl enable --now openclaw-gateway.service
    systemctl enable --now novnc.service
"
ok "All services enabled and started."

sleep 5

# ─── Verify services ─────────────────────────────────────────────────────────
info "Verifying services..."
for svc in vncserver openclaw-gateway novnc; do
    if ct_exec "systemctl is-active --quiet $svc"; then
        ok "$svc is running."
    else
        warn "$svc failed to start. Check with: pct exec $VMID -- systemctl status $svc"
    fi
done

# Re-detect IP
CT_IP=$(ct_exec "hostname -I 2>/dev/null" | awk '{print $1}' || echo "unknown")

# ─── Print connection info ────────────────────────────────────────────────────
echo
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        OpenClaw LXC Setup Complete!               ║${NC}"
echo -e "${BOLD}║        (unprivileged container)                   ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Container ID:${NC}  $VMID"
echo -e "  ${BOLD}Container IP:${NC}  $CT_IP"
echo
echo -e "  ${BOLD}OpenClaw Dashboard:${NC}"
echo -e "    http://${CT_IP}:18789/"
echo -e "    Auth token: ${CYAN}${AUTH_TOKEN}${NC}"
echo
echo -e "  ${BOLD}noVNC (remote desktop):${NC}"
echo -e "    http://${CT_IP}:6080/vnc.html"
echo -e "    VNC password: (same as container password)"
echo -e "    User: openclaw (non-root)"
echo
echo -e "  ${BOLD}SSH:${NC}"
echo -e "    ssh ${ADMIN_USER}@${CT_IP}  (key auth only, password login disabled)"
echo
echo -e "  ${BOLD}Manage container:${NC}"
echo -e "    pct enter $VMID"
echo -e "    pct stop $VMID"
echo -e "    pct start $VMID"
echo
echo -e "  ${BOLD}Security notes:${NC}"
echo -e "    - Container is unprivileged (nesting=1)"
echo -e "    - OpenClaw runs as user 'openclaw', not root"
echo -e "    - Chrome runs as 'openclaw' user (no --no-sandbox needed)"
echo -e "    - SSH password login disabled, key auth only"
echo -e "    - Admin user '${ADMIN_USER}' has full sudo"
echo -e "    - brewuser sudo limited to brew binary only"
echo
