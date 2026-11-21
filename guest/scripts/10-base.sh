#!/usr/bin/env bash
# 10-base.sh - patch the OS, install what the build needs, strip what it doesn't.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
log() { echo "==> [10-base] $*"; }
mkdir -p /var/log/hermes-build

# First boot runs its own apt jobs (cloud-init, apt-daily, unattended-upgrades). Wait for them, and make every
# later apt/dpkg call wait for the lock instead of failing.
log "Waiting for first-boot setup to finish"
cloud-init status --wait >/dev/null 2>&1 || true
echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/99hermes-lock-timeout
for _ in $(seq 1 180); do
  pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -x dpkg >/dev/null \
    || pgrep -f 'unattended-upgrade( |$)' >/dev/null || break   # not the always-on -shutdown helper
  sleep 5
done

log "Full upgrade"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade

log "Installing baseline packages"
apt-get -y install --no-install-recommends \
  ca-certificates curl gnupg jq less vim-tiny \
  nftables auditd audispd-plugins apparmor apparmor-utils \
  unattended-upgrades apt-listchanges needrestart \
  uidmap dbus-user-session systemd-container \
  libpam-pwquality lynis iputils-ping netcat-openbsd

log "Removing packages this VM doesn't need"
purge_if_present() {
  for p in "$@"; do
    if dpkg -s "$p" >/dev/null 2>&1; then apt-get -y purge "$p"; fi
  done
}
systemctl disable --now snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
purge_if_present snapd ufw apport apport-symptoms popularity-contest \
  multipath-tools modemmanager avahi-daemon cups-browsed telnet ftp rsh-client
apt-get -y autoremove --purge

# Keep snapd from coming back as a dependency.
cat > /etc/apt/preferences.d/no-snapd.pref <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

log "Silencing MOTD news and Ubuntu Pro apt adverts"
if [ -f /etc/default/motd-news ]; then sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news; fi
systemctl disable --now motd-news.timer 2>/dev/null || true
if command -v pro >/dev/null 2>&1; then pro config set apt_news=false || true; fi

log "Done"
