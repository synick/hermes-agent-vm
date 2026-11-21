# shellcheck shell=bash
# host: everything on the Mac side. Each step is idempotent, so re-running is safe.

cmd_host() {
  load_config
  export_config
  say "Mac setup"
  info "This needs administrator rights (sudo) for three things, and nothing else:"
  info "  1. creating the two VMware Fusion networks ($FUSION_VMNET for Hermes, $UPLINK_VMNET for the router)"
  info "  2. installing the pf firewall anchor $PF_ANCHOR_NAME and its loader ($PF_DAEMON_LABEL)"
  info "  3. (later) reading pf rule counters during 'verify'"
  sudo -v || die "sudo is required for host setup"

  _host_fusion_networks
  _host_pf
  _host_ollama_check
  _host_caddy
}

# _fusion_net_lines VMNET SUBNET MODE : the "answer" lines Fusion's networking file must contain.
#   isolated = no Mac adapter, no DHCP, no NAT: a private wire between Hermes and the router.
#   nat      = Mac adapter, DHCP and NAT: the router's way out.
_fusion_net_lines() {
  local n=${1#vmnet} subnet=$2 mode=$3
  echo "VNET_${n}_HOSTONLY_SUBNET=$subnet"
  echo "VNET_${n}_HOSTONLY_NETMASK=255.255.255.0"
  if [ "$mode" = isolated ]; then
    echo "VNET_${n}_VIRTUAL_ADAPTER=no"
    echo "VNET_${n}_DHCP=no"
  else
    echo "VNET_${n}_VIRTUAL_ADAPTER=yes"
    echo "VNET_${n}_DHCP=yes"
    echo "VNET_${n}_NAT=yes"
  fi
}
_fusion_net_ok() { # _fusion_net_ok VMNET SUBNET MODE
  local netfile="$FUSION_PREFS/networking" kv
  for kv in $(_fusion_net_lines "$@"); do
    grep -q "^answer ${kv%%=*} ${kv#*=}$" "$netfile" 2>/dev/null || return 1
  done
  if [ "$3" = isolated ]; then
    if grep -q "^answer VNET_${1#vmnet}_NAT yes$" "$netfile" 2>/dev/null; then return 1; fi
  else
    [ -f "$FUSION_PREFS/$1/dhcpd.conf" ] || return 1
  fi
  return 0
}
_fusion_net_apply() { # _fusion_net_apply VMNET SUBNET MODE
  local cli="$FUSION_LIB/vmnet-cfgcli" netfile="$FUSION_PREFS/networking" kv n=${1#vmnet}
  if [ "$3" = isolated ]; then
    sudo "$cli" vnetcfgremove "VNET_${n}_NAT" >/dev/null 2>&1 || true
  fi
  # vmnet-cfgcli reports success in text but not reliably in its exit code, so check the file afterwards.
  for kv in $(_fusion_net_lines "$@"); do
    sudo "$cli" vnetcfgadd "${kv%%=*}" "${kv#*=}" >/dev/null 2>&1 || true
    grep -q "^answer ${kv%%=*} ${kv#*=}$" "$netfile" \
      || die "Couldn't set ${kv%%=*}=${kv#*=} in $netfile. See 'Creating the Fusion networks by hand' in the README."
  done
}

_host_fusion_networks() {
  say "VMware Fusion networks"
  local need=""
  if _fusion_net_ok "$FUSION_VMNET" "$VM_SUBNET" isolated; then
    ok "$FUSION_VMNET (Hermes network, $VM_SUBNET/24): isolated - no Mac, no DHCP, no NAT"
  else need="$need hermes"; fi
  if _fusion_net_ok "$UPLINK_VMNET" "$UPLINK_SUBNET" nat; then
    ok "$UPLINK_VMNET (router uplink, $UPLINK_SUBNET/24): NAT + DHCP"
  else need="$need uplink"; fi
  [ -z "$need" ] && return 0

  local role
  for role in hermes router; do
    if vm_running "$role"; then die "$(vm_name_of "$role") is running. Stop the VMs first (./hermes-vm.sh stop): changing Fusion's networks restarts them."; fi
  done
  for role in $need; do
    if [ "$role" = hermes ]; then
      grep -q "^answer VNET_${FUSION_VMNET#vmnet}_" "$FUSION_PREFS/networking" 2>/dev/null \
        && warn "$FUSION_VMNET exists with other settings; it will become hermes-vm's isolated network"
    else
      grep -q "^answer VNET_${UPLINK_VMNET#vmnet}_" "$FUSION_PREFS/networking" 2>/dev/null \
        && warn "$UPLINK_VMNET exists with other settings; it will become the router's uplink"
    fi
  done
  yes_default "Continue?" || die "Pick other network names with ./hermes-vm.sh configure"
  fusion_quit_wait
  case "$need" in *hermes*) _fusion_net_apply "$FUSION_VMNET" "$VM_SUBNET" isolated ;; esac
  case "$need" in *uplink*) _fusion_net_apply "$UPLINK_VMNET" "$UPLINK_SUBNET" nat ;; esac
  sudo "$FUSION_LIB/vmnet-cli" --configure >/dev/null 2>&1 || true
  sudo "$FUSION_LIB/vmnet-cli" --stop >/dev/null 2>&1 || true
  sudo "$FUSION_LIB/vmnet-cli" --start >/dev/null 2>&1 || true
  _fusion_net_ok "$FUSION_VMNET" "$VM_SUBNET" isolated || die "Fusion didn't apply the settings for $FUSION_VMNET. See 'Creating the Fusion networks by hand' in the README."
  _fusion_net_ok "$UPLINK_VMNET" "$UPLINK_SUBNET" nat || die "Fusion didn't create $UPLINK_VMNET/dhcpd.conf. See 'Creating the Fusion networks by hand' in the README."
  ok "$FUSION_VMNET: isolated Hermes network ($VM_SUBNET/24)"
  ok "$UPLINK_VMNET: router uplink with NAT ($UPLINK_SUBNET/24)"
}

