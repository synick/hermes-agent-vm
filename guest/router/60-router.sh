#!/usr/bin/env bash
# 60-router.sh - turns the router VM into Hermes's only way out. Run as root by `hermes-vm.sh lockdown`.
# Nothing here takes effect until the router's next boot (lockdown restarts it on its new networks), so the SSH
# session running this is never cut off part-way, and a mistake is caught by the checks before anything changes.
set -euo pipefail
F="${FW_FILES:?FW_FILES not set}"
log() { echo "==> [60-router] $*"; }
for v in VM_GW HERMES_IP UPLINK_GW UPLINK_NAT ROUTER_WAN_IP ROUTER_WAN_MAC ROUTER_LAN_MAC LLM_PORT DNS_SERVERS; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v not set" >&2; exit 1; }
done

log "Firewall: render and syntax-check /etc/nftables.conf"
sed -e "s/@VM_GW@/${VM_GW}/g" -e "s/@HERMES_IP@/${HERMES_IP}/g" -e "s/@UPLINK_GW@/${UPLINK_GW}/g" \
    -e "s/@LLM_PORT@/${LLM_PORT}/g" "$F/nftables.conf.tpl" > /tmp/router-nftables.conf
if grep -q '@[A-Z_]*@' /tmp/router-nftables.conf; then echo "ERROR: unrendered placeholder in nftables.conf" >&2; exit 1; fi
nft -c -f /tmp/router-nftables.conf
install -m 0600 /tmp/router-nftables.conf /etc/nftables.conf
rm -f /tmp/router-nftables.conf
systemctl enable nftables >/dev/null 2>&1

log "SSH: the Mac's hop into Hermes may forward to $HERMES_IP:22 and nowhere else"
cat > /etc/ssh/sshd_config.d/91-hermes-router.conf <<EOF
# hermes-vm router: SSH forwarding only to Hermes's SSH port (used by the Mac to reach Hermes).
PermitOpen $HERMES_IP:22
EOF
chmod 0644 /etc/ssh/sshd_config.d/91-hermes-router.conf
sshd -t

log "Interfaces: wan ($ROUTER_WAN_MAC) and lan ($ROUTER_LAN_MAC), named by MAC address"
cat > /etc/systemd/network/10-hermes-wan.link <<EOF
[Match]
MACAddress=$ROUTER_WAN_MAC

[Link]
Name=wan
EOF
cat > /etc/systemd/network/10-hermes-lan.link <<EOF
[Match]
MACAddress=$ROUTER_LAN_MAC

[Link]
Name=lan
EOF

# DHCP on the Hermes network has a pool of exactly one address, Hermes's, so it doesn't depend on Hermes's MAC
# address or DHCP client ID; Hermes is the only machine on that network. (The forward chain only lets that address out.)
log "Addresses: wan $ROUTER_WAN_IP via $UPLINK_NAT; lan $VM_GW, with DHCP handing out $HERMES_IP only"
{
  echo "[Match]"
  echo "Name=wan"
  echo
  echo "[Network]"
  echo "Address=$ROUTER_WAN_IP/24"
  echo "Gateway=$UPLINK_NAT"
  for d in $DNS_SERVERS; do echo "DNS=$d"; done
  echo "LinkLocalAddressing=no"
  echo "IPv6AcceptRA=no"
} > /etc/systemd/network/20-hermes-wan.network
cat > /etc/systemd/network/20-hermes-lan.network <<EOF
[Match]
Name=lan

[Link]
RequiredForOnline=no

[Network]
Address=$VM_GW/24
DHCPServer=yes
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPServer]
PoolOffset=${HERMES_IP##*.}
PoolSize=1
EmitRouter=yes
EmitDNS=yes
DNS=$DNS_SERVERS
EmitNTP=no
DefaultLeaseTimeSec=3600
EOF
chmod 0644 /etc/systemd/network/10-hermes-*.link /etc/systemd/network/20-hermes-*.network

log "Retiring the installer's netplan config (systemd-networkd is configured directly)"
mkdir -p /etc/netplan.disabled-by-hermes-vm
for f in /etc/netplan/*.yaml; do
  [ -e "$f" ] && mv "$f" /etc/netplan.disabled-by-hermes-vm/
done
systemctl enable systemd-networkd >/dev/null 2>&1

log "IPv4 forwarding on (from the next boot)"
cat > /etc/sysctl.d/95-hermes-router.conf <<'EOF'
# hermes-vm router: forward between lan and wan (the firewall decides what may pass).
net.ipv4.ip_forward = 1
EOF

log "Done; applies when the router restarts"
