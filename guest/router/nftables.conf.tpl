#!/usr/sbin/nft -f
# hermes-vm router firewall. This is the isolation boundary: Hermes's only network link ends at this VM.
#   lan = the Hermes network (only Hermes and this router are on it; the Mac is not)
#   wan = the uplink to VMware Fusion's NAT, where the Mac is @UPLINK_GW@
# Policy for Hermes: the internet, plus one forwarded port to the Mac's Ollama gateway. No local networks, ever.
flush ruleset

define MAC        = @UPLINK_GW@
define LAN_IP     = @VM_GW@
define HERMES     = @HERMES_IP@
define LLM_PORT   = @LLM_PORT@

table inet router {
  set nonpublic4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
                 224.0.0.0/4, 240.0.0.0/4 }
  }

  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    iifname "wan" ip saddr $MAC tcp dport 22 accept             # admin SSH, from the Mac only
    iifname "lan" udp sport 68 udp dport 67 accept              # DHCP for Hermes
    meta pkttype { broadcast, multicast } drop                   # LAN chatter (discovery etc.): drop, don't log
    limit rate 6/minute log prefix "router-in-drop: " level info
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    # The Ollama gateway: only via the port forward below, only to the gateway port on the Mac.
    iifname "lan" oifname "wan" ip saddr $HERMES ct status dnat ip daddr $MAC tcp dport $LLM_PORT counter accept
    # Every local, private and special-purpose range: the Mac, your LAN, hotspots, Tailscale, link-local.
    iifname "lan" ip daddr @nonpublic4 limit rate 6/minute log prefix "router-fwd-local: " level warn
    iifname "lan" ip daddr @nonpublic4 counter drop
    # The internet, from Hermes's reserved address only.
    iifname "lan" oifname "wan" ip saddr $HERMES counter accept
    limit rate 6/minute log prefix "router-fwd-drop: " level info
  }

  chain output {
    type filter hook output priority filter; policy accept;
    ct state established,related accept
    oif "lo" accept
    meta nfproto ipv6 drop
    oifname "lan" udp sport 67 accept                           # DHCP offers to Hermes
    oifname "lan" ip daddr $HERMES tcp dport 22 accept          # the Mac's SSH hop into Hermes
    oifname "lan" drop                                          # nothing else towards Hermes
    ip daddr @nonpublic4 limit rate 6/minute log prefix "router-out-local: " level warn
    ip daddr @nonpublic4 drop                                   # the router itself stays off local networks too
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "lan" ip daddr $LAN_IP tcp dport $LLM_PORT dnat to $MAC:$LLM_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wan" masquerade
  }
}
