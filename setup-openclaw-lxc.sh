#!/usr/bin/env bash
#
# setup-openclaw-lxc.sh — Automated OpenClaw AI assistant setup in a Proxmox LXC container
#
# Run this script directly on the Proxmox host.
# It creates a Debian 13 LXC, installs OpenClaw + XFCE desktop + VNC/noVNC,
# and prints connection info when done.
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
echo -e "${BOLD}║     OpenClaw LXC Setup for Proxmox               ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo

read -rp "Container password: " -s CT_PASSWORD
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

# Find template storage (supports vztmpl content)
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

# Find rootdir storage (prefer local-lvm, then any with rootdir)
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
info "Creating LXC container $VMID..."
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
ok "Container $VMID created."

info "Starting container $VMID..."
pct start "$VMID"
ok "Container started."

info "Waiting for container to boot..."
sleep 3

# Helper: run a command inside the container
ct_exec() {
    pct exec "$VMID" -- bash -c "$1"
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

    # Fix locale warnings
    apt-get update && apt-get install -y locales 2>&1 | grep -v 'Failed to write'
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    apt-get upgrade -y 2>&1 | grep -v 'Failed to write'
    apt-get install -y curl ca-certificates gnupg git 2>&1 | grep -v 'Failed to write'
"
ok "Prerequisites installed."

info "Installing Node.js 22..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
    apt-get install -y nodejs 2>&1 | grep -v 'Failed to write'
"
ok "Node.js installed."

info "Installing OpenClaw..."
ct_exec "npm install -g openclaw@latest 2>&1 | tail -5"
ok "OpenClaw installed."

info "Installing XFCE4, TigerVNC, noVNC, Chromium, dbus-x11 (this takes a few minutes)..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    apt-get install -y xfce4 xfce4-terminal tigervnc-standalone-server novnc websockify chromium dbus-x11 2>&1 \
        | grep -v -E 'Failed to write|Failed to send reload|Permission denied|Cannot set LC_'
"
ok "Desktop environment installed."

# ─── Configure OpenClaw ──────────────────────────────────────────────────────
info "Configuring OpenClaw..."
AUTH_TOKEN=$(openssl rand -hex 16)

ct_exec "
    openclaw config set gateway.mode local
    openclaw config set gateway.bind lan
    openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
    openclaw config set gateway.auth.token '${AUTH_TOKEN}'
"
ok "OpenClaw configured (token: $AUTH_TOKEN)."

# ─── Configure VNC ───────────────────────────────────────────────────────────
info "Configuring VNC..."
ct_exec "
    mkdir -p /root/.config/tigervnc
    echo '${CT_PASSWORD}' | vncpasswd -f > /root/.config/tigervnc/passwd
    chmod 600 /root/.config/tigervnc/passwd
"

ct_exec "cat > /root/.config/tigervnc/xstartup << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XSTARTUP
chmod +x /root/.config/tigervnc/xstartup"
ok "VNC configured."

# ─── Fix Chromium for LXC (--no-sandbox) ─────────────────────────────────────
info "Patching Chromium for LXC..."
ct_exec "
    sed -i 's|Exec=/usr/bin/chromium|Exec=/usr/bin/chromium --no-sandbox|g' /usr/share/applications/chromium.desktop

    cat > /usr/local/bin/chromium-browser << 'WRAPPER'
#!/bin/bash
exec /usr/bin/chromium --no-sandbox \"\$@\"
WRAPPER
    chmod +x /usr/local/bin/chromium-browser

    mkdir -p /root/Desktop
    cp /usr/share/applications/chromium.desktop /root/Desktop/
    chmod +x /root/Desktop/chromium.desktop
"
ok "Chromium patched."

# ─── Create desktop shortcuts ────────────────────────────────────────────────
info "Creating desktop shortcuts..."

# OpenClaw Onboarding wizard (runs in terminal)
ct_exec "cat > /root/Desktop/openclaw-onboard.desktop << 'SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Setup Wizard
Comment=Run the OpenClaw onboarding wizard to configure your AI assistant
Exec=xfce4-terminal --title \"OpenClaw Onboarding\" --hold -e \"openclaw onboard\"
Icon=utilities-terminal
Terminal=false
Categories=Utility;
StartupNotify=true
SHORTCUT
chmod +x /root/Desktop/openclaw-onboard.desktop"

# OpenClaw Dashboard (opens in Chromium with token)
ct_exec "cat > /root/Desktop/openclaw-dashboard.desktop << SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Dashboard
Comment=Open the OpenClaw Control UI in Chromium
Exec=/usr/bin/chromium --no-sandbox http://127.0.0.1:18789/#token=${AUTH_TOKEN}
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
SHORTCUT
chmod +x /root/Desktop/openclaw-dashboard.desktop"

ok "Desktop shortcuts created."

# ─── Create systemd services ─────────────────────────────────────────────────
info "Creating systemd services..."

ct_exec "cat > /etc/systemd/system/openclaw-gateway.service << 'SVC'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
ExecStart=/bin/openclaw gateway run --bind lan --auth token
Restart=always
RestartSec=5
Environment=NODE_ENV=production
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "cat > /etc/systemd/system/vncserver.service << SVC
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
Environment=HOME=/root
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
    systemctl enable --now openclaw-gateway.service
    systemctl enable --now vncserver.service
    systemctl enable --now novnc.service
"
ok "All services enabled and started."

sleep 3

# ─── Verify services ─────────────────────────────────────────────────────────
info "Verifying services..."
for svc in openclaw-gateway vncserver novnc; do
    if ct_exec "systemctl is-active --quiet $svc"; then
        ok "$svc is running."
    else
        warn "$svc failed to start. Check with: pct exec $VMID -- systemctl status $svc"
    fi
done

# Re-detect IP in case it changed
CT_IP=$(ct_exec "hostname -I 2>/dev/null" | awk '{print $1}' || echo "unknown")

# ─── Print connection info ────────────────────────────────────────────────────
echo
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           OpenClaw LXC Setup Complete!            ║${NC}"
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
echo
echo -e "  ${BOLD}SSH:${NC}"
echo -e "    ssh root@${CT_IP}"
echo
echo -e "  ${BOLD}Manage container:${NC}"
echo -e "    pct enter $VMID"
echo -e "    pct stop $VMID"
echo -e "    pct start $VMID"
echo
