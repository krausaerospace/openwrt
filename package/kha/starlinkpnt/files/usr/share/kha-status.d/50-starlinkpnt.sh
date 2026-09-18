# sourced by /root/status.sh (for f in /usr/share/kha-status.d/*.sh) in a
# subshell -- not executed, so no shebang and mode 644. POSIX/busybox sh only.
# Shipped by the starlinkpnt package; maintained in the buildroot repo at
# package/kha/starlinkpnt/files/usr/share/kha-status.d/50-starlinkpnt.sh

echo "== Starlink dish"
if ping -c1 -W2 192.168.100.1 >/dev/null 2>&1; then
    echo "  ping dish (192.168.100.1): OK"
else
    echo "  ping dish (192.168.100.1): FAIL (no WAN lease yet? bridge can't poll position without this)"
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
    echo "  not installed (reinstall the starlinkpnt package; Python deps: starlink-install-deps)"
fi
