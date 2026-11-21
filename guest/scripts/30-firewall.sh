#!/usr/bin/env bash
# 30-firewall.sh - Hermes nftables: inbound SSH only via the router; outbound internet + the Ollama gateway, nothing local.
set -euo pipefail
F="${FW_FILES:-/var/tmp/hermes-files}"
log() { echo "==> [30-firewall] $*"; }
: "${VM_GW:?VM_GW not set}" "${LLM_PORT:?LLM_PORT not set}"

log "Rendering /etc/nftables.conf (gateway ${VM_GW}:${LLM_PORT})"
sed -e "s/@VM_GW@/${VM_GW}/g" -e "s/@LLM_PORT@/${LLM_PORT}/g" \
  "$F/nftables/nftables.conf.tpl" > /etc/nftables.conf
chmod 0600 /etc/nftables.conf

log "Lock-out guard: this SSH session must arrive from the router ($VM_GW)"
src="${SSH_CLIENT%% *}"
if [ -n "$src" ] && [ "$src" != "$VM_GW" ]; then
  echo "ERROR: connecting from $src, not the router ($VM_GW). Loading the firewall now would lock this session out." >&2
  exit 1
fi

log "Syntax check, then load"
nft -c -f /etc/nftables.conf
# This SSH session comes through the router (VM_GW), which the input chain allows, so loading now is safe.
nft -f /etc/nftables.conf
systemctl enable nftables

log "Done"
