# shellcheck shell=bash
# Day-to-day commands: start, stop, status, ssh, setup-hermes, verify, logs, uninstall.

_require_vm() { vm_exists hermes || die "No Hermes VM at $VM_DIR yet. Run: ./hermes-vm.sh build"; }

# Power on headless, retrying: straight after Packer, a snapshot or a .vmx edit, Fusion sometimes isn't ready
# and vmrun says "Cannot connect to the virtual machine". Then try with the Fusion window, then show vmware.log.
_vm_power_on() { # _vm_power_on ROLE
  local role=${1:-hermes} vmx dir attempt out
  vmx=$(vmx_path "$role"); dir=$(vm_dir_of "$role")
  vm_clear_stale_locks "$role"
  for attempt in 1 2 3; do
    # "trap - ERR": a failed attempt here is expected and retried, not an unexpected stop.
    if out=$(trap - ERR; "$VMRUN" -T fusion start "$vmx" nogui 2>&1); then return 0; fi
    vm_running "$role" && return 0
    warn "Start attempt $attempt didn't work: $(printf '%s' "$out" | grep -i error | head -1)"
    sleep 8
    vm_clear_stale_locks "$role"
  done
  info "Trying once more with the VMware Fusion window open"
  if "$VMRUN" -T fusion start "$vmx" gui >/dev/null 2>&1 || vm_running "$role"; then return 0; fi
  if [ -f "$dir/vmware.log" ]; then
    warn "The last errors in the VM's log ($dir/vmware.log):"
    grep -iE 'error|failed|cannot|msg_post|panic' "$dir/vmware.log" | tail -12 | sed 's/^/      /' >&2 || true
  fi
  info "You can also open the VM in Fusion (double-click $dir) to see VMware's own message."
  return 1
}

# Run-time size: Hermes as configured, the router 1 vCPU / 1 GB. Applied while powered off, before each start, so
# changing it in 'configure' takes effect at the next start. (Reverting a snapshot is fine: the next start reapplies.)
_apply_size() { # _apply_size ROLE
  local vmx cpus mem
  vmx=$(vmx_path "$1")
  if [ "$1" = router ]; then cpus=1; mem=1024; else cpus=$CPUS; mem=$((MEMORY_GB * 1024)); fi
  [ "$(vmx_get "$vmx" numvcpus)" = "$cpus" ] || vmx_set "$vmx" numvcpus "$cpus"
  [ "$(vmx_get "$vmx" memsize)" = "$mem" ] || vmx_set "$vmx" memsize "$mem"
}

