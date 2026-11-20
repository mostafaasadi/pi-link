#!/bin/bash
set -euo pipefail

SCRIPT_NAME="pi-link"
SERVICE_NAME="pi-link.service"
TIMER_NAME="pi-link.timer"
BIN_DEST="/usr/local/bin/${SCRIPT_NAME}"
UNIT_DIR="/etc/systemd/system"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WIRED_CON="Wired failover"
WIFI_CON="WIFI"
ETH="eth0"
WLAN="wlan0"
VIP="192.168.1.14/24"
GATEWAY="192.168.1.1"
DNS="192.168.1.1"
INTERVAL=15
ASSUME_YES=0
MODE="install"

log() { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --uninstall) MODE="uninstall" ;;
        *) die "unknown option: $arg" ;;
    esac
done

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi

if [[ "$MODE" == "uninstall" ]]; then
    systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "${UNIT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${TIMER_NAME}" "$BIN_DEST"
    rm -f /run/pi-link.state /run/pi-link.lock
    systemctl daemon-reload
    nmcli connection modify "$WIFI_CON" connection.autoconnect yes 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    log "Uninstalled. WiFi autoconnect restored."
    exit 0
fi

command -v nmcli >/dev/null 2>&1 || die "nmcli not found"
systemctl is-active --quiet NetworkManager || die "NetworkManager is not running"
[[ -f "${SRC_DIR}/${SCRIPT_NAME}" ]] || die "${SCRIPT_NAME} not found next to installer"
bash -n "${SRC_DIR}/${SCRIPT_NAME}" || die "watchdog script has syntax errors"

if ip -4 addr show dev "$WLAN" 2>/dev/null | grep -q "${VIP%%/*}/" && [[ "$(cat /sys/class/net/$ETH/carrier 2>/dev/null)" == "1" ]]; then
    warn "Current path is WiFi and cable is present: installing will move to wired and turn the WiFi radio off (SSH over WiFi will drop)."
    if (( ! ASSUME_YES )); then
        read -r -p "Continue? [y/N] " answer
        [[ "$answer" == "y" || "$answer" == "Y" ]] || die "aborted by user"
    fi
fi

log "Installing script to ${BIN_DEST}"
install -m 0755 "${SRC_DIR}/${SCRIPT_NAME}" "$BIN_DEST"

log "Writing systemd units"
cat > "${UNIT_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=Station network failover watchdog (wired preferred, wifi standby)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=${BIN_DEST}
TimeoutStartSec=90
Nice=10
EOF

cat > "${UNIT_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Run station failover watchdog every ${INTERVAL}s

[Timer]
OnBootSec=${INTERVAL}s
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5s
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
printf '0 0 0 0\n' > /run/pi-link.state
rm -f /run/pi-link.lock

log "Configuring NetworkManager profiles"
if nmcli -t -f NAME connection show | grep -qx "$WIRED_CON"; then
    nmcli connection modify "$WIRED_CON" \
        connection.interface-name "$ETH" \
        ipv4.method manual ipv4.addresses "$VIP" \
        ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
        connection.autoconnect yes connection.autoconnect-priority 100
else
    warn "profile '$WIRED_CON' not found; create it before relying on wired"
fi

if nmcli -t -f NAME connection show | grep -qx "$WIFI_CON"; then
    nmcli connection modify "$WIFI_CON" \
        connection.interface-name "$WLAN" \
        ipv4.method manual ipv4.addresses "$VIP" \
        ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" \
        connection.autoconnect no 802-11-wireless.powersave 2
else
    warn "profile '$WIFI_CON' not found; wifi failover will not work until it exists"
fi

systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
systemctl reset-failed "$SERVICE_NAME" "$TIMER_NAME" 2>/dev/null || true
systemctl enable --now "$TIMER_NAME"

log "Smoke test: running watchdog once"
if "$BIN_DEST"; then
    log "Watchdog executed OK"
else
    warn "Watchdog exited non-zero (check: journalctl -t pi-link)"
fi

log "Timer status:"
systemctl list-timers --all | grep "$TIMER_NAME" || true
log "Last log lines:"
journalctl -t pi-link -n 5 --no-pager || true
log "Current addresses:"
ip -4 addr show dev "$ETH" | grep inet || true
ip -4 addr show dev "$WLAN" | grep inet || true
nmcli radio || true
log "Done. Emergency stop: sudo systemctl stop ${TIMER_NAME} && sudo nmcli radio wifi on"
