# sourced by /root/status.sh (for f in /usr/share/kha-status.d/*.sh) in a
# subshell -- not executed, so no shebang and mode 644. POSIX/busybox sh only.
# Shipped by the rtspforwarder package; maintained in the buildroot repo at
# package/kha/rtspforwarder/files/usr/share/kha-status.d/40-rtspforwarder.sh

echo "== RTSP forwarder"
url=$(uci -q get rtspforwarder.main.url)
if [ -z "$url" ]; then
    echo "  endpoint: not set (LuCI: Services > RTSP Forwarder)"
else
    echo "  endpoint: $url"
fi
if /etc/init.d/rtspforwarder running 2>/dev/null; then
    echo "  service: running"
else
    echo "  service: NOT running"
fi
logread 2>/dev/null | grep -E '(^|[^a-z])rtspforwarder(\[|:)' | tail -n 3 | sed 's/^/  log: /'
