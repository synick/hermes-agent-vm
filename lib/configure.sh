# shellcheck shell=bash
# configure: every question is asked here, up front. Later steps only read what's saved.

_detect_timezone() {
  local tz
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' || true)
  echo "${tz:-UTC}"
}

_next_free_vmnet() { # _next_free_vmnet [vmnetN to skip]
  local n=2
  while [ $n -lt 20 ]; do
    if [ "vmnet$n" != "${1:-}" ] && ! grep -q "^answer VNET_${n}_" "$FUSION_PREFS/networking" 2>/dev/null; then echo "vmnet$n"; return; fi
    n=$((n + 1))
  done
  echo "vmnet$((n + 1))"
}

_first_ollama_model() {
  command -v ollama >/dev/null || return 0
  ollama list 2>/dev/null | awk 'NR==2 {print $1}' || true
}

# 0 = subnet clashes with a network the Mac is on, or with a *different* Fusion network
_subnet_conflict() {
  local subnet=$1 vmnet=$2 p n
  p="${subnet%.*}"                       # e.g. 172.16.42
  n=${vmnet#vmnet}
  # Our own network already configured with this subnet is fine (re-runs).
  grep -q "^answer VNET_${n}_HOSTONLY_SUBNET ${subnet}$" "$FUSION_PREFS/networking" 2>/dev/null && return 1
  grep "_HOSTONLY_SUBNET ${subnet}$" "$FUSION_PREFS/networking" 2>/dev/null | grep -vq "VNET_${n}_" && return 0
  ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -q "^${p//./\\.}\." && return 0
  return 1
}

_valid_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] ;; esac; }

# ---------- validation (shared by the review screen and the edit questions) ----------
_bad_name()   { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9-]{0,40}$ ]] && return 1; echo "VM name: use letters, digits and hyphens, starting with a letter (it also becomes the hostname, in lowercase)"; }
_bad_int()    { _valid_int "$2" "$3" "$4" && return 1; echo "$1: enter a number from $3 to $4"; }
_bad_admin()  {
  case "$1" in hermes|root) echo "Admin username: '$1' is reserved"; return 0 ;; esac
  [[ "$1" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] && return 1
  echo "Admin username: lowercase letters, digits, - or _, starting with a letter"
}
_bad_iso()    { [ -z "$1" ] || [ -f "$1" ] && return 1; echo "ISO: no file at $1"; }
_bad_vmnet()  { # _bad_vmnet VALUE OTHER_VMNET
  [[ "$1" =~ ^vmnet[0-9]+$ ]] || { echo "Fusion network: use the form vmnetN"; return 0; }
  case "$1" in vmnet0|vmnet1|vmnet8) echo "Fusion network: $1 is one of Fusion's defaults; pick another so the firewall covers only these VMs"; return 0 ;; esac
  [ "$1" = "${2:-}" ] && { echo "Fusion networks: the Hermes network and the router uplink must be different networks"; return 0; }
  return 1
}
_bad_subnet() { # _bad_subnet VALUE VMNET OTHER_SUBNET
  [[ "$1" =~ ^([0-9]{1,3}\.){3}0$ ]] || { echo "Subnet: use the form a.b.c.0 (a /24)"; return 0; }
  [ "$1" = "${3:-}" ] && { echo "Subnets: the Hermes network and the router uplink need different subnets"; return 0; }
  _subnet_conflict "$1" "$2" && { echo "Subnet: $1/24 is already in use on this Mac or by another Fusion network"; return 0; }
  return 1
}
_bad_port()   { _valid_int "$1" 1024 65535 && [ "$1" != 11434 ] && return 1; echo "Gateway port: pick a free port from 1024 to 65535 (not 11434, Ollama's own)"; }
_bad_model()  { [ -n "$1" ] && return 1; echo "Model: no Ollama model found. Pull one (e.g. ollama pull qwen3:14b) or type its name"; }

_config_problems() { # prints one line per invalid setting; prints nothing if all is well
  _bad_name "$VM_NAME" || true
  _bad_int "vCPUs" "$CPUS" 2 32 || true
  _bad_int "Memory (GB)" "$MEMORY_GB" 3 128 || true
  _bad_int "Disk (GB)" "$DISK_GB" 30 2000 || true
  _bad_admin "$ADMIN_USER" || true
  _bad_iso "$ISO_PATH" || true
  _bad_vmnet "$FUSION_VMNET" "$UPLINK_VMNET" || true
  _bad_vmnet "$UPLINK_VMNET" "$FUSION_VMNET" || true
  _bad_subnet "$VM_SUBNET" "$FUSION_VMNET" "$UPLINK_SUBNET" || true
  _bad_subnet "$UPLINK_SUBNET" "$UPLINK_VMNET" "$VM_SUBNET" || true
  _bad_port "$LLM_PORT" || true
  _bad_model "$LLM_MODEL" || true
}

