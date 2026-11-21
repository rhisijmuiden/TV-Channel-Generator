#!/usr/bin/env bash
# Builds the Proxmox VE container (CT) template: a Debian 13 root file system with Beeldkrant
# installed by install/debian.sh, packed as a .tar.zst that Proxmox lists under CT Templates.
# Every container made from it creates its own admin account and one-time password on its first boot.
#
# Needs root, mmdebstrap and zstd (Debian or Ubuntu: apt install mmdebstrap zstd debian-archive-keyring).
#
#   sudo build/lxc/build-template.sh [output dir]       (default: ./dist)
#
# Settings (environment variables):
#     BEELDKRANT_CHANNEL=stable|test   release channel the containers start on (default stable)
#     ARCH=amd64                       Debian architecture (default amd64)
#     MIRROR=http://deb.debian.org/debian
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$(mkdir -p "${1:-$REPO_DIR/dist}" && cd "${1:-$REPO_DIR/dist}" && pwd)"
ARCH="${ARCH:-amd64}"
SUITE=trixie
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"
CHANNEL="${BEELDKRANT_CHANNEL:-stable}"
VERSION="$(node -p "require('$REPO_DIR/package.json').version" 2>/dev/null || sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$REPO_DIR/package.json" | head -n 1)"
# A fixed name, so https://github.com/<repo>/releases/latest/download/<name>.tar.zst always gives the
# newest template (Proxmox: CT Templates → Download from URL). The version is in /etc/beeldkrant-template.
NAME="beeldkrant-debian-13-${ARCH}"
ROOTFS="$(mktemp -d /var/tmp/beeldkrant-rootfs.XXXXXX)"
trap 'rm -rf "$ROOTFS"' EXIT

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v mmdebstrap >/dev/null || { echo "mmdebstrap is missing (apt install mmdebstrap)." >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is missing (apt install zstd)." >&2; exit 1; }
[[ -d "$REPO_DIR/.git" ]] || { echo "$REPO_DIR is not a git checkout." >&2; exit 1; }

# A system container like Proxmox's own Debian template: systemd, ifupdown (Proxmox writes
# /etc/network/interfaces), DHCP, SSH (Proxmox makes new host keys for each container) and some tools.
PACKAGES=(
  systemd systemd-sysv dbus libpam-systemd ifupdown dhcpcd-base iproute2 iputils-ping
  openssh-server ca-certificates curl wget less nano procps tzdata locales cron logrotate
  apt-utils bash-completion
)

echo "Building $NAME.tar.zst from $(git -C "$REPO_DIR" rev-parse --short HEAD)"
mmdebstrap \
  --variant=minbase \
  --architectures="$ARCH" \
  --include="$(IFS=,; echo "${PACKAGES[*]}")" \
  --setup-hook='mkdir -p "$1/opt/beeldkrant-src"' \
  --customize-hook="sync-in '$REPO_DIR' /opt/beeldkrant-src" \
  --customize-hook='chroot "$1" env BEELDKRANT_TEMPLATE=1 BEELDKRANT_SOURCE=/opt/beeldkrant-src BEELDKRANT_CHANNEL='"$CHANNEL"' bash /opt/beeldkrant-src/install/debian.sh' \
  --customize-hook='rm -rf "$1/opt/beeldkrant-src"' \
  "$SUITE" "$ROOTFS" \
  "deb $MIRROR $SUITE main" \
  "deb $MIRROR $SUITE-updates main" \
  "deb $SECURITY $SUITE-security main"

# Make it a clean template: Proxmox sets the host name, network, DNS, root password and SSH host
# keys per container; systemd makes a new machine id on first boot.
echo "Cleaning up the root file system"
cat >"$ROOTFS/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian $SUITE main
deb http://deb.debian.org/debian $SUITE-updates main
deb http://security.debian.org/debian-security $SUITE-security main
EOF
echo 'en_US.UTF-8 UTF-8' >"$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen >/dev/null
echo 'LANG=en_US.UTF-8' >"$ROOTFS/etc/default/locale"
ln -sf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
echo 'Etc/UTC' >"$ROOTFS/etc/timezone"
printf 'auto lo\niface lo inet loopback\n' >"$ROOTFS/etc/network/interfaces"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
: >"$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
echo localhost >"$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' >"$ROOTFS/etc/hosts"
rm -f "$ROOTFS/etc/resolv.conf"; : >"$ROOTFS/etc/resolv.conf"
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin "$ROOTFS"/var/cache/apt/archives/*.deb
rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* "$ROOTFS"/root/.npm "$ROOTFS"/root/.cache
find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} +
rm -f "$ROOTFS/var/log/beeldkrant-install.log"
# What the template is, for `cat /etc/beeldkrant-template` inside a container.
cat >"$ROOTFS/etc/beeldkrant-template" <<EOF
Beeldkrant $VERSION container template ($NAME)
Built from $(git -C "$REPO_DIR" rev-parse HEAD) on $(date -u +%Y-%m-%dT%H:%M:%SZ)
Release channel: $CHANNEL
EOF

echo "Packing $OUT_DIR/$NAME.tar.zst"
tar --numeric-owner --xattrs --acls -C "$ROOTFS" -cf - . | zstd -q -T0 -19 -o "$OUT_DIR/$NAME.tar.zst" -f
(cd "$OUT_DIR" && sha256sum "$NAME.tar.zst" >"$NAME.tar.zst.sha256")
ls -lh "$OUT_DIR/$NAME.tar.zst"
echo "$OUT_DIR/$NAME.tar.zst"