_host_pf() {
  say "Firewall: pf anchor $PF_ANCHOR_NAME"
  local tmp
  tmp=$(mktemp -d)
  render "$REPO/host/pf-anchor.tpl" "$tmp/anchor"
  render "$REPO/host/pf-load.sh.tpl" "$tmp/pf-load.sh"
  render "$REPO/host/pf-daemon.plist.tpl" "$tmp/pf.plist"
  plutil -lint -s "$tmp/pf.plist" || die "Generated launchd plist is invalid"

  local out
  # Syntax-check without the interface-bound lines (the VM interface may not exist yet).
  if ! out=$(grep -v 'vm_if' "$tmp/anchor" | sudo pfctl -a "$PF_ANCHOR_NAME" -nf - 2>&1); then
    echo "$out" | grep -v ALTQ >&2
    die "pf rejected the generated rules ($tmp/anchor)"
  fi

  sudo install -m 0644 -o root -g wheel "$tmp/anchor" "$PF_ANCHOR_FILE"
  sudo install -d -m 0755 -o root -g wheel "$SUPPORT_DIR"
  sudo install -m 0755 -o root -g wheel "$tmp/pf-load.sh" "$PF_LOADER"
  sudo install -m 0644 -o root -g wheel "$tmp/pf.plist" "$PF_DAEMON_PLIST"
  rm -rf "$tmp"

  sudo rm -f /var/run/hermes-vm-pf.iface
  launchd_load system "$PF_DAEMON_LABEL" "$PF_DAEMON_PLIST" sudo
  sleep 1
  sudo "$PF_LOADER"
  if sudo pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null | grep -q "$UPLINK_GW"; then
    ok "Loaded; re-applied at boot and every 30 seconds by launchd"
  else
    die "The anchor didn't load. Check: sudo pfctl -a $PF_ANCHOR_NAME -s rules"
  fi
}

_host_ollama_check() {
  say "Ollama"
  if ! command -v ollama >/dev/null; then
    warn "Not installed. Hermes needs a model; install Ollama, pull $LLM_MODEL, then run ./hermes-vm.sh host again."
    return
  fi
  local listen
  listen=$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u | tr '\n' ' ' || true)
  if [ -z "$listen" ]; then
    warn "Ollama isn't running (nothing listening on 11434). Start the Ollama app."
  elif echo "$listen" | tr ' ' '\n' | grep -v '^$' | grep -qvE '^(127\.0\.0\.1|\[::1\]):11434$'; then
    warn "Ollama is listening beyond loopback ($listen). Anyone on your network can use it."
    info "Fix: launchctl setenv OLLAMA_HOST 127.0.0.1:11434   then quit and reopen Ollama."
  else
    ok "Listening on loopback only"
  fi
  if (ollama list 2>/dev/null || true) | awk 'NR>1 {print $1}' | grep -qxF "$LLM_MODEL"; then
    ok "Model $LLM_MODEL is pulled"
  else
    warn "Model $LLM_MODEL isn't pulled yet: ollama pull $LLM_MODEL"
  fi
}

_host_caddy() {
  say "Ollama gateway (Caddy on $UPLINK_GW:$LLM_PORT, reached by Hermes through the router)"
  local caddy uid
  caddy=$(command -v caddy) || die "caddy not found (brew install caddy)"
  export CADDY_BIN="$caddy"
  mkdir -p "$LOG_DIR"
  render "$REPO/host/Caddyfile.tpl" "$CONFIG_DIR/Caddyfile"
  chmod 600 "$CONFIG_DIR/Caddyfile"
  "$caddy" validate --config "$CONFIG_DIR/Caddyfile" --adapter caddyfile >/dev/null 2>&1 \
    || die "Caddy rejected $CONFIG_DIR/Caddyfile (run: caddy validate --config $CONFIG_DIR/Caddyfile)"
  mkdir -p "$(dirname "$CADDY_AGENT_PLIST")"
  render "$REPO/host/caddy-agent.plist.tpl" "$CADDY_AGENT_PLIST"
  plutil -lint -s "$CADDY_AGENT_PLIST" || die "Generated Caddy plist is invalid"
  uid=$(id -u)
  launchd_load "gui/$uid" "$CADDY_AGENT_LABEL" "$CADDY_AGENT_PLIST"
  ok "Installed as a LaunchAgent. It starts serving once the router's network is up."
}