# Keep the Hermes container's limits in step with the VM size (memory minus 1 GB, same CPUs). Only touches the VM
# when they differ; restarts the container only if it was running.
_sync_container_limits() {
  local want have
  want="$MEMORY_GB $CPUS"
  have=$(vm_ssh -o BatchMode=yes "cat /var/lib/hermes-vm/limits 2>/dev/null || true" 2>/dev/null || true)
  [ "$have" = "$want" ] && return 0
  info "Setting the Hermes container's limits to $(( MEMORY_GB > 2 ? MEMORY_GB - 1 : 1 )) GB / $CPUS CPUs"
  vm_sudo "f=/home/hermes/hermes/compose.yaml; [ -f \$f ] || exit 0
    sed -i -E 's/^( *mem_limit:).*/\\1 $(( MEMORY_GB > 2 ? MEMORY_GB - 1 : 1 ))g/; s/^( *cpus:).*/\\1 $CPUS.0/' \$f
    install -d -m 0755 /var/lib/hermes-vm; echo '$want' > /var/lib/hermes-vm/limits
    u=\$(id -u hermes)
    run() { sudo -u hermes env XDG_RUNTIME_DIR=/run/user/\$u DOCKER_HOST=unix:///run/user/\$u/docker.sock \"\$@\"; }
    if [ -n \"\$(cd /home/hermes/hermes && run docker compose ps -q 2>/dev/null)\" ]; then
      cd /home/hermes/hermes && run docker compose up -d >/dev/null && echo 'Hermes container restarted with the new limits'
    fi" || warn "Couldn't update the container limits; they'll be retried at the next start"
}

# ---------- which Ollama model Hermes uses ----------
# Runs as root in the Hermes VM (through vm_sudo). ACTION=get prints model.default from Hermes's own config.yaml
# (in its Docker volume); ACTION=set changes it with `hermes config set` and restarts the container.
# (A function printing a heredoc, not VAR=$(cat <<...): macOS bash 3.2 mis-parses 'case' inside $(...).)
_hermes_model_script() {
  cat <<'EOS'
u=$(id -u hermes)
run() { sudo -u hermes env XDG_RUNTIME_DIR=/run/user/$u DOCKER_HOST=unix:///run/user/$u/docker.sock "$@"; }
cd /home/hermes/hermes || exit 1
case "$ACTION" in
  get)
    f=$(ls /home/hermes/.local/share/docker/volumes/*hermes-data/_data/config.yaml 2>/dev/null | head -1)
    [ -n "$f" ] || exit 0
    awk '/^model:/ {m=1; next}
         m && /^[^ #]/ {m=0}
         m && /^  (default|model):/ {sub(/^  (default|model):[ ]*/, ""); sub(/[ ]+#.*$/, ""); gsub(/["'\'']/, ""); print; exit}' "$f"
    ;;
  set)
    i=0
    until [ -n "$(run docker compose ps -q --status running hermes 2>/dev/null)" ]; do
      i=$((i + 1)); [ "$i" -gt 45 ] && { echo "The Hermes container isn't running" >&2; exit 1; }
      sleep 2
    done
    run docker compose exec -T hermes hermes config set model.default "$MODEL" >/dev/null 2>&1 || exit 1
    run docker compose restart hermes >/dev/null 2>&1 || exit 1
    ;;
esac
EOS
}

_hermes_model_get() { vm_sudo "ACTION=get; $(_hermes_model_script)" 2>/dev/null | tail -1 || true; }
_hermes_model_set() { vm_sudo "ACTION=set MODEL=$(printf '%q' "$1"); $(_hermes_model_script)"; }

# Chat models in the Mac's Ollama, one per line as NAME<tab>SIZE (embedding models left out).
_ollama_models() {
  command -v ollama >/dev/null || return 0
  ollama list 2>/dev/null | awk 'NR > 1 && tolower($1) !~ /embed/ {print $1 "\t" $3 " " $4}' || true
}

# _choose_model [NAME] : NAME switches straight to that model; no NAME lists the models and asks, with the one
# Hermes uses now as the default (Enter, or 30 seconds without an answer, keeps it). Without a terminal it keeps it.
_choose_model() {
  local want=${1:-} cur list names name size i n ans
  list=$(_ollama_models)
  if [ -z "$list" ]; then warn "No models in 'ollama list' on this Mac; Hermes keeps its current model"; return 0; fi
  cur=$(_hermes_model_get); [ -n "$cur" ] || cur=$LLM_MODEL
  names=$(printf '%s\n' "$list" | cut -f1)
  n=$(printf '%s\n' "$names" | wc -l | tr -d ' ')

  if [ -z "$want" ]; then
    [ -t 0 ] || { ok "Hermes model: $cur"; return 0; }
    say "Model"
    i=0
    while IFS=$'\t' read -r name size; do
      i=$((i + 1))
      if [ "$name" = "$cur" ]; then printf '    %s%2d) %-50s %8s  (current)%s\n' "$B" "$i" "$name" "$size" "$X"
      else printf '    %2d) %-50s %8s\n' "$i" "$name" "$size"; fi
    done <<EOF
$list
EOF
    printf '%s\n' "$names" | grep -qxF "$cur" || warn "The current model ($cur) isn't in 'ollama list' any more; pick one"
    while :; do
      ans=""
      read -r -t 30 -p "    Model number or name [Enter = $cur]: " ans || echo
      if [ -z "$ans" ]; then want=$cur
      elif [ "$ans" -ge 1 ] 2>/dev/null && [ "$ans" -le "$n" ]; then want=$(printf '%s\n' "$names" | sed -n "${ans}p")
      else want=$ans; fi
      printf '%s\n' "$names" | grep -qxF "$want" && break
      warn "'$want' isn't one of the models above"
    done
  elif ! printf '%s\n' "$names" | grep -qxF "$want"; then
    die "'$want' isn't in 'ollama list' on this Mac. Pull it first: ollama pull $want"
  fi

  if [ "$want" = "$cur" ]; then
    ok "Hermes model: $cur"
  else
    info "Switching Hermes from $cur to $want (restarts the Hermes container; a running task is stopped)"
    _hermes_model_set "$want" || die "Couldn't change the model. Hermes is still on $cur.
    By hand: hermes-shell, then: cd ~/hermes && docker compose exec hermes hermes model"
    ok "Hermes model: $want"
  fi
  if [ "$LLM_MODEL" != "$want" ]; then LLM_MODEL=$want; save_config; fi
}

cmd_model() {
  load_config; _require_vm
  if ! vm_running hermes || ! vm_locked hermes; then die "Hermes isn't running. Start it first: ./hermes-vm.sh start"; fi
  _choose_model "${1:-}"
}

_start_one() { # _start_one ROLE
  if vm_running "$1"; then ok "$(vm_name_of "$1") already running"; return 0; fi
  _apply_size "$1"
  info "Starting $(vm_name_of "$1")"
  _vm_power_on "$1" || die "VMware couldn't start $(vm_name_of "$1") (details above)"
}

_security_stop() { # _security_stop MESSAGE : power Hermes off hard, then stop with a SECURITY error
  "$VMRUN" -T fusion stop "$(vmx_path hermes)" hard >/dev/null 2>&1 || true
  die "SECURITY: $1
    Hermes has been powered off. Re-run ./hermes-vm.sh lockdown, or check its adapter:
      grep -i '^ethernet' \"$(vmx_path hermes)\"
    It must have only ethernet0, with connectionType = \"custom\", vnet = \"$FUSION_VMNET\" and no bsdname line."
}

# Once Hermes is up, prove it isn't somewhere it shouldn't be: not bridged, and the Mac not on its network.
_check_hermes_isolation() {
  local hv ip waited=0
  hv=$(vmx_path hermes)
  if grep -iqE '^ethernet[0-9]+\.bsdname' "$hv"; then _security_stop "Hermes's adapter is set to bridge onto a Mac interface."; fi
  if ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -q "^${VM_SUBNET%.*}\."; then
    _security_stop "the Mac has an address on the Hermes network ($VM_SUBNET/24); $FUSION_VMNET should have no Mac adapter.
    In Fusion > Settings > Network, untick 'Connect Macs to this network' for $FUSION_VMNET."
  fi
  while [ "$waited" -lt 60 ]; do   # VMware Tools reports the address a little after boot
    ip=$(vm_reported_ip hermes)
    [ -n "$ip" ] && break
    sleep 5; waited=$((waited + 5))
  done
  case "$ip" in
    "") warn "VMware Tools hasn't reported Hermes's address yet; carrying on (SSH below goes only via the router)" ;;
    "${VM_SUBNET%.*}".*) ok "Hermes is on the isolated network at $ip" ;;
    *) _security_stop "Hermes got $ip, which is NOT on the Hermes network ($VM_SUBNET/24)." ;;
  esac
}

