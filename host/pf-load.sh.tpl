#!/bin/sh
# hermes-vm pf loader - run by launchd as root at boot and every 30 seconds.
# Binds the anchor's interface-specific rules to whichever interface carries the VM gateway address
# (Fusion creates it when a VM starts), and reloads the anchor if anything flushed it.
GW="{{UPLINK_GW}}"
ANCHOR="com.apple/hermes-vm"
FILE="/etc/pf.anchors/hermes-vm"
STATE="/var/run/hermes-vm-pf.iface"

IF=none
for i in $(/sbin/ifconfig -l); do
  if /sbin/ifconfig "$i" 2>/dev/null | grep -q "inet $GW "; then IF=$i; break; fi
done

# Fusion normally has pf enabled already; take our own reference only if it isn't.
/sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || /sbin/pfctl -E >/dev/null 2>&1

LAST=$(cat "$STATE" 2>/dev/null || true)
if [ "$IF" != "$LAST" ] || ! /sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
  if [ "$IF" = none ]; then
    # VM not running: load everything except the interface-bound rules.
    grep -v 'vm_if' "$FILE" | /sbin/pfctl -a "$ANCHOR" -f - 2>&1 | grep -v -e 'ALTQ' -e '^$' -e 'Use of -f option' -e 'present in the main ruleset' -e 'See /etc/pf.conf' || true
  else
    /sbin/pfctl -a "$ANCHOR" -D "vm_if=$IF" -f "$FILE" 2>&1 | grep -v -e 'ALTQ' -e '^$' -e 'Use of -f option' -e 'present in the main ruleset' -e 'See /etc/pf.conf' || true
  fi
  echo "$IF" > "$STATE"
  /usr/bin/logger -t hermes-vm-pf "anchor loaded (vm_if=$IF)"
fi
