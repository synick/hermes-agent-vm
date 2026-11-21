# shellcheck shell=bash
# lockdown: stage 2. Wire Hermes so that its only link to anything is the router VM.
#
#   Hermes ──[$FUSION_VMNET: isolated, no Mac]── router VM ──[$UPLINK_VMNET: Fusion NAT]── internet
#                                                    └─ port forward ──> Mac $UPLINK_GW:$LLM_PORT (Ollama gateway)
#
#   1. Configure the router (firewall, forwarding, DHCP for Hermes) while it's still reachable
#   2. Mac side: the two Fusion networks, pf anchor, Ollama gateway   (cmd_host)
#   3. Rewire both VMs' network adapters, boot them, check nothing is bridged or on the Mac's network
#   4. Hermes's own firewall, snapshots, then prove the isolation with 'verify'

vmx_get() { # vmx_get FILE KEY -> value (case-insensitive key)
  local qk
  qk=$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')
  grep -iE "^${qk} = " "$1" 2>/dev/null | head -1 | sed 's/^[^"]*"\(.*\)".*/\1/' || true
}

# The router's two adapters get fixed MAC addresses (VMware's manual range), so the router can name them
# "wan" and "lan" by MAC whatever order they appear in. The uplink one is derived from the saved lan one.
_router_wan_mac() {
  local last=${ROUTER_LAN_MAC##*:}
  printf '%s:%02x\n' "${ROUTER_LAN_MAC%:*}" $(( 0x$last ^ 1 ))
}

_vmx_nic() { # _vmx_nic VMX ethernetN VNET [static-MAC]
  local vmx=$1 eth=$2 vnet=$3 mac=${4:-}
  # Packer writes "<eth>.bsdName = en0" (bridged mode: which Mac interface to bridge to). With a custom network it
  # would bridge the VM straight onto the Mac's Wi-Fi/LAN, bypassing everything. Remove it.
  vmx_del "$vmx" "${eth}\\.bsdname"
  vmx_set "$vmx" "$eth.present" TRUE
  vmx_set "$vmx" "$eth.connectionType" custom
  vmx_set "$vmx" "$eth.vnet" "$vnet"
  if [ -n "$mac" ]; then
    vmx_del "$vmx" "${eth}\\.generatedaddress(offset)?"
    vmx_set "$vmx" "$eth.addressType" static
    vmx_set "$vmx" "$eth.address" "$mac"
  fi
  grep -iq "^$eth\\.vnet = \"$vnet\"" "$vmx" || die "Couldn't set $eth in $vmx"
}

_vmx_disable_other_nics() { # _vmx_disable_other_nics VMX KEEP...   (e.g. ethernet0 ethernet1)
  local vmx=$1 eth k keep; shift
  for eth in $(grep -ioE '^ethernet[0-9]+\.present' "$vmx" | cut -d. -f1 | tr 'A-Z' 'a-z' | sort -u || true); do
    keep=no
    for k in "$@"; do [ "$eth" = "$k" ] && keep=yes; done
    [ "$keep" = yes ] || vmx_set "$vmx" "$eth.present" FALSE
  done
}

_rewire_vms() {
  say "Rewiring the VMs"
  local rv hv dev
  rv=$(vmx_path router); hv=$(vmx_path hermes)
  dev=$(vmx_get "$rv" ethernet0.virtualDev); dev=${dev:-vmxnet3}

  _vmx_disable_other_nics "$rv" ethernet0 ethernet1
  _vmx_nic "$rv" ethernet0 "$UPLINK_VMNET" "$(_router_wan_mac)"
  _vmx_nic "$rv" ethernet1 "$FUSION_VMNET" "$ROUTER_LAN_MAC"
  vmx_set "$rv" ethernet1.virtualDev "$dev"
  ok "Router: uplink on $UPLINK_VMNET, inside leg on $FUSION_VMNET"

  _vmx_disable_other_nics "$hv" ethernet0
  _vmx_nic "$hv" ethernet0 "$FUSION_VMNET"
  ok "Hermes: one adapter, on $FUSION_VMNET only"

  if grep -iqE '^ethernet[0-9]+\.bsdname' "$rv" "$hv"; then die "Couldn't remove the bridged-mode setting from the VMs"; fi
}

# Files for a script run as root in a VM: packed with no macOS extended attributes, copied, unpacked to /tmp.
_push_bundle() { # _push_bundle [--router] NAME FILE...
  local flag="" name tmp f
  [ "${1:-}" = --router ] && { flag=--router; shift; }
  name=$1; shift
  tmp=$(mktemp -d)
  for f in "$@"; do cp "$f" "$tmp/"; done
  (cd "$tmp" && COPYFILE_DISABLE=1 tar --no-xattrs -czf bundle.tgz ./*)
  vm_scp $flag "$tmp/bundle.tgz" "/tmp/$name.tgz"
  rm -rf "$tmp"
}

_configure_router() {
  say "Router VM ($ROUTER_NAME)"
  if ! vm_running router; then
    info "Starting it"
    _vm_power_on router || die "VMware couldn't start $ROUTER_NAME (details above)"
  fi
  if vm_locked router && [ -x "$PF_LOADER" ]; then
    info "Re-applying the Mac's firewall for the router's network (your Mac password, for sudo)"
    sudo "$PF_LOADER"
  fi
  info "Waiting for SSH (up to 3 minutes)"
  vm_wait_ssh router || { vm_no_ip_help router; die "Can't reach $ROUTER_NAME over SSH"; }
  _push_bundle --router hermes-router "$REPO/guest/router/60-router.sh" "$REPO/guest/router/nftables.conf.tpl"
  vm_ssh --router -o BatchMode=yes "rm -rf /tmp/hermes-router && mkdir -p /tmp/hermes-router && tar -xzf /tmp/hermes-router.tgz -C /tmp/hermes-router" \
    || die "Couldn't copy the router's configuration to it"
  local rc=0
  vm_sudo --router "env VM_GW='$VM_GW' HERMES_IP='$HERMES_IP' UPLINK_GW='$UPLINK_GW' UPLINK_NAT='$UPLINK_NAT' \
      ROUTER_WAN_IP='$ROUTER_WAN_IP' ROUTER_WAN_MAC='$(_router_wan_mac)' ROUTER_LAN_MAC='$ROUTER_LAN_MAC' \
      LLM_PORT='$LLM_PORT' DNS_SERVERS='$DNS_SERVERS' FW_FILES=/tmp/hermes-router bash /tmp/hermes-router/60-router.sh" || rc=$?
  vm_ssh --router -o BatchMode=yes "rm -rf /tmp/hermes-router /tmp/hermes-router.tgz" || true
  [ "$rc" -eq 0 ] || die "Configuring the router failed (see above); nothing was changed on it"
  ok "Router configured: Hermes gets the internet and the Ollama gateway, nothing local (active from its next boot)"
}

_apply_guest_firewall() {
  say "Hermes's own firewall (nftables inside the Hermes VM)"
  # 30-firewall.sh expects the template under nftables/
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/nftables"
  cp "$REPO/guest/files/nftables/nftables.conf.tpl" "$tmp/nftables/"
  cp "$REPO/guest/scripts/30-firewall.sh" "$tmp/"
  (cd "$tmp" && COPYFILE_DISABLE=1 tar --no-xattrs -czf fw.tgz 30-firewall.sh nftables)
  vm_scp "$tmp/fw.tgz" /tmp/hermes-fw.tgz
  rm -rf "$tmp"
  vm_ssh -o BatchMode=yes "rm -rf /tmp/hermes-fw && mkdir -p /tmp/hermes-fw && tar -xzf /tmp/hermes-fw.tgz -C /tmp/hermes-fw" \
    || die "Couldn't copy the firewall files to Hermes"
  local rc=0
  vm_sudo "env VM_GW='$VM_GW' LLM_PORT='$LLM_PORT' FW_FILES=/tmp/hermes-fw bash /tmp/hermes-fw/30-firewall.sh" || rc=$?
  vm_ssh -o BatchMode=yes "rm -rf /tmp/hermes-fw /tmp/hermes-fw.tgz" || true
  [ "$rc" -eq 0 ] || die "Applying Hermes's firewall failed (see above)"
  ok "Hermes firewall active: SSH only via the router; out: internet + Ollama gateway, no local networks"
}

_snapshot() { # _snapshot ROLE NAME
  vm_clear_stale_locks "$1"
  "$VMRUN" -T fusion deleteSnapshot "$(vmx_path "$1")" "$2" >/dev/null 2>&1 || true
  "$VMRUN" -T fusion snapshot "$(vmx_path "$1")" "$2"
  vm_clear_stale_locks "$1"
}

cmd_lockdown() {
  load_config
  export_config
  vm_exists hermes || die "No Hermes VM at $VM_DIR yet. Run: ./hermes-vm.sh build"
  vm_exists router || die "No router VM at $ROUTER_DIR yet. Run: ./hermes-vm.sh build  (it builds just what's missing)"
  local role
  for role in hermes router; do
    case "$(vm_stage "$role")" in
      none|installed|base) die "$(vm_name_of "$role") isn't provisioned yet. Run: ./hermes-vm.sh  (it carries on from where things are)" ;;
    esac
  done
  ensure_agent_key

  say "Lockdown, stage 3 of 4"
  info "Puts Hermes on a private network shared only with the router VM, which is its one way out:"
  info "internet yes, the Ollama gateway yes, the Mac and every local network no. Then tests it."

  _configure_router

  say "Shutting both VMs down to rewire them"
  vm_stop hermes
  vm_stop router
  ok "Stopped"

  cmd_host
  _rewire_vms

  cmd_start
  _apply_guest_firewall

  say "Snapshots"
  info "Shutting down first: powered-off snapshots are quick and hold no memory image."
  vm_stop hermes
  vm_stop router
  _snapshot router clean
  _snapshot hermes clean-no-secrets
  ok "Snapshots taken: router 'clean', Hermes 'clean-no-secrets' (locked down, no keys yet)."
  info "Roll back to these rather than repairing a suspect VM."
  cmd_start

  cmd_verify
}
