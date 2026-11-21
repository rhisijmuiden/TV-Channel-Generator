#!/usr/bin/env bash
# Installs Beeldkrant on a plain Debian 13: bare metal, a VM, a VPS or a system container (an LXC
# container on Proxmox VE or another LXC/Incus host). Asks nothing, so it can also run over SSH
# (Build My TV Station) and is used to build the Proxmox container template (see build/lxc/).
#
# Run as root:
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rhisijmuiden/TV-Channel-Generator/main/install/debian.sh)"
# On a minimal Debian without curl:
#     bash -c "$(wget -qO- https://raw.githubusercontent.com/rhisijmuiden/TV-Channel-Generator/main/install/debian.sh)"
#
# Settings (environment variables):
#     BEELDKRANT_CHANNEL=stable|test   release channel (default stable: the newest GitHub release;
#                               test: every change on main). Can be changed later in the panel.
#     BEELDKRANT_REF=<branch>   install and follow another branch instead of a channel
#     PORT=<port>               port of the admin panel (default 8080; can be changed in the panel)
#     GPU=intel|amd|all|none    VAAPI drivers for hardware H.264 encoding (default: detect)
#     VERBOSE=1                 show everything apt and npm print instead of only the steps
#
# All it prints at the end is the address of the admin panel, the user "admin" and a one-time
# password that must be changed at the first login; everything else is set up in the panel.
# The full log is kept in /var/log/beeldkrant-install.log. On a machine where Beeldkrant is
# already installed it runs `update` instead.
#
# For building images (used by build/lxc/build-template.sh, inside a chroot):
#     BEELDKRANT_TEMPLATE=1     install and enable everything, but start nothing: the service creates
#                               the admin account and its password on the first boot of each copy
#     BEELDKRANT_SOURCE=<dir>   install from this git checkout instead of cloning from GitHub
set -euo pipefail

BEELDKRANT_REPO="${BEELDKRANT_REPO:-https://github.com/rhisijmuiden/TV-Channel-Generator.git}"
BEELDKRANT_REF="${BEELDKRANT_REF:-}"
BEELDKRANT_CHANNEL="${BEELDKRANT_CHANNEL:-stable}"
BEELDKRANT_SOURCE="${BEELDKRANT_SOURCE:-}"
TEMPLATE="${BEELDKRANT_TEMPLATE:-0}"
PORT="${PORT:-8080}"
GPU="${GPU:-auto}"
VERBOSE="${VERBOSE:-0}"
APP_DIR=/opt/beeldkrant
DATA_DIR=/var/lib/beeldkrant
LOG=/var/log/beeldkrant-install.log

if [[ -t 1 ]]; then c_ok=$'\e[1;32m'; c_step=$'\e[1;34m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'; else c_ok=''; c_step=''; c_warn=''; c_err=''; c_off=''; fi
STEP=0
STEPS=6
step() { STEP=$((STEP + 1)); echo "${c_step}[${STEP}/${STEPS}]${c_off} $*"; echo "=== $* ===" >>"$LOG"; }
warn() { echo "${c_warn}[!]${c_off} $*"; }
die() { echo "${c_err}[✗]${c_off} $*" >&2; [[ -s "$LOG" ]] && echo "    The last lines of $LOG:" >&2 && tail -n 15 "$LOG" | sed 's/^/    /' >&2; exit 1; }
# Runs a command with its output in the log only (or on screen with VERBOSE=1).
run() {
  if [[ "$VERBOSE" == "1" ]]; then "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; fi
  "$@" >>"$LOG" 2>&1
}

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "This installer is for Debian 13. Found: ${PRETTY_NAME:-unknown}."
[[ "${VERSION_ID:-}" == "13" ]] || warn "This installer is made for Debian 13; found ${PRETTY_NAME:-unknown}. Continuing anyway."
if [[ "$TEMPLATE" != "1" && ! -d /run/systemd/system ]]; then
  die "Beeldkrant needs systemd. Use a VM, a physical machine or a system container (LXC/Incus); application containers such as Docker are not supported."
fi

if [[ -d "$APP_DIR/.git" ]]; then
  echo "Beeldkrant is already installed; updating it instead."
  exec bash "$APP_DIR/scripts/update.sh"
fi

mkdir -p "$(dirname "$LOG")"
: >"$LOG"
chmod 0600 "$LOG"
export DEBIAN_FRONTEND=noninteractive
echo "Installing Beeldkrant. This takes a few minutes; details are in $LOG."

step "Installing packages (Chromium, ffmpeg, fonts and Node.js)"
run apt-get update || die "apt-get update failed. Is the network up?"
run apt-get install -y \
  git ca-certificates curl pciutils \
  ffmpeg chromium xvfb pulseaudio \
  fonts-dejavu fonts-liberation2 fonts-noto-core fonts-noto-color-emoji \
  nodejs npm || die "Installing the packages failed."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
(( NODE_MAJOR >= 18 )) || die "Node.js 18 or newer is needed; Debian installed $(node -v)."