cmd_start() {
  load_config; _require_vm
  say "Starting"
  if vm_locked hermes; then
    vm_exists router || die "Hermes is locked down but the router VM is missing. Run: ./hermes-vm.sh build"
    _start_one router
    if [ -x "$PF_LOADER" ]; then
      info "Binding the Mac's firewall to the router's network"
      sudo "$PF_LOADER"
    fi
    info "Waiting for the router (up to 3 minutes)"
    vm_wait_ssh router || { vm_no_ip_help router; die "The router isn't answering SSH at $ROUTER_WAN_IP"; }
    ok "Router up at $ROUTER_WAN_IP"
    _start_one hermes
    _check_hermes_isolation
    info "Waiting for Hermes's SSH, via the router (up to 3 minutes)"
    vm_wait_ssh hermes || { vm_no_ip_help hermes; die "Hermes isn't answering SSH at $HERMES_IP (through the router)"; }
    ok "Hermes running at $HERMES_IP  (./hermes-vm.sh ssh)"
    _sync_container_limits
    _choose_model "${HERMES_VM_MODEL:-}"
  else
    # Build stage: Hermes (and the router, if built) are still on Fusion's default network.
    _start_one hermes
    local ip
    info "Waiting for the VM to report its address (up to 2 minutes)"
    ip=$(vm_ip hermes)
    [ -n "$ip" ] || { vm_no_ip_help hermes; die "The VM started but didn't report an IP address"; }
    info "Waiting for SSH on $ip (the VM may still be booting; up to 3 minutes)"
    vm_wait_ssh hermes || die "The VM is at $ip but SSH isn't answering after 3 minutes.
    Open the VM's console in VMware Fusion to see whether it finished booting, then re-run the same command."
    ok "Running at $ip, not yet locked down (./hermes-vm.sh lockdown)"
  fi
}

