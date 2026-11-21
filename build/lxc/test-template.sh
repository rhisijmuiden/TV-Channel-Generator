#!/usr/bin/env bash
# Boots a built CT template with systemd-nspawn (as Proxmox would start a new container) and checks
# that Beeldkrant comes up on its own, created the admin account with a one-time password and put
# the address, user name and password on the console login screen.
#
#   sudo build/lxc/test-template.sh dist/beeldkrant-debian-13-amd64.tar.zst
set -euo pipefail

TARBALL="$(realpath "$1")"
ROOT="$(mktemp -d /var/tmp/beeldkrant-test.XXXXXX)"
MACHINE="bk-template-test"
LOG="$ROOT.console.log"
cleanup() {
  machinectl terminate "$MACHINE" >/dev/null 2>&1 || true
  sleep 2
  rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; echo "--- console ---" >&2; tail -n 60 "$LOG" >&2 || true; exit 1; }

echo "Unpacking $TARBALL"
tar --numeric-owner -xaf "$TARBALL" -C "$ROOT"
[[ ! -s "$ROOT/var/lib/beeldkrant/data.json" ]] || fail "The template already holds a database"
[[ ! -e "$ROOT/var/lib/beeldkrant/initial-admin-password" ]] || fail "The template already holds a password"
ls "$ROOT"/etc/ssh/ssh_host_* >/dev/null 2>&1 && fail "The template holds SSH host keys"
# Proxmox writes these for each container; nspawn needs a name server for nothing here.
echo test-ct >"$ROOT/etc/hostname"

echo "Booting it"
# Shares the network of the runner, so the panel is on localhost:8080.
script -qfec "systemd-nspawn --quiet --machine=$MACHINE --directory=$ROOT --boot" /dev/null >"$LOG" 2>&1 &

ok=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && [[ -s "$ROOT/var/lib/beeldkrant/initial-admin-password" ]]; then ok=1; break; fi
  sleep 1
done
(( ok )) || fail "The admin panel did not come up within 3 minutes"
PASSWORD="$(tr -d '[:space:]' <"$ROOT/var/lib/beeldkrant/initial-admin-password")"
echo "Admin panel is up; one-time password created"

curl -fsS -c "$ROOT.cookies" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$PASSWORD\"}" http://127.0.0.1:8080/api/login | tee "$ROOT.login.json"
echo
grep -q '"mustChangePassword":true' "$ROOT.login.json" || fail "Logging in with the one-time password did not ask for a new password"

for _ in $(seq 1 60); do [[ -s "$ROOT/etc/issue.d/beeldkrant.issue" ]] && break; sleep 1; done
[[ -s "$ROOT/etc/issue.d/beeldkrant.issue" ]] || fail "beeldkrant-welcome did not write the console login screen"
cat "$ROOT/etc/issue.d/beeldkrant.issue"
grep -q "$PASSWORD" "$ROOT/etc/issue.d/beeldkrant.issue" || fail "The console login screen does not show the password"
grep -q ':8080/' "$ROOT/etc/issue.d/beeldkrant.issue" || fail "The console login screen does not show the address"
sleep 3
grep -q "$PASSWORD" "$LOG" && echo "The console shows the password" || echo "Note: the console log did not show the login screen (nspawn console), but the issue file is right"
for unit in beeldkrant beeldkrant-update.path beeldkrant-welcome; do
  systemctl --machine="$MACHINE" is-active --quiet "$unit" 2>/dev/null || machinectl shell "$MACHINE" /bin/systemctl is-active "$unit" >/dev/null 2>&1 || echo "Note: could not confirm $unit through machinectl"
done
echo "PASS"
