#!/bin/sh
# status.sh — field verification ladder for the router (non-interactive).
# Checks WAN and ZeroTier (if present). Networking is configured
# automatically at first boot; ZeroTier membership is managed from the
# controller side.
# Installed packages can add sections via /usr/share/kha-status.d/*.sh.

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
    echo "  ping 1.1.1.1: FAIL  (upstream down? cable?)"
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

# Optional sections dropped in by packages (sourced in lexical order).
for f in /usr/share/kha-status.d/*.sh; do
    [ -f "$f" ] || continue
    echo
    ( . "$f" )
done

y=$(date +%Y)
[ "$y" -lt 2024 ] 2>/dev/null && \
    echo "WARNING: clock is $(date) — no RTC; NTP needs WAN; certs may fail"
exit 0