# ---------- defaults, review screen, edit questions ----------
_config_derive() {
  VM_DIR="$HOME/Virtual Machines.localized/$VM_NAME.vmwarevm"
  VM_GW="${VM_SUBNET%.*}.1"           # the router, as Hermes sees it (Hermes's gateway and Ollama endpoint)
  HERMES_IP="${VM_SUBNET%.*}.10"      # fixed by the router's DHCP
  UPLINK_GW="${UPLINK_SUBNET%.*}.1"   # the Mac on the uplink network (Ollama gateway listens here)
  UPLINK_NAT="${UPLINK_SUBNET%.*}.2"  # VMware's NAT router on the uplink network
  ROUTER_WAN_IP="${UPLINK_SUBNET%.*}.10"
  ROUTER_NAME="${VM_NAME}-router"
  ROUTER_DIR="$HOME/Virtual Machines.localized/$ROUTER_NAME.vmwarevm"
}

_random_vmware_mac() { # VMware's range for manually set addresses: 00:50:56:00:00:00 - 00:50:56:3F:FF:FF
  printf '00:50:56:%02x:%02x:%02x\n' $((RANDOM % 64)) $((RANDOM % 256)) $((RANDOM % 256))
}

_config_fill_defaults() { # keep anything already saved; fill the rest with defaults
  VM_NAME="${VM_NAME:-hermes-vm}"
  CPUS="${CPUS:-2}"
  MEMORY_GB="${MEMORY_GB:-4}"
  DISK_GB="${DISK_GB:-60}"
  ADMIN_USER="${ADMIN_USER:-vmadmin}"
  TIMEZONE="${TIMEZONE:-$(_detect_timezone)}"
  UBUNTU_VERSION="${UBUNTU_VERSION:-26.04.1}"
  ISO_PATH="${ISO_PATH:-}"
  FUSION_VMNET="${FUSION_VMNET:-$(_next_free_vmnet)}"
  VM_SUBNET="${VM_SUBNET:-172.16.42.0}"
  UPLINK_VMNET="${UPLINK_VMNET:-$(_next_free_vmnet "$FUSION_VMNET")}"
  UPLINK_SUBNET="${UPLINK_SUBNET:-172.16.43.0}"
  ROUTER_LAN_MAC="${ROUTER_LAN_MAC:-$(_random_vmware_mac)}"
  LLM_PORT="${LLM_PORT:-11435}"
  DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"
  LLM_MODEL="${LLM_MODEL:-$(_first_ollama_model)}"
  HERMES_TAG="${HERMES_TAG:-latest}"
  HEADLESS="${HEADLESS:-false}"
  ISO_SHA256="${ISO_SHA256:-}"
  _config_derive
}

