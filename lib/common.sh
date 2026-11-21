# shellcheck shell=bash
# Shared helpers for hermes-vm.sh. Written for macOS's stock bash 3.2 (no associative arrays, no case-changing expansions).

# ---------- locations (nothing secret is written to any of these) ----------
CONFIG_DIR="${HERMES_VM_CONFIG_DIR:-$HOME/.config/hermes-vm}"
CONFIG_FILE="$CONFIG_DIR/config.env"
BUILD_DIR="$CONFIG_DIR/build"
ISO_DIR="$CONFIG_DIR/iso"
KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
LOG_DIR="$HOME/Library/Logs"
KEYCHAIN_SERVICE="hermes-vm"
SSH_KEY="$HOME/.ssh/hermes_vm_ed25519"
SSH_KEY_COMMENT="hermes-vm-admin"

FUSION_APP="/Applications/VMware Fusion.app"
FUSION_LIB="$FUSION_APP/Contents/Library"
FUSION_PREFS="/Library/Preferences/VMware Fusion"
VMRUN="$FUSION_LIB/vmrun"

PF_ANCHOR_NAME="com.apple/hermes-vm"
PF_ANCHOR_FILE="/etc/pf.anchors/hermes-vm"
SUPPORT_DIR="/Library/Application Support/hermes-vm"
PF_LOADER="$SUPPORT_DIR/pf-load.sh"
PF_DAEMON_LABEL="local.hermes-vm.pf"
PF_DAEMON_PLIST="/Library/LaunchDaemons/$PF_DAEMON_LABEL.plist"
CADDY_AGENT_LABEL="local.hermes-vm.caddy"
CADDY_AGENT_PLIST="$HOME/Library/LaunchAgents/$CADDY_AGENT_LABEL.plist"

UBUNTU_GPG_FPR="843938DF228D22F7B3742BC0D94AA3F0EFE21092" # Ubuntu CD Image Automatic Signing Key (2012)

# Every setting the wizard collects. Saved to $CONFIG_FILE (mode 600); the password is NOT one of them.
# FUSION_VMNET/VM_SUBNET: the Hermes network (Hermes + the router's inside leg; the Mac is NOT on it). VM_GW is the
# router's address there. UPLINK_*: the router's outside network (Fusion NAT), where the Mac is UPLINK_GW.
CONFIG_VARS="VM_NAME VM_DIR CPUS MEMORY_GB DISK_GB ADMIN_USER TIMEZONE UBUNTU_VERSION ISO_PATH ISO_SHA256 FUSION_VMNET VM_SUBNET VM_GW HERMES_IP UPLINK_VMNET UPLINK_SUBNET UPLINK_GW UPLINK_NAT ROUTER_NAME ROUTER_DIR ROUTER_WAN_IP ROUTER_LAN_MAC LLM_PORT LLM_MODEL HERMES_TAG DNS_SERVERS HEADLESS"

# ---------- output ----------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; X=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; YLW=""; X=""
fi
say()  { printf '\n%s==> %s%s\n' "$B" "$*" "$X"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$X" "$*"; }
warn() { printf '    %s!%s %s\n' "$YLW" "$X" "$*" >&2; }
die()  { printf '\n%s✗ %s%s\n' "$RED" "$*" "$X" >&2; exit 1; }

# ask VAR "Question" "default"   (Enter accepts the default)
ask() {
  local __var=$1 __q=$2 __def=${3-} __ans=""
  if [ -n "$__def" ]; then
    read -r -p "    $__q [$__def]: " __ans || true
  else
    read -r -p "    $__q: " __ans || true
  fi
  [ -z "$__ans" ] && __ans=$__def
  printf -v "$__var" '%s' "$__ans"
}
# yes_default "Question" -> 0 unless the answer starts with n
yes_default() { local a=""; read -r -p "    $1 [Y/n]: " a || true; case "$a" in [nN]*) return 1 ;; *) return 0 ;; esac; }
# no_default "Question" -> 0 only if the answer starts with y
no_default()  { local a=""; read -r -p "    $1 [y/N]: " a || true; case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac; }
pause() { local a=""; read -r -p "    $1 " a || true; }