cmd_stop() {
  load_config; _require_vm
  say "Stopping"
  local role
  for role in hermes router; do   # Hermes first: it should never be up without its router
    vm_exists "$role" || continue
    if vm_running "$role"; then
      "$VMRUN" -T fusion stop "$(vmx_path "$role")" soft || "$VMRUN" -T fusion stop "$(vmx_path "$role")" hard
      ok "$(vm_name_of "$role") stopped"
    else
      ok "$(vm_name_of "$role") not running"
    fi
  done
}

cmd_status() {
  load_config
  say "hermes-vm status"
  local role
  for role in hermes router; do
    if ! vm_exists "$role"; then warn "$(vm_name_of "$role"): not built yet"
    elif vm_running "$role"; then
      if vm_locked "$role"; then ok "$(vm_name_of "$role"): running, locked down ($(vm_ip "$role"))"
      else ok "$(vm_name_of "$role"): running, NOT yet locked down ($(VM_IP_WAIT=0 vm_ip "$role"))"; fi
    else info "$(vm_name_of "$role"): stopped"; fi
  done

  if [ -f "$PF_ANCHOR_FILE" ]; then
    local iface
    iface=$(cat /var/run/hermes-vm-pf.iface 2>/dev/null || echo "?")
    if [ "$iface" = "none" ]; then info "Mac firewall anchor installed (interface rules waiting for the router to start)"
    else ok "Mac firewall anchor installed, bound to $iface"; fi
  else warn "Mac firewall anchor not installed (./hermes-vm.sh host)"; fi

  if launchctl print "gui/$(id -u)/$CADDY_AGENT_LABEL" 2>/dev/null | grep -q 'state = running'; then
    ok "Ollama gateway running on $UPLINK_GW:$LLM_PORT (Hermes uses $VM_GW:$LLM_PORT)"
  else
    info "Ollama gateway not serving yet (it starts once the router's network is up)"
  fi
}

cmd_ssh() {
  load_config; _require_vm; ensure_agent_key
  vm_ssh "$@"
}

cmd_ssh_router() {
  load_config; vm_exists router || die "No router VM yet. Run: ./hermes-vm.sh build"
  ensure_agent_key
  vm_ssh --router "$@"
}

cmd_setup_hermes() {
  load_config; _require_vm; ensure_agent_key
  vm_running hermes || cmd_start
  say "Hermes first run"
  cat <<EOF
    The Hermes setup wizard runs inside the VM. When it asks for a model provider, choose a
    custom / OpenAI-compatible endpoint and enter:

      Base URL : http://$VM_GW:$LLM_PORT/v1
      API key  : no-key
      Model    : $LLM_MODEL

    Only give Hermes credentials made for it (scoped, revocable): its shell can read its .env.
    You'll be asked for the VM admin password once, for sudo.
EOF
  offer_password_clipboard
  vm_ssh -t "sudo machinectl shell hermes@ /bin/bash -lc 'cd ~/hermes && docker compose run --rm hermes setup && docker compose up -d && docker compose ps'"
  ok "Hermes is running. Watch requests arrive with: ./hermes-vm.sh logs"
}

cmd_verify() {
  load_config; _require_vm; ensure_agent_key
  vm_locked hermes || die "Hermes isn't locked down yet. Run: ./hermes-vm.sh lockdown"
  { vm_running hermes && vm_running router; } || cmd_start
  local mac_ip router
  mac_ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  router=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}' || true)
  say "Isolation tests (run inside the VM, as root, to simulate a fully compromised guest)"
  info "Pass 1 runs with Hermes's own firewall on. Pass 2 switches it off, so only the router VM stands"
  info "between Hermes and your network; Hermes's firewall is restored automatically afterwards."
  vm_scp "$REPO/guest/verify-guest.sh" /tmp/hermes-verify.sh
  local rc=0
  vm_sudo "bash /tmp/hermes-verify.sh '$VM_GW' '$LLM_PORT' '$mac_ip' '$router' '$UPLINK_GW'" || rc=$?
  vm_ssh -o BatchMode=yes "rm -f /tmp/hermes-verify.sh" || true

  say "Mac firewall counters (blocked packets from the router's network)"
  sudo pfctl -a "$PF_ANCHOR_NAME" -vs rules 2>/dev/null | awk '/^block/ {rule=$0; getline; print "    " $0 "   <- " rule}' | sed 's/  */ /g'
  [ "$rc" -eq 0 ] && ok "All isolation tests passed" || die "$rc test(s) failed - don't add secrets until they pass"
}