_config_show() {
  local window="shown (recommended the first time)"
  [ "$HEADLESS" = "true" ] && window="hidden"
  cat <<EOF

    ${B}Virtual machine${X}
      Name              $VM_NAME
      CPU / memory      $CPUS vCPU, $MEMORY_GB GB RAM (Hermes container: $(( MEMORY_GB > 2 ? MEMORY_GB - 1 : 1 )) GB; change any time, applies at next start)
      Disk              $DISK_GB GB
      Admin user        $ADMIN_USER
      Timezone          $TIMEZONE
      Install window    $window
    ${B}Ubuntu${X}
      Version           $UBUNTU_VERSION LTS (arm64)
      ISO               ${ISO_PATH:-download and GPG-verify automatically (about 3 GB)}
    ${B}Network${X}  (Hermes -> router VM -> internet; the Mac is not on Hermes's network)
      Hermes network    $FUSION_VMNET, $VM_SUBNET/24: Hermes $HERMES_IP, router $VM_GW
      Router uplink     $UPLINK_VMNET, $UPLINK_SUBNET/24 (Fusion NAT): router $ROUTER_WAN_IP, the Mac $UPLINK_GW
      Ollama gateway    Hermes uses http://$VM_GW:$LLM_PORT (the router passes it to the Mac's $UPLINK_GW:$LLM_PORT)
      Router VM         $ROUTER_NAME (1 vCPU, 1 GB RAM, 12 GB disk)
      DNS servers       $DNS_SERVERS
    ${B}Hermes${X}
      Model             ${LLM_MODEL:-(none found)}
      Image tag         $HERMES_TAG (pinned to its digest at build time)
EOF
}

_ask_valid() { # _ask_valid VAR "Question" validator [extra validator args...]
  local __var=$1 __q=$2 __check=$3 __msg; shift 3
  while :; do
    ask "$__var" "$__q" "${!__var-}"
    if __msg=$("$__check" "${!__var-}" "$@"); then warn "$__msg"; else return 0; fi
  done
}
_ask_int() { # _ask_int VAR "Question" min max
  local __var=$1 __q=$2 __msg
  while :; do
    ask "$__var" "$__q" "${!__var-}"
    if __msg=$(_bad_int "$__q" "${!__var-}" "$3" "$4"); then warn "$__msg"; else return 0; fi
  done
}

_config_edit() {
  echo; info "Press Enter to keep the value in [brackets]."
  echo; info "${B}Virtual machine${X}"
  _ask_valid VM_NAME "VM name" _bad_name
  _ask_int   CPUS "vCPUs" 2 32
  _ask_int   MEMORY_GB "Memory (GB)" 3 128
  _ask_int   DISK_GB "Disk (GB)" 30 2000
  _ask_valid ADMIN_USER "Admin username inside the VM" _bad_admin
  ask TIMEZONE "Timezone" "$TIMEZONE"
  local show="Y/n"; [ "$HEADLESS" = "true" ] && show="y/N"
  local a=""; read -r -p "    Show the VM window during the install? [$show]: " a || true
  case "$a" in [yY]*) HEADLESS=false ;; [nN]*) HEADLESS=true ;; esac

  echo; info "${B}Ubuntu${X}"
  ask UBUNTU_VERSION "Ubuntu Server LTS version (arm64)" "$UBUNTU_VERSION"
  info "${D}Leave blank to download automatically. Type - to clear a saved path.${X}"
  ask ISO_PATH "Path to an ISO you already have" "$ISO_PATH"
  [ "$ISO_PATH" = "-" ] && ISO_PATH=""
  ISO_PATH="${ISO_PATH/#\~/$HOME}"
  local isomsg
  if isomsg=$(_bad_iso "$ISO_PATH"); then warn "$isomsg"; ISO_PATH=""; fi

  echo; info "${B}Network${X}"
  info "${D}Two VMware Fusion networks: one shared only by Hermes and the router, and the router's own NAT uplink.${X}"
  info "${D}Pick /24s that no network you join will use.${X}"
  _ask_valid FUSION_VMNET "Hermes network (Fusion network name)" _bad_vmnet "$UPLINK_VMNET"
  _ask_valid VM_SUBNET "Hermes network subnet (x.y.z.0)" _bad_subnet "$FUSION_VMNET" "$UPLINK_SUBNET"
  _ask_valid UPLINK_VMNET "Router uplink (Fusion network name)" _bad_vmnet "$FUSION_VMNET"
  _ask_valid UPLINK_SUBNET "Router uplink subnet (x.y.z.0)" _bad_subnet "$UPLINK_VMNET" "$VM_SUBNET"
  _ask_valid LLM_PORT "Ollama gateway port on the Mac" _bad_port
  ask DNS_SERVERS "Public DNS servers for the VM" "$DNS_SERVERS"

  echo; info "${B}Hermes${X}"
  _ask_valid LLM_MODEL "Ollama model for Hermes" _bad_model
  ask HERMES_TAG "Hermes image tag" "$HERMES_TAG"
  _config_derive
}

cmd_configure() {
  say "Configuration"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    info "Your saved settings:"
  else
    info "Suggested settings:"
  fi
  _config_fill_defaults

  local problems choice
  while :; do
    _config_show
    problems=$(_config_problems)
    if [ -n "$problems" ]; then
      echo
      printf '%s\n' "$problems" | while IFS= read -r line; do warn "$line"; done
      info "Those need changing before the build can run."
      _config_edit
      continue
    fi
    echo
    choice=""
    read -r -p "    Press Enter to use these settings, or type e to edit them: " choice || true
    case "$choice" in
      ""|[yY]*) break ;;
      [eE]*)    _config_edit ;;
      *)        warn "Press Enter, or type e" ;;
    esac
  done

  save_config
  ok "Settings saved to $CONFIG_FILE (readable only by you)"

  _configure_password
  _configure_ssh_key
  ok "Configuration complete"
}

_configure_password() {
  echo; info "${B}VM admin password${X}"
  if keychain_has "$ADMIN_USER"; then
    if ! no_default "A password for '$ADMIN_USER' is already in your Keychain. Replace it?"; then
      ok "Keeping the existing Keychain password"
      return
    fi
  fi
  info "Used for sudo inside the VM. At least 14 characters, no single quotes."
  info "macOS will ask for it twice and store it in your login Keychain (it never touches disk here)."
  local pw
  while :; do
    security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$ADMIN_USER" \
      -l "hermes-vm admin password ($ADMIN_USER)" -w || { warn "Keychain didn't accept that; try again"; continue; }
    pw=$(keychain_get "$ADMIN_USER" || true)
    if [ ${#pw} -lt 14 ]; then warn "Too short (${#pw} characters)"; continue; fi
    case "$pw" in *"'"*) warn "Single quotes aren't allowed"; continue ;; esac
    break
  done
  pw=""
  ok "Password stored in your login Keychain (service \"$KEYCHAIN_SERVICE\", account \"$ADMIN_USER\")"
}

_configure_ssh_key() {
  echo; info "${B}SSH key${X}"
  if [ ! -f "$SSH_KEY" ]; then
    info "Creating $SSH_KEY. Choose a passphrase: it's saved in your Keychain, so you won't need to type it again."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -a 100 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY"
  else
    ok "Using existing $SSH_KEY"
  fi
  ensure_agent_key
  ok "SSH key loaded in ssh-agent"
}
