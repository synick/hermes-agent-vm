#!/usr/bin/env bash
# Runs INSIDE the VM as root (copied in and removed by `hermes-vm.sh verify`).
# Root in the VM is the worst case: a fully compromised guest. Pass 1 keeps Hermes's own firewall on;
# pass 2 flushes it so only the router VM stands in the way, then restores it.
#   GW = the router VM (Hermes's gateway)   UPLINK_GW = the Mac, on the router's uplink network
set -uo pipefail
GW=${1:?gateway} PORT=${2:?port} MAC_IP=${3-} ROUTER=${4-} UPLINK_GW=${5-}
pass=0; fail=0

result() { # result NAME EXPECT(open|blocked) GOT
  if [ "$2" = "$3" ]; then printf '    \033[32mPASS\033[0m  %-46s %s\n' "$1" "$3"; pass=$((pass + 1))
  else printf '    \033[31mFAIL\033[0m  %-46s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
probe() { # probe NAME EXPECT command...   (command succeeds = reachable; every probe has its own timeout)
  local name=$1 expect=$2; shift 2
  if "$@" >/dev/null 2>&1; then result "$name" "$expect" open; else result "$name" "$expect" blocked; fi
}
tcp()  { nc -z -w 4 "$1" "$2"; }
ping1() { ping -c 1 -W 3 "$1"; }
http_status() { curl -s -o /dev/null -w '%{http_code}' -m 5 "$@"; }

network_tests() {
  probe "Internet: https://github.com"            open    curl -sfI -m 5 https://github.com
  probe "Ollama gateway: model list"              open    bash -c "curl -sf -m 5 http://$GW:$PORT/v1/models | grep -q '\"data\"'"
  if [ "$(http_status -X POST "http://$GW:$PORT/api/pull" -d '{}')" = "403" ]; then result "Gateway refuses /api/pull" open open
  else result "Gateway refuses /api/pull" open "not 403"; fi
  probe "Router VM: Ollama :11434"                blocked tcp "$GW" 11434
  probe "Router VM: SSH :22"                      blocked tcp "$GW" 22
  probe "Router VM: ping"                         blocked ping1 "$GW"
  if [ -n "$UPLINK_GW" ]; then
    probe "Mac $UPLINK_GW (uplink): raw Ollama :11434" blocked tcp "$UPLINK_GW" 11434
    probe "Mac $UPLINK_GW (uplink): gateway direct"    blocked tcp "$UPLINK_GW" "$PORT"
    probe "Mac $UPLINK_GW (uplink): AirPlay :7000"     blocked tcp "$UPLINK_GW" 7000
    probe "Mac $UPLINK_GW (uplink): ping"              blocked ping1 "$UPLINK_GW"
  fi
  if [ -n "$MAC_IP" ]; then
    probe "Mac LAN address $MAC_IP: ping"         blocked ping1 "$MAC_IP"
    probe "Mac LAN address $MAC_IP: :7000"        blocked tcp "$MAC_IP" 7000
  fi
  if [ -n "$ROUTER" ]; then
    probe "Home router $ROUTER: ping/53/80/443"   blocked bash -c "ping -c1 -W3 $ROUTER || nc -z -w3 $ROUTER 53 || nc -z -w3 $ROUTER 80 || nc -z -w3 $ROUTER 443"
  fi
  probe "Tailscale MagicDNS 100.100.100.100:53"   blocked tcp 100.100.100.100 53   # meaningful if Tailscale runs on the Mac
}

HUID=$(id -u hermes)
as_hermes() { runuser -u hermes -- env XDG_RUNTIME_DIR="/run/user/$HUID" DOCKER_HOST="unix:///run/user/$HUID/docker.sock" "$@"; }

echo; echo "  Pass 1 - Hermes firewall ON (normal operation)"
network_tests
docker_rootless() { as_hermes docker info 2>/dev/null | grep -qi rootless; }
probe "IPv6 egress"                               blocked curl -6 -sf -m 5 https://ipv6.google.com
probe "hermes user has no sudo"                   blocked as_hermes sudo -n true
probe "Docker is rootless (user hermes)"          open    docker_rootless
probe "No rootful Docker socket"                  blocked test -S /var/run/docker.sock

echo; echo "  Pass 2 - Hermes firewall OFF (only the router VM remains)"
trap 'nft -f /etc/nftables.conf' EXIT
nft flush ruleset
network_tests
nft -f /etc/nftables.conf && trap - EXIT
echo "    (Hermes firewall restored)"

echo; printf '  %d passed, %d failed\n\n' "$pass" "$fail"
exit "$fail"