cmd_logs() {
  load_config
  info "Ollama gateway requests from the VM (Ctrl-C to stop)"
  tail -n 20 -F "$LOG_DIR/hermes-vm-gateway.log"
}

cmd_uninstall() {
  # shellcheck disable=SC1090
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"   # not load_config: uninstall must work with older settings too
  say "Uninstall hermes-vm"
  info "Removes the Mac-side pieces. You'll be asked separately about the VM, SSH key and Keychain entry."
  yes_default "Continue?" || exit 0
  sudo -v

  # Ollama gateway
  launchctl bootout "gui/$(id -u)/$CADDY_AGENT_LABEL" >/dev/null 2>&1 || true
  rm -f "$CADDY_AGENT_PLIST"
  ok "Ollama gateway removed"

  # Firewall
  sudo launchctl bootout "system/$PF_DAEMON_LABEL" >/dev/null 2>&1 || true
  sudo rm -f "$PF_DAEMON_PLIST" /var/run/hermes-vm-pf.iface
  sudo pfctl -a "$PF_ANCHOR_NAME" -F all >/dev/null 2>&1 || true
  sudo rm -f "$PF_ANCHOR_FILE"
  sudo rm -rf "$SUPPORT_DIR"
  ok "Firewall anchor and loader removed"

  # VMs
  local role dir
  for role in hermes router; do
    [ -n "${VM_DIR:-}" ] || break
    [ "$role" = router ] && [ -z "${ROUTER_DIR:-}" ] && continue
    dir=$(vm_dir_of "$role")
    if vm_exists "$role" && no_default "Delete the VM at $dir?"; then
      vm_running "$role" && "$VMRUN" -T fusion stop "$(vmx_path "$role")" hard >/dev/null 2>&1 || true
      "$VMRUN" -T fusion deleteVM "$(vmx_path "$role")" >/dev/null 2>&1 || true
      rm -rf "$dir"
      forget_host_key "$role"
      ok "$(vm_name_of "$role") deleted"
    fi
  done

  # Fusion networks
  local vmnet n k changed=no
  for vmnet in ${FUSION_VMNET:-} ${UPLINK_VMNET:-}; do
    grep -q "^answer VNET_${vmnet#vmnet}_" "$FUSION_PREFS/networking" 2>/dev/null || continue
    no_default "Remove the Fusion network $vmnet?" || continue
    fusion_quit_wait
    n=${vmnet#vmnet}
    for k in DHCP NAT HOSTONLY_NETMASK HOSTONLY_SUBNET VIRTUAL_ADAPTER; do
      sudo "$FUSION_LIB/vmnet-cfgcli" vnetcfgremove "VNET_${n}_$k" >/dev/null 2>&1 || true
    done
    changed=yes
  done
  if [ "$changed" = yes ]; then
    sudo "$FUSION_LIB/vmnet-cli" --configure >/dev/null 2>&1 || true
    sudo "$FUSION_LIB/vmnet-cli" --stop >/dev/null 2>&1 || true
    sudo "$FUSION_LIB/vmnet-cli" --start >/dev/null 2>&1 || true
    ok "Fusion network(s) removed"
  fi

  if [ -n "${ADMIN_USER:-}" ] && keychain_has "$ADMIN_USER" && no_default "Delete the VM admin password from your Keychain?"; then
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$ADMIN_USER" >/dev/null
    ok "Keychain entry deleted"
  fi

  if [ -f "$SSH_KEY" ] && no_default "Delete the SSH key $SSH_KEY?"; then
    ssh-add -d "$SSH_KEY" >/dev/null 2>&1 || true
    rm -f "$SSH_KEY" "$SSH_KEY.pub"
    ok "SSH key deleted"
  fi

  if [ -d "$CONFIG_DIR" ] && no_default "Delete settings and the downloaded ISO ($CONFIG_DIR)?"; then
    rm -rf "$CONFIG_DIR"
    ok "Settings deleted"
  fi
  ok "Uninstall complete"
}
