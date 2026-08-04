#!/bin/sh
# status.sh — field verification ladder for the Starlink kit (non-interactive).
# Checks WAN, ZeroTier (if present), and the Starlink->MAVLink position bridge.
# Networking is configured automatically at first boot; ZeroTier membership is
# managed from the controller side. The bridge is started manually with
# starlink-start after every boot.

echo "== WAN"
wd=$(uci -q get network.wan.device)
if [ -n "$wd" ]; then
    echo "  device: $wd"
    ad=$(uci -q get network.aux.device)
    for p in jack1 jack2; do
        role=""
        [ "$p" = "$wd" ] && role=" [wan]"
        [ "$p" = "$ad" ] && role=" [aux]"
        if [ "$(cat /sys/class/net/$p/carrier 2>/dev/null)" = "1" ]; then
            echo "  port $p: link UP ($(cat /sys/class/net/$p/speed 2>/dev/null) Mbps)$role"
        else
            echo "  port $p: no link$role"
        fi
    done
    ip -4 -o addr show "$wd" 2>/dev/null | awk '{print "  addr:  " $4}'
else
    echo "  not configured"
fi
rt=$(ip route 2>/dev/null | grep '^default')
[ -n "$rt" ] && echo "  route: $rt" || echo "  route: NONE (no default route)"
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    echo "  ping 1.1.1.1: OK"
else
    echo "  ping 1.1.1.1: FAIL  (dish booting? cable? obstruction?)"
fi
if ping -c1 -W2 192.168.100.1 >/dev/null 2>&1; then
    echo "  ping dish (192.168.100.1): OK"
else
    echo "  ping dish (192.168.100.1): FAIL (bridge can't poll position without this)"
fi

echo "== ZeroTier"
if command -v zerotier-cli >/dev/null 2>&1; then
    zerotier-cli info 2>/dev/null | sed 's/^/  /'
    zerotier-cli listnetworks 2>/dev/null | sed -n '2,$s/^/  /p'
    for l in $(ip -o link 2>/dev/null | awk -F': ' '/: zt/{print $2}'); do
        if ip link show "$l" 2>/dev/null | head -n1 | grep -q '[,<]UP[,>]'; then
            echo "  tap $l: UP"
        else
            ip link set "$l" up 2>/dev/null
            echo "  tap $l: was DOWN -> brought UP (silent ping-eater)"
        fi
    done
    zerotier-cli peers 2>/dev/null | awk 'NR>2 && $3=="LEAF"{printf "  peer %s: %s (%s ms)\n",$1,$5,$4}'
else
    echo "  not installed"
fi

echo "== Starlink-MAVLink bridge"
if [ -x /etc/init.d/starlink_mavlink ]; then
    if /etc/init.d/starlink_mavlink running 2>/dev/null; then
        echo "  service: running"
    else
        echo "  service: NOT running — start it: starlink-start <FC-IP>  (or 'starlink-start auto')"
    fi
    [ -f /root/starlinkpnt/logs/last_fc.txt ] && \
        echo "  last FC: $(cat /root/starlinkpnt/logs/last_fc.txt)"
    tail -n 3 /root/starlinkpnt/logs/starlink_mavlink.log 2>/dev/null | sed 's/^/  log: /'
else
    echo "  not installed (sh /root/starlinkpnt/setup.sh --preinstall)"
fi

y=$(date +%Y)
[ "$y" -lt 2024 ] 2>/dev/null && \
    echo "WARNING: clock is $(date) — no RTC; NTP needs WAN; certs may fail"
exit 0
