# pi-link

Network failover watchdog for Raspberry Pi. Keeps your Pi online by automatically switching between wired Ethernet and WiFi.

## What it does

- Prefers wired Ethernet when available
- Falls back to WiFi if wired connection fails
- Maintains a static IP across both interfaces
- Runs as a systemd timer (checks every 15s)
- Disables WiFi radio when wired is healthy (saves power)

## Requirements

- Raspberry Pi OS (or any Debian-based system)
- NetworkManager
- sudo privileges

## Installation

1. Create NetworkManager profiles:
   ```bash
   sudo nmcli connection add con-name "Wired failover" type ethernet ifname eth0 \
       ipv4.method manual ipv4.addresses 192.168.1.14/24 \
       ipv4.gateway 192.168.1.1 ipv4.dns 192.168.1.1 \
       connection.autoconnect yes connection.autoconnect-priority 100
   
   sudo nmcli connection add con-name "WIFI" type wifi ifname wlan0 \
       ssid "YOUR_SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "YOUR_PASSWORD" \
       ipv4.method manual ipv4.addresses 192.168.1.14/24 \
       ipv4.gateway 192.168.1.1 ipv4.dns 192.168.1.1 \
       connection.autoconnect no
   ```

2. Edit `install.sh` to match your network settings (VIP, GATEWAY, DNS, SSID)

3. Run installer:
   ```bash
   ./install.sh
   ```

## Usage

```bash
# Check status
systemctl status pi-link.timer

# View logs
journalctl -t pi-link -f

# Emergency stop (disable watchdog, enable WiFi)
sudo systemctl stop pi-link.timer && sudo nmcli radio wifi on

# Uninstall
sudo ./install.sh --uninstall
```

## Configuration

Edit variables at the top of `pi-link`:
- `VIP`: Static IP address
- `GATEWAY`: Gateway IP
- `DOWN_NEED`: Failed pings before failover (default: 3)
- `SWITCH_COOLDOWN`: Seconds between switches (default: 60)