# ---------- config ----------
load_config() {
  [ -f "$CONFIG_FILE" ] || die "No configuration yet. Run: ./hermes-vm.sh configure"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  [ -n "${UPLINK_VMNET:-}" ] && [ -n "${ROUTER_NAME:-}" ] \
    || die "Your settings are from before the router VM was added. Run ./hermes-vm.sh configure, check the new
    network lines and press Enter; then: ./hermes-vm.sh build  (builds just the router) and ./hermes-vm.sh lockdown"
}
save_config() {
  local v tmp
  umask 077
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  tmp="$CONFIG_FILE.tmp"
  {
    echo "# hermes-vm settings - written by hermes-vm.sh. No secrets here: the admin password lives in your Keychain."
    for v in $CONFIG_VARS; do printf '%s=%q\n' "$v" "${!v-}"; done
  } > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}
export_config() {
  local v
  for v in $CONFIG_VARS; do export "${v?}"; done
  export CONFIG_DIR LOG_DIR PF_DAEMON_LABEL PF_LOADER CADDY_AGENT_LABEL
}

# ---------- secrets (macOS login Keychain) ----------
keychain_get() { security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null || return 1; }
keychain_has() { security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" >/dev/null 2>&1 || return 1; }

# Puts the VM admin password on the clipboard for 30 seconds (for sudo prompts inside the VM).
offer_password_clipboard() {
  if no_default "Copy the VM admin password to the clipboard for 30 seconds (for sudo in the VM)?"; then
    keychain_get "$ADMIN_USER" | tr -d '\n' | pbcopy
    ( sleep 30; printf '' | pbcopy ) >/dev/null 2>&1 &
    ok "Copied. Paste it at the [sudo] prompt; the clipboard clears in 30 seconds."
  fi
}

# ---------- templates ----------
# render TEMPLATE OUTPUT : replaces {{NAME}} with the exported environment variable NAME; fails on any unset one.
render() {
  perl -pe 's/\{\{([A-Z0-9_]+)\}\}/defined $ENV{$1} ? $ENV{$1} : die("unset template variable $1\n")/ge' "$1" > "$2"
}

# ---------- VM helpers ----------
# Two VMs: "hermes" (the agent) and "router" (Hermes's only way out). Helpers take the role; the default is hermes.
vm_name_of() { if [ "${1:-hermes}" = router ]; then echo "$ROUTER_NAME"; else echo "$VM_NAME"; fi; }
vm_dir_of()  { if [ "${1:-hermes}" = router ]; then echo "$ROUTER_DIR"; else echo "$VM_DIR"; fi; }
vmx_path()   { echo "$(vm_dir_of "${1:-hermes}")/$(vm_name_of "${1:-hermes}").vmx"; }
vm_exists()  { [ -f "$(vmx_path "${1:-hermes}")" ]; }
vm_running() { "$VMRUN" -T fusion list 2>/dev/null | grep -Fq "$(vmx_path "${1:-hermes}")" || return 1; }
vm_locked()  { # 0 once lockdown has moved this VM onto its own network
  local vnet=$FUSION_VMNET
  [ "${1:-hermes}" = router ] && vnet=$UPLINK_VMNET
  grep -iq "^ethernet0\.vnet = \"$vnet\"" "$(vmx_path "${1:-hermes}")" 2>/dev/null
}
vm_mac() { # vm_mac ROLE [ethernetN] -> the adapter's MAC address, lowercase (empty until the VM has booted once)
  grep -iE "^${2:-ethernet0}\.(generatedaddress|address) = " "$(vmx_path "${1:-hermes}")" 2>/dev/null \
    | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr 'A-F' 'a-f' || true
}
vm_stop() { # vm_stop ROLE : clean shutdown, forced if that fails
  vm_running "$1" || return 0
  "$VMRUN" -T fusion stop "$(vmx_path "$1")" soft >/dev/null 2>&1 \
    || "$VMRUN" -T fusion stop "$(vmx_path "$1")" hard >/dev/null 2>&1 || true
}
vm_no_ip_help() { # vm_no_ip_help ROLE
  cat >&2 <<EOF

    If the error above mentions a host key, or nothing at all, check for a Little Snitch (or other firewall)
    prompt about "ssh" waiting for an answer, then re-run the same command.

    $(vm_name_of "${1:-hermes}") is running but can't be reached. To see why:
      1. Open it in Fusion (double-click $(vm_dir_of "${1:-hermes}")) and log in as $ADMIN_USER.
      2. Run:  ip -br addr   and   sudo networkctl status
      3. Then: sudo journalctl -b -u systemd-networkd | tail -30
EOF
}
# VMware locks each disk with a "<disk>.lck" folder. After a snapshot (or a build shown in the Fusion window), a
# VMware process can keep the powered-off VM open, and its lock then stops the VM starting ("Cannot open the
# disk ... Directory not empty"). For a VM that is NOT running: wait for that process to exit; if it doesn't,
# close the Fusion window (only when no VM at all is running) and finally end the leftover process. Then remove
# the leftover lock folders.
_vmx_orphans() { pgrep -f "vmware-vmx.*${1}\.vmx" 2>/dev/null || true; }
vm_clear_stale_locks() { # vm_clear_stale_locks ROLE
  local role=${1:-hermes} waited=0 locks name dir pids
  name=$(vm_name_of "$role"); dir=$(vm_dir_of "$role")
  vm_running "$role" && return 0
  while [ -n "$(_vmx_orphans "$name")" ] && [ "$waited" -lt 30 ]; do
    sleep 3; waited=$((waited + 3))
  done
  if [ -n "$(_vmx_orphans "$name")" ] && pgrep -xq "VMware Fusion" \
     && "$VMRUN" -T fusion list 2>/dev/null | grep -q '^Total running VMs: 0'; then
    info "VMware Fusion is still holding $name open; closing the Fusion window (no VMs are running)"
    osascript -e 'tell application "VMware Fusion" to quit' >/dev/null 2>&1 || true
    waited=0
    while [ -n "$(_vmx_orphans "$name")" ] && [ "$waited" -lt 20 ]; do sleep 2; waited=$((waited + 2)); done
  fi
  pids=$(_vmx_orphans "$name")
  if [ -n "$pids" ] && ! vm_running "$role"; then
    info "Ending a leftover VMware process for the powered-off $name"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 5
    pids=$(_vmx_orphans "$name")
    # shellcheck disable=SC2086
    [ -n "$pids" ] && { kill -9 $pids 2>/dev/null || true; sleep 2; }
  fi
  vm_running "$role" && return 0
  locks=$(find "$dir" -maxdepth 1 -name '*.lck' 2>/dev/null || true)
  if [ -n "$locks" ]; then
    printf '%s\n' "$locks" | while IFS= read -r l; do rm -rf -- "$l"; done
    info "Cleared stale VMware lock files ($name)"
  fi
  return 0
}

# Where each VM is in the process, read from its snapshots (works while it's powered off):
#   none -> installed (Packer done) -> base -> provisioned -> locked
# Older builds made everything in Packer and named that snapshot 'built': that counts as provisioned.
vm_snapshots() { "$VMRUN" -T fusion listSnapshots "$(vmx_path "$1")" 2>/dev/null | tail -n +2 || true; }
vm_stage() { # vm_stage ROLE
  local snaps lockname=clean-no-secrets
  vm_exists "$1" || { echo none; return 0; }
  [ "$1" = router ] && lockname=clean
  snaps=$(vm_snapshots "$1")
  if printf '%s\n' "$snaps" | grep -qx "$lockname" && vm_locked "$1"; then echo locked
  elif printf '%s\n' "$snaps" | grep -qxE 'provisioned|built|clean|clean-no-secrets'; then echo provisioned
  elif printf '%s\n' "$snaps" | grep -qx base; then echo base
  else echo installed
  fi
}

vm_reported_ip() { "$VMRUN" -T fusion getGuestIPAddress "$(vmx_path "${1:-hermes}")" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true; }

vm_ip() { # vm_ip ROLE : prints the VM's IPv4 address, or nothing
  # After lockdown both addresses are fixed. Before it (on Fusion's default NAT, during the build stage) ask VMware
  # Tools, retrying for up to VM_IP_WAIT seconds, and fall back to Fusion's DHCP leases matched on the MAC.
  local role=${1:-hermes} mac ip waited=0 limit=${VM_IP_WAIT:-120}
  if vm_locked "$role"; then
    if [ "$role" = router ]; then echo "$ROUTER_WAN_IP"; else echo "$HERMES_IP"; fi
    return 0
  fi
  mac=$(vm_mac "$role")
  while :; do
    ip=$(vm_reported_ip "$role")
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    # The lease file can still hold an address from an earlier boot, so only fall back to it once VMware Tools
    # has had 30 seconds to report the current one (or when the caller asked not to wait).
    if [ -n "$mac" ] && { [ "$waited" -ge 30 ] || [ "$limit" -lt 30 ]; } \
       && [ -r "${VMNET_LEASES_DIR:-/var/db/vmware}/vmnet-dhcpd-vmnet8.leases" ]; then
      ip=$(awk -v m="$mac" '/^lease /{ip=$2} /hardware ethernet/{h=$3; sub(";","",h); if (tolower(h)==m) last=ip} END{print last}' \
             "${VMNET_LEASES_DIR:-/var/db/vmware}/vmnet-dhcpd-vmnet8.leases" 2>/dev/null || true)
      [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    [ "$waited" -ge "$limit" ] && return 0
    sleep "${VM_IP_SLEEP:-3}"; waited=$((waited + 3))
  done
}

ensure_agent_key() {
  [ -f "$SSH_KEY" ] || die "SSH key $SSH_KEY is missing. Run: ./hermes-vm.sh configure"
  if ! ssh-add -l 2>/dev/null | grep -q "$SSH_KEY_COMMENT"; then
    info "Loading your hermes-vm SSH key into ssh-agent (passphrase saved in your Keychain)"
    ssh-add --apple-use-keychain "$SSH_KEY" >/dev/null || die "Couldn't add $SSH_KEY to ssh-agent"
  fi
}

# _ssh_target ROLE : sets SSH_OPTS (array) and SSH_HOST. After lockdown the Mac isn't on the Hermes network at all,
# so SSH to Hermes hops through the router (whose sshd lets it forward to Hermes's port 22 and nothing else).
_ssh_target() {
  local role=${1:-hermes}
  # Host keys are recorded under the VM's name (HostKeyAlias), not its address: addresses get reused by a rebuilt
  # VM, and a reinstall forgets the old key (see forget_host_key), so a rebuild never trips over its predecessor.
  SSH_OPTS=(-o IdentitiesOnly=yes -i "$SSH_KEY" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new
            -o "HostKeyAlias=$(vm_name_of "$role")" -o CheckHostIP=no)
  if [ "$role" = hermes ] && vm_locked hermes; then
    SSH_OPTS+=(-o "ProxyCommand=ssh -q -o IdentitiesOnly=yes -i '$SSH_KEY' -o 'UserKnownHostsFile=$KNOWN_HOSTS' -o StrictHostKeyChecking=accept-new -o HostKeyAlias=$ROUTER_NAME -o CheckHostIP=no -o ConnectTimeout=5 -W %h:%p $ADMIN_USER@$ROUTER_WAN_IP")
    SSH_HOST=$HERMES_IP
  else
    SSH_HOST=$(vm_ip "$role")
  fi
}

vm_ssh() { # vm_ssh [--router] [ssh args...]
  local role=hermes
  [ "${1:-}" = --router ] && { role=router; shift; }
  _ssh_target "$role"
  [ -n "$SSH_HOST" ] || die "Can't find $(vm_name_of "$role")'s address. Is it running? (./hermes-vm.sh start)"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$SSH_HOST" "$@"
}

forget_host_key() { # forget_host_key ROLE : after a reinstall the VM has a new host key
  # Remove it under the VM's name and under its fixed addresses (entries from before names were used).
  local h
  [ -f "$KNOWN_HOSTS" ] || return 0
  if [ "$1" = router ]; then h="$ROUTER_NAME $ROUTER_WAN_IP"; else h="$VM_NAME $HERMES_IP"; fi
  for h in $h; do ssh-keygen -R "$h" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true; done
  rm -f "$KNOWN_HOSTS.old"
}

vm_scp() { # vm_scp [--router] LOCAL REMOTE_PATH
  local role=hermes
  [ "${1:-}" = --router ] && { role=router; shift; }
  _ssh_target "$role"
  [ -n "$SSH_HOST" ] || die "Can't find $(vm_name_of "$role")'s address. Is it running? (./hermes-vm.sh start)"
  scp -q "${SSH_OPTS[@]}" "$1" "$ADMIN_USER@$SSH_HOST:$2"
}

# vm_sudo [--router] COMMAND : run COMMAND (a shell string) as root in the VM. The admin password comes from your
# Keychain and is piped to sudo over the SSH connection: never on a command line, never on the clipboard.
# SSH_CLIENT is passed through so scripts can see where the session comes from.
vm_sudo() {
  local flag=""
  [ "${1:-}" = --router ] && { flag=--router; shift; }
  [ -n "${SUDO_PW:-}" ] || SUDO_PW=$(keychain_get "$ADMIN_USER") || die "Couldn't read the admin password from the Keychain"
  # shellcheck disable=SC2086
  printf '%s\n' "$SUDO_PW" | vm_ssh $flag -o BatchMode=yes "sudo -S -p '' env SSH_CLIENT=\"\$SSH_CLIENT\" bash -c $(printf '%q' "$1")"
}

vm_wait_ssh() { # vm_wait_ssh ROLE : waits up to VM_SSH_WAIT seconds (default 180) until SSH accepts our key
  # The address is looked up again on every attempt: while a VM boots, the first answer can be stale.
  local role=${1:-hermes} limit=${VM_SSH_WAIT:-180} waited=0 first=yes
  ensure_agent_key
  while :; do
    if [ "$first" = yes ]; then _ssh_target "$role"; first=no
    else VM_IP_WAIT=0 _ssh_target "$role"; fi
    if [ -n "$SSH_HOST" ] && VM_SSH_LAST_ERR=$(ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$ADMIN_USER@$SSH_HOST" true 2>&1); then
      return 0
    fi
    [ -n "$SSH_HOST" ] || VM_SSH_LAST_ERR="no address found for $(vm_name_of "$role")"
    if [ "$waited" -ge "$limit" ]; then
      warn "Last SSH attempt ($ADMIN_USER@${SSH_HOST:-?}): $(printf '%s' "$VM_SSH_LAST_ERR" | tail -2 | tr '\n' ' ')"
      return 1
    fi
    sleep 5; waited=$((waited + 5))
  done
}

openssl3() {
  local p
  p="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
  [ -x "$p" ] || die "OpenSSL 3 not found (brew install openssl@3)"
  echo "$p"
}

# ---------- .vmx editing ----------
# VMX keys are case-insensitive and Packer writes them in lowercase. A key present twice (in any case)
# makes VMware refuse to open the VM, so always remove every variant before writing.
vmx_del() { # vmx_del FILE KEY_REGEX   (case-insensitive, anchored at the key)
  K="$2" perl -i -ne 'print unless /^\s*(?:$ENV{K})\s*=/i' "$1"
}
vmx_set() { # vmx_set FILE KEY VALUE
  local qk
  qk=$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')
  vmx_del "$1" "$qk"
  printf '%s = "%s"\n' "$2" "$3" >> "$1"
}

# launchd_load DOMAIN LABEL PLIST [sudo]
# (Re)loads a launchd job. `bootout` finishes asynchronously, so an immediate `bootstrap` can fail with
# "5: Input/output error"; wait for the old job to go, and if it's somehow still loaded, restart it instead.
launchd_load() {
  local domain=$1 label=$2 plist=$3 pre=${4:-} i
  $pre launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    $pre launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if $pre launchctl bootstrap "$domain" "$plist" 2>/dev/null; then return 0; fi
  if $pre launchctl print "$domain/$label" >/dev/null 2>&1; then
    $pre launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 && return 0
  fi
  sleep 2
  $pre launchctl bootstrap "$domain" "$plist" || die "launchd wouldn't load $label from $plist"
}

fusion_quit_wait() {
  while pgrep -xq "VMware Fusion"; do
    pause "VMware Fusion is open. Quit it (Cmd-Q) so its network settings can be changed, then press Enter."
  done
}
