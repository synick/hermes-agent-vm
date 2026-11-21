#!/usr/bin/env bash
# 20-harden.sh - OS hardening (CIS-style, scaled to a single-purpose agent VM).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
F=/var/tmp/hermes-files
log() { echo "==> [20-harden] $*"; }
: "${ADMIN_USER:?ADMIN_USER not set}"

log "Kernel parameters"
install -m 0644 "$F/sysctl/90-hermes-hardening.conf" /etc/sysctl.d/90-hermes-hardening.conf
sysctl --system >/dev/null

log "Kernel command line: IPv6 off, memory hardening"
CMDLINE="ipv6.disable=1 init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on"
install -d /etc/default/grub.d
cat > /etc/default/grub.d/90-hermes-hardening.cfg <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $CMDLINE"
EOF
update-grub

log "Kernel module blacklist"
install -m 0644 "$F/modprobe/90-hermes-blacklist.conf" /etc/modprobe.d/90-hermes-blacklist.conf

log "Mounts: /tmp as tmpfs (nosuid,nodev), /dev/shm noexec"
install -d /etc/systemd/system
cat > /etc/systemd/system/tmp.mount <<'EOF'
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,size=2G

[Install]
WantedBy=local-fs.target
EOF
systemctl daemon-reload
systemctl enable tmp.mount
grep -q '^tmpfs /dev/shm' /etc/fstab || echo 'tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0' >> /etc/fstab

log "SSH daemon"
sed "s/@ADMIN_USER@/${ADMIN_USER}/g" "$F/ssh/90-hermes-hardening.conf" > /etc/ssh/sshd_config.d/90-hermes-hardening.conf
chmod 0644 /etc/ssh/sshd_config.d/90-hermes-hardening.conf
# Ed25519 host key only
rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key*
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
sshd -t
systemctl try-reload-or-restart ssh.service || true   # Ubuntu uses ssh.socket activation; new connections read the new config

log "Accounts: lock root, restrict su, sudo hygiene, umask, password quality"
passwd -l root
grep -q '^auth required pam_wheel.so' /etc/pam.d/su || \
  sed -i '/^auth\s\+sufficient\s\+pam_rootok.so/a auth required pam_wheel.so use_uid group=sudo' /etc/pam.d/su
# Options supported by both sudo-rs (Ubuntu 26.04's default) and classic sudo. sudo-rs logs to the journal.
cat > /etc/sudoers.d/90-hermes-hardening <<'EOF'
Defaults use_pty
Defaults timestamp_timeout=5
Defaults passwd_tries=3
EOF
chmod 0440 /etc/sudoers.d/90-hermes-hardening
# Never leave a drop-in that sudo can't parse: that would lock the admin out of sudo.
if ! sudo -n -l -U "$ADMIN_USER" >/dev/null 2>&1; then
  rm -f /etc/sudoers.d/90-hermes-hardening
  echo "WARNING: sudo rejected the hardening drop-in; removed it and kept sudo's defaults" >&2
fi
sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs
sed -i 's/^#\?\s*minlen.*/minlen = 14/' /etc/security/pwquality.conf

log "Core dumps off"
cat > /etc/security/limits.d/90-no-core.conf <<'EOF'
* hard core 0
EOF
install -d /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/90-off.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

log "Persistent, capped journal"
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-hermes.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
Compress=yes
EOF
systemctl restart systemd-journald

log "Audit rules"
install -m 0640 "$F/audit/90-hermes.rules" /etc/audit/rules.d/90-hermes.rules
systemctl enable auditd
augenrules --load || true

log "AppArmor on (Ubuntu's shipped profiles keep their default modes)"
systemctl enable apparmor

log "Automatic security updates (reboot at 04:00 if required)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52-hermes-unattended <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
systemctl enable unattended-upgrades

log "Done"
