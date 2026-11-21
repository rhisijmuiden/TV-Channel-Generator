#!/bin/sh
# Shown after logging in on the shell (Debian runs /etc/update-motd.d/* at login).
[ -x /usr/bin/beeldkrant-info ] && /usr/bin/beeldkrant-info --motd
exit 0
