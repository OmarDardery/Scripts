#!/usr/bin/env bash
# Proxmox VE 9: Debian 13 LXC + browser-accessible OrcaSlicer
# https://github.com/OmarDardery/Scripts
set -Eeuo pipefail

CTID="${CTID:-106}"
IP="${IP:-192.168.1.247}"
CIDR="${CIDR:-24}"
GW="${GW:-192.168.1.1}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-debian-13-standard_13.6-1_amd64.tar.zst}"
DISK_GB="${DISK_GB:-24}"
RAM_MB="${RAM_MB:-4096}"
SWAP_MB="${SWAP_MB:-512}"
CORES="${CORES:-2}"
TZ="${TZ:-Africa/Cairo}"
IMAGE="lscr.io/linuxserver/orcaslicer:latest"

die() { echo "ERROR: $*" >&2; exit 1; }
msg() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || die "Run this as root on your Proxmox host."
command -v pct >/dev/null || die "This must be run on a Proxmox VE host (pct missing)."
command -v pvesm >/dev/null || die "pvesm not found."
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
[[ "$IP" =~ ^192\.168\.1\.[0-9]{1,3}$ ]] || die "Expected a 192.168.1.x address. Override IP=... after reviewing networking."
ip -4 addr show dev "$BRIDGE" | grep -q '192.168.1.240/24' || die "$BRIDGE does not have the expected 192.168.1.240/24 host address. Review networking first."
ip -4 route | grep -q "default via $GW " || die "Expected gateway $GW not found."
if pct status "$CTID" >/dev/null 2>&1; then die "CT $CTID already exists. No changes made."; fi
if ping -c 2 -W 1 "$IP" >/dev/null 2>&1; then die "IP $IP responds to ping; choose another unused IP."; fi
if ip neigh show "$IP" | grep -Eq 'lladdr .* (REACHABLE|STALE|DELAY|PROBE|PERMANENT)'; then
  die "IP $IP was found in the neighbor table."
fi
pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "$STORAGE" || die "Storage '$STORAGE' unavailable."
pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_STORAGE" || die "Template storage '$TEMPLATE_STORAGE' unavailable."
pveam list "$TEMPLATE_STORAGE" | grep -Fq "$TEMPLATE" || die "Template $TEMPLATE not found on $TEMPLATE_STORAGE."

echo "OrcaSlicer LXC installation plan:"
echo "  CT: $CTID (unprivileged Debian 13, nesting/keyctl)"
echo "  IP: $IP/$CIDR via $GW on $BRIDGE"
echo "  Disk: $DISK_GB GB on $STORAGE, RAM: $RAM_MB MB, CPU: $CORES"
echo "  URL: https://$IP:3001/"
echo "  Note: Ping cannot guarantee that an IP address is free. Confirm it is outside DHCP allocations."
read -r -p "Have you reserved/verified this IP, and proceed? [y/N] " answer </dev/tty
[[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled."
read -r -p "Web login username [orca]: " WEB_USER </dev/tty
WEB_USER="${WEB_USER:-orca}"
[[ "$WEB_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Use only letters, numbers, _, ., - in username."
read -r -s -p "Web login password (minimum 12 characters): " WEB_PASS </dev/tty
printf '\n'
[[ ${#WEB_PASS} -ge 12 && "$WEB_PASS" != *$'\n'* && "$WEB_PASS" != *$'\r'* ]] || die "Password must be at least 12 characters, without newlines."
read -r -s -p "Confirm password: " WEB_PASS2 </dev/tty
printf '\n'
[[ "$WEB_PASS" == "$WEB_PASS2" ]] || die "Passwords do not match."
unset WEB_PASS2

# Enable rootdir on the existing 'local' storage without removing other content types.
CONTENT="$(pvesm config "$STORAGE" | sed -n 's/^[[:space:]]*content[[:space:]]\+//p' | head -n 1)"
[[ -n "$CONTENT" ]] || die "Cannot determine storage content settings for $STORAGE."
if [[ ",$CONTENT," != *",rootdir,"* ]]; then
  echo "Storage '$STORAGE' currently allows: $CONTENT"
  read -r -p "Add 'rootdir' to allowed content types on this storage? [y/N] " enable </dev/tty
  [[ "$enable" =~ ^[Yy]$ ]] || die "Storage must allow rootdir; cancelled."
  pvesm set "$STORAGE" --content "$CONTENT,rootdir"
fi

msg "Creating CT $CTID"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname orcaslicer --ostype debian --arch amd64 \
  --unprivileged 1 --features nesting=1,keyctl=1 \
  --rootfs "${STORAGE}:${DISK_GB}" --cores "$CORES" \
  --memory "$RAM_MB" --swap "$SWAP_MB" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP}/${CIDR},gw=${GW}" \
  --nameserver "$GW" --onboot 1 --start 1
# Do not destroy the container on failure: preserve logs for diagnosis.

msg "Installing Docker in CT $CTID"
pct exec "$CTID" -- bash -lc 'set -e; export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y docker.io ca-certificates curl; systemctl enable --now docker; docker info >/dev/null'

msg "Saving web authentication securely"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
printf 'CUSTOM_USER=%s\nPASSWORD=%s\n' "$WEB_USER" "$WEB_PASS" > "$TMP"
unset WEB_PASS
pct push "$CTID" "$TMP" /root/orcaslicer.env --perms 0600
rm -f "$TMP"
trap - EXIT

msg "Starting browser-based OrcaSlicer"
pct exec "$CTID" -- mkdir -p /opt/orcaslicer/config
pct exec "$CTID" -- chown 1000:1000 /opt/orcaslicer/config
pct exec "$CTID" -- docker run -d \
  --name orcaslicer --restart unless-stopped \
  --shm-size 1g -p 3001:3001 \
  --env-file /root/orcaslicer.env \
  -e PUID=1000 -e PGID=1000 -e "TZ=$TZ" -e AUTO_GPU=false \
  -v /opt/orcaslicer/config:/config \
  "$IMAGE"

msg "Installing update helper"
pct exec "$CTID" -- bash -lc 'cat > /usr/local/sbin/orcaslicer-update <<'"'"'SCRIPT'"'"'
#!/bin/bash
set -euo pipefail
docker pull lscr.io/linuxserver/orcaslicer:latest
docker rm -f orcaslicer
docker run -d --name orcaslicer --restart unless-stopped \
  --shm-size 1g -p 3001:3001 \
  --env-file /root/orcaslicer.env \
  -e PUID=1000 -e PGID=1000 -e TZ=Africa/Cairo -e AUTO_GPU=false \
  -v /opt/orcaslicer/config:/config \
  lscr.io/linuxserver/orcaslicer:latest
SCRIPT
chmod 700 /usr/local/sbin/orcaslicer-update'
msg "Installation finished"
echo "Open https://$IP:3001/ (accept the self-signed certificate on your trusted LAN)."
echo "Logs: pct exec $CTID -- docker logs --tail 100 orcaslicer"
echo "Update: pct exec $CTID -- /usr/local/sbin/orcaslicer-update"
echo "Security: keep port 3001 LAN-only; basic authentication is not internet-grade."
