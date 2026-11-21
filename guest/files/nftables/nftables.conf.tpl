#!/usr/sbin/nft -f
# Hermes VM guest firewall - defence in depth. The real boundary is the router VM (VM_GW), Hermes's only link.
flush ruleset

define VM_GW    = @VM_GW@
define LLM_PORT = @LLM_PORT@

table inet hermes {
  set nonpublic4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16,
                 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
                 224.0.0.0/4, 240.0.0.0/4 }
  }

  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    udp sport 67 udp dport 68 accept                  # DHCP replies
    ip saddr $VM_GW tcp dport 22 accept               # SSH only via the router (the Mac's hop)
    limit rate 6/minute log prefix "nft-in-drop: " level info
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
    ct state established,related accept
    oif "lo" accept
    meta nfproto ipv6 reject                          # IPv6 is off; refuse anything that tries
    udp dport 67 accept                               # DHCP requests
    ip daddr $VM_GW tcp sport 22 accept               # replies on the router's SSH hop (even for a session opened
                                                      # before this firewall loaded, which conntrack may not know)
    ip daddr $VM_GW tcp dport $LLM_PORT accept        # Ollama gateway (the router forwards it to the Mac)
    ip daddr @nonpublic4 limit rate 6/minute log prefix "nft-out-local: " level warn
    ip daddr @nonpublic4 reject                       # no LAN, homelab, Tailscale, link-local, host
  }
}
