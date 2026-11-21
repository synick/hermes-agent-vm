#!/usr/bin/env bash
# 90-finalise.sh - switch off first-boot provisioning, clean up, record a Lynis hardening baseline.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
log() { echo "==> [90-finalise] $*"; }
: "${ADMIN_USER:?}"

log "Disabling cloud-init (nothing should reconfigure this VM on boot, e.g. via VMware guestinfo)"
touch /etc/cloud/cloud-init.disabled

if id hermes >/dev/null 2>&1; then
  log "Reloading audit rules now that /home/hermes paths exist"
else
  log "No hermes user on this VM (the router): dropping the Hermes-only audit watches"
  sed -i '/\/home\/hermes\//d' /etc/audit/rules.d/90-hermes.rules
fi
augenrules --load

log "Cleaning up"
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/tmp/hermes-files

log "Lynis baseline audit"
mkdir -p /var/log/hermes-build
lynis audit system --quick --no-colors > /var/log/hermes-build/lynis-baseline.txt 2>&1 || true
grep -E 'Hardening index' /var/log/hermes-build/lynis-baseline.txt || true
install -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0600 /var/log/hermes-build/lynis-baseline.txt "/home/${ADMIN_USER}/lynis-baseline.txt"

log "Done - VM is built and hardened"