step "Installing GPU drivers for hardware encoding"
# Hardware H.264 encoding through VAAPI when a GPU is passed through to this machine.
# A template gets both drivers, because it does not know where it will run.
[[ "$TEMPLATE" == "1" && "$GPU" == "auto" ]] && GPU=all
if [[ "$GPU" == "auto" ]]; then
  GPU=none
  if [[ -e /dev/dri/renderD128 ]]; then
    vga="$(lspci 2>/dev/null | grep -iE 'VGA|Display|3D' || true)"
    if grep -qi intel <<<"$vga"; then GPU=intel
    elif grep -qiE 'AMD|ATI' <<<"$vga"; then GPU=amd
    else GPU=all  # inside a container lspci often sees nothing; /dev/dri is enough reason
    fi
  fi
fi
case "$GPU" in
  intel) run apt-get install -y --no-install-recommends intel-media-va-driver vainfo ;;
  amd) run apt-get install -y --no-install-recommends mesa-va-drivers vainfo ;;
  all) run apt-get install -y --no-install-recommends intel-media-va-driver mesa-va-drivers vainfo ;;
  none) echo "    No GPU found; Beeldkrant encodes on the CPU." ;;
  *) die "Unknown GPU=$GPU (use intel, amd, all or none)." ;;
esac || warn "The GPU drivers could not be installed; Beeldkrant encodes on the CPU."

step "Creating the service user"
id beeldkrant &>/dev/null || run useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin beeldkrant
install -d -o beeldkrant -g beeldkrant "$DATA_DIR"
for grp in video render; do getent group "$grp" >/dev/null && run usermod -aG "$grp" beeldkrant; done

# What to install: a local checkout, the pinned branch, the newest release (stable) or main (test,
# or no release yet).
[[ "$BEELDKRANT_CHANNEL" == "test" ]] || BEELDKRANT_CHANNEL="stable"
if [[ -n "$BEELDKRANT_SOURCE" ]]; then
  step "Installing Beeldkrant (from $BEELDKRANT_SOURCE)"
  run git -c advice.detachedHead=false clone --quiet --depth 1 "file://$(cd "$BEELDKRANT_SOURCE" && pwd)" "$APP_DIR" || die "Could not copy $BEELDKRANT_SOURCE."
  git -C "$APP_DIR" remote set-url origin "$BEELDKRANT_REPO"
else
  CLONE_REF="$BEELDKRANT_REF"
  if [[ -z "$CLONE_REF" && "$BEELDKRANT_CHANNEL" == "stable" ]]; then
    CLONE_REF="$(git ls-remote --tags --refs "$BEELDKRANT_REPO" 'refs/tags/v*' 2>>"$LOG" | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
  fi
  CLONE_REF="${CLONE_REF:-main}"
  step "Installing Beeldkrant ($CLONE_REF)"
  run git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$CLONE_REF" "$BEELDKRANT_REPO" "$APP_DIR" || die "Could not download Beeldkrant from $BEELDKRANT_REPO."
fi
echo "$BEELDKRANT_CHANNEL" >"$DATA_DIR/update-channel"
chown beeldkrant:beeldkrant "$DATA_DIR/update-channel"
(cd "$APP_DIR" && run npm ci --omit=dev --no-audit --no-fund --loglevel=error) || die "Installing the Node.js packages failed."
chown -R beeldkrant:beeldkrant "$APP_DIR"

step "Setting up the services"
{
  [[ -n "$BEELDKRANT_REF" ]] && echo "BEELDKRANT_REF=$BEELDKRANT_REF"
  [[ "$PORT" != "8080" ]] && echo "PORT=$PORT"
  true
} >/etc/default/beeldkrant
install -m 0644 "$APP_DIR/deploy/beeldkrant.service" /etc/systemd/system/beeldkrant.service
# The `update` command, and the units that let the admin panel start it.
install -m 0755 "$APP_DIR/scripts/update.sh" /usr/bin/update
install -m 0644 "$APP_DIR/deploy/beeldkrant-update.path" "$APP_DIR/deploy/beeldkrant-update.service" /etc/systemd/system/
# `beeldkrant-station`: connects Beeldkrant to Build My TV Station (see the README).
install -m 0755 "$APP_DIR/scripts/station.sh" /usr/bin/beeldkrant-station
# `beeldkrant-info`: the panel address and one-time password, on the console login screen and at login.
install -m 0755 "$APP_DIR/scripts/info.sh" /usr/bin/beeldkrant-info
install -m 0644 "$APP_DIR/deploy/beeldkrant-welcome.service" /etc/systemd/system/
install -d /etc/update-motd.d
install -m 0755 "$APP_DIR/deploy/motd.sh" /etc/update-motd.d/90-beeldkrant
UNITS=(beeldkrant beeldkrant-update.path beeldkrant-welcome)
if [[ "$TEMPLATE" == "1" ]]; then
  run systemctl enable "${UNITS[@]}"
  step "Done: the template starts Beeldkrant on its first boot"
  exit 0
fi
run systemctl daemon-reload
run systemctl enable --now beeldkrant beeldkrant-update.path || die "Beeldkrant did not start. See: journalctl -u beeldkrant -n 50"
run systemctl enable beeldkrant-welcome

step "Starting Beeldkrant"
for _ in $(seq 1 60); do
  [[ -s "$DATA_DIR/initial-admin-password" ]] && break
  systemctl is-failed --quiet beeldkrant && die "Beeldkrant did not start. See: journalctl -u beeldkrant -n 50"
  sleep 1
done
run systemctl start beeldkrant-welcome || true

/usr/bin/beeldkrant-info --wait
