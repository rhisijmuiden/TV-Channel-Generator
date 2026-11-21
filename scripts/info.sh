#!/usr/bin/env bash
# Shows how to reach the Beeldkrant admin panel: its address, the user "admin" and, as long as it
# has not been changed, the one-time password. Installed as /usr/bin/beeldkrant-info.
#
#   beeldkrant-info            print it
#   beeldkrant-info --wait     wait (up to 2 minutes) for the service to create the password and
#                              for the machine to get an IP address first
#   beeldkrant-info --issue    also write it to the login screen of the console (/etc/issue.d), so it
#                              shows in the Proxmox console without logging in (beeldkrant-welcome.service)
#   beeldkrant-info --motd     the short version shown after logging in on the shell
set -uo pipefail

DATA_DIR="${DATA_DIR:-/var/lib/beeldkrant}"
[[ -f /etc/default/beeldkrant ]] && source /etc/default/beeldkrant
PASSWORD_FILE="$DATA_DIR/initial-admin-password"
ISSUE_FILE=/etc/issue.d/beeldkrant.issue
WAIT=0; ISSUE=0; MOTD=0
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=1 ;;
    --issue) ISSUE=1; WAIT=1 ;;
    --motd) MOTD=1 ;;
  esac
done

ipv4() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | head -n 1; }
password() { tr -d '[:space:]' 2>/dev/null <"$PASSWORD_FILE"; }

if (( WAIT )); then
  for _ in $(seq 1 120); do
    [[ -n "$(ipv4)" && ( -n "$(password)" || -s "$DATA_DIR/data.json" ) ]] && break
    sleep 1
  done
fi

# A port chosen in the panel (Settings → Application) is kept in the database and wins over PORT.
port="$(node -e 'try { const s = require(process.argv[1]).settings || {}; if (s.port) console.log(s.port); } catch {}' "$DATA_DIR/data.json" 2>/dev/null)"
port="${port:-${PORT:-8080}}"
address="$(node -e 'try { const s = require(process.argv[1]).settings || {}; if (s.serverAddress) console.log(s.serverAddress.replace(/^https?:\/\//, "")); } catch {}' "$DATA_DIR/data.json" 2>/dev/null)"
ip="$(ipv4)"
host="${address:-${ip:-$(hostname -f 2>/dev/null || hostname)}}"
url="http://${host}:${port}${BK_BASE_PATH:-}/"
pw="$(password)"

if (( MOTD )); then
  echo
  echo "  Beeldkrant admin panel: $url"
  [[ -n "$pw" ]] && echo "  User: admin    One-time password: $pw"
  echo "  Show this again with: beeldkrant-info    Update with: update"
  echo
  exit 0
fi

lines=("Beeldkrant is ready." "" "Admin panel:  $url" "User name:    admin")
if [[ -n "$pw" ]]; then
  lines+=("Password:     $pw" "" "This one-time password must be changed at the first login." "Everything else is set up in the admin panel.")
else
  lines+=("Password:     (the one-time password has already been changed)")
fi
[[ -n "$address" && -n "$ip" && "$address" != "$ip" ]] && lines+=("" "Also reachable at http://${ip}:${port}${BK_BASE_PATH:-}/")

width=0
for l in "${lines[@]}"; do (( ${#l} > width )) && width=${#l}; done
box() {
  printf '  ┌%s┐\n' "$(printf '─%.0s' $(seq 1 $((width + 2))))"
  for l in "${lines[@]}"; do printf '  │ %-*s │\n' "$width" "$l"; done
  printf '  └%s┘\n' "$(printf '─%.0s' $(seq 1 $((width + 2))))"
}

if (( ISSUE )); then
  mkdir -p /etc/issue.d
  # Only root (agetty) reads it: it holds the one-time password.
  { echo; box | sed 's/\\/\\\\/g'; echo; } >"$ISSUE_FILE.tmp" && chmod 0600 "$ISSUE_FILE.tmp" && mv "$ISSUE_FILE.tmp" "$ISSUE_FILE"
  # Let the login prompts that are already on screen show it.
  command -v agetty >/dev/null && agetty --reload 2>/dev/null || true
  exit 0
fi

echo
box
echo
