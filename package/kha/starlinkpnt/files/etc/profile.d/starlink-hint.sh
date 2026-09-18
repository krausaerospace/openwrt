# Remind the operator to start the Starlink->MAVLink bridge (it does not
# autostart unless enabled on the LuCI Starlink PNT page). Sourced by
# /etc/profile on interactive logins.
if ! /etc/init.d/starlink_mavlink running 2>/dev/null; then
	echo "Starlink->MAVLink bridge is NOT running."
	echo "  start it: starlink-start <FC-IP>    (or 'starlink-start auto' to scan for the FC)"
	echo "  or from LuCI: Services > Starlink PNT"
fi
