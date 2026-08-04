#!/usr/bin/env python3
"""
Starlink MAVLink Position Estimator

Polls Starlink dish for location via gRPC, logs to file, and sends
MAV_CMD_EXTERNAL_POSITION_ESTIMATE (43003) over MAVLink.

Intended to run onboard a Raspberry Pi on an aircraft.
"""

import argparse
import ipaddress
import logging
import logging.handlers
import math
import os
import select
import signal
import socket
import subprocess
import sys
import time


def _lazy_imports_mavlink():
    """Import pymavlink only (enough for --discover-only)."""
    global mavutil
    from pymavlink import mavutil as _mv
    mavutil = _mv


def _lazy_imports():
    """Import heavy runtime deps (grpc, pymavlink). Deferred so --install works
    on machines that don't have them installed."""
    global grpc, reflection_pb2, reflection_pb2_grpc, descriptor_pb2
    global DescriptorPool, GetMessageClass, MessageToDict
    import grpc as _grpc
    from grpc_reflection.v1alpha import (
        reflection_pb2 as _rp,
        reflection_pb2_grpc as _rpg,
    )
    from google.protobuf import descriptor_pb2 as _dp
    from google.protobuf.descriptor_pool import DescriptorPool as _DP
    from google.protobuf.message_factory import GetMessageClass as _GMC
    from google.protobuf.json_format import MessageToDict as _MTD
    grpc = _grpc
    reflection_pb2 = _rp
    reflection_pb2_grpc = _rpg
    descriptor_pb2 = _dp
    DescriptorPool = _DP
    GetMessageClass = _GMC
    MessageToDict = _MTD
    _lazy_imports_mavlink()

STARLINK_ADDRS = ["192.168.100.1:9200", "100.64.0.1:9200"]
GRPC_TIMEOUT_MS = 5000
MAV_CMD_EXTERNAL_POSITION_ESTIMATE = 43003
MAVLINK_HB_TIMEOUT = 15.0  # seconds without FC heartbeat before reconnecting

log = logging.getLogger("starlink_mavlink")

shutdown_requested = False


def request_shutdown(signum, frame):
    global shutdown_requested
    log.info("Shutdown requested (signal %d)", signum)
    shutdown_requested = True


def setup_logging(log_dir, console=True):
    """Configure logging to rotating file and optionally console."""
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "starlink_mavlink.log")

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = logging.handlers.RotatingFileHandler(
        log_path, maxBytes=10 * 1024 * 1024, backupCount=5
    )
    file_handler.setFormatter(formatter)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(file_handler)

    if console:
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        root.addHandler(console_handler)

    log.info("Logging to %s", log_path)


# ---------------------------------------------------------------------------
# CSV data log (one line per position fix)
# ---------------------------------------------------------------------------

class DataLog:
    """Append-only CSV log of position fixes."""

    HEADER = "timestamp,lat,lon,alt,sigma_m,speed_mps,source\n"

    def __init__(self, log_dir):
        os.makedirs(log_dir, exist_ok=True)
        self.path = os.path.join(log_dir, "positions.csv")
        if not os.path.exists(self.path):
            with open(self.path, "w") as f:
                f.write(self.HEADER)
        self._file = open(self.path, "a")

    def write(self, ts, lat, lon, alt, sigma, speed, source):
        self._file.write(
            f"{ts:.3f},{lat:.7f},{lon:.7f},{alt},{sigma},{speed},{source}\n"
        )
        self._file.flush()

    def close(self):
        self._file.close()


# ---------------------------------------------------------------------------
# Starlink gRPC helpers (reflection-based, no proto files needed)
# ---------------------------------------------------------------------------

def get_reflection_stub(channel):
    return reflection_pb2_grpc.ServerReflectionStub(channel)


def build_descriptor_pool(stub):
    pool = DescriptorPool()
    all_fds = {}
    to_fetch = set([("symbol", "SpaceX.API.Device.Device")])
    fetched_symbols = set()
    fetched_files = set()

    while to_fetch:
        fetch_type, fetch_val = to_fetch.pop()
        if fetch_type == "symbol":
            if fetch_val in fetched_symbols:
                continue
            fetched_symbols.add(fetch_val)
            req = reflection_pb2.ServerReflectionRequest(
                file_containing_symbol=fetch_val
            )
        else:
            if fetch_val in fetched_files:
                continue
            fetched_files.add(fetch_val)
            req = reflection_pb2.ServerReflectionRequest(file_by_filename=fetch_val)

        try:
            resps = list(stub.ServerReflectionInfo(iter([req])))
            for resp in resps:
                if resp.HasField("file_descriptor_response"):
                    for fd_bytes in resp.file_descriptor_response.file_descriptor_proto:
                        fd = descriptor_pb2.FileDescriptorProto()
                        fd.ParseFromString(fd_bytes)
                        if fd.name not in all_fds:
                            all_fds[fd.name] = fd
                            for dep in fd.dependency:
                                if dep not in fetched_files:
                                    to_fetch.add(("file", dep))
        except Exception:
            pass

    added = set()

    def add_fd(name):
        if name in added or name not in all_fds:
            return
        fd = all_fds[name]
        for dep in fd.dependency:
            add_fd(dep)
        if name not in added:
            try:
                pool.Add(fd)
                added.add(name)
            except Exception:
                pass

    for name in all_fds:
        add_fd(name)
    return pool


class StarlinkConnection:
    """Manages the gRPC connection to the Starlink dish."""

    def __init__(self, addrs=None):
        self.addrs = addrs or STARLINK_ADDRS
        self.channel = None
        self.pool = None
        self.RequestClass = None
        self.ResponseClass = None
        self._method = None

    def connect(self):
        """Try each address until one works. Returns True on success."""
        for addr in self.addrs:
            log.info("Trying Starlink at %s ...", addr)
            try:
                channel = grpc.insecure_channel(
                    addr,
                    options=[
                        ("grpc.connect_timeout_ms", GRPC_TIMEOUT_MS),
                        ("grpc.keepalive_timeout_ms", GRPC_TIMEOUT_MS),
                    ],
                )
                stub = get_reflection_stub(channel)
                pool = build_descriptor_pool(stub)

                request_desc = pool.FindMessageTypeByName(
                    "SpaceX.API.Device.Request"
                )
                response_desc = pool.FindMessageTypeByName(
                    "SpaceX.API.Device.Response"
                )
                self.RequestClass = GetMessageClass(request_desc)
                self.ResponseClass = GetMessageClass(response_desc)
                self.channel = channel
                self.pool = pool
                self._method = channel.unary_unary(
                    "/SpaceX.API.Device.Device/Handle",
                    request_serializer=self.RequestClass.SerializeToString,
                    response_deserializer=self.ResponseClass.FromString,
                )
                log.info("Connected to Starlink at %s", addr)
                return True
            except Exception as e:
                log.warning("Failed to connect to %s: %s", addr, e)
        return False

    def inhibit_gps(self, inhibit=True):
        """Enable or disable GPS inhibit on the dish."""
        req = self.RequestClass()
        req.dish_inhibit_gps.inhibit_gps = inhibit
        self._method(req)
        log.info("GPS inhibit set to %s", inhibit)

    def close(self):
        if self.channel:
            try:
                self.inhibit_gps(False)
                log.info("GPS inhibit cleared on shutdown")
            except Exception:
                pass
            try:
                self.channel.close()
            except Exception:
                pass
            self.channel = None

    def get_location(self):
        """Returns (lat, lon, alt, sigma_m, speed_mps, source) or None."""
        req = self.RequestClass()
        req.get_location.SetInParent()
        resp = MessageToDict(
            self._method(req), preserving_proto_field_name=True
        )
        loc = resp.get("get_location")
        if not loc:
            return None
        lla = loc.get("lla", {})
        lat = lla.get("lat")
        lon = lla.get("lon")
        if lat is None or lon is None:
            return None
        return (
            lat,
            lon,
            lla.get("alt"),
            loc.get("sigma_m"),
            loc.get("horizontal_speed_mps"),
            loc.get("source"),
        )


# ---------------------------------------------------------------------------
# MAVLink helpers
# ---------------------------------------------------------------------------

def connect_mavlink(connection_string, source_system=254, source_component=1):
    """Connect to the flight controller. Returns a mavutil connection."""
    log.info("Connecting MAVLink on %s ...", connection_string)
    mav_conn = mavutil.mavlink_connection(
        connection_string,
        source_system=source_system,
        source_component=source_component,
    )
    # Send our heartbeat first so the FC knows we exist and responds
    mav_conn.mav.heartbeat_send(
        mavutil.mavlink.MAV_TYPE_ONBOARD_CONTROLLER,
        mavutil.mavlink.MAV_AUTOPILOT_INVALID,
        0, 0, 0,
    )
    log.info("Waiting for heartbeat ...")
    if mav_conn.wait_heartbeat(timeout=30) is None:
        mav_conn.close()
        raise TimeoutError("no MAVLink heartbeat within 30s")
    log.info(
        "MAVLink heartbeat from system %d component %d",
        mav_conn.target_system,
        mav_conn.target_component,
    )
    return mav_conn


def send_position_estimate(mav_conn, lat, lon, sigma_m, t0):
    """Send MAV_CMD_EXTERNAL_POSITION_ESTIMATE (43003) via COMMAND_INT.

    Must use COMMAND_INT (not COMMAND_LONG) because ArduPilot's
    mav_frame_for_command_long() has no entry for this command,
    so COMMAND_LONG returns MAV_RESULT_UNSUPPORTED.

    param1: transmission_time - wrapping timestamp in sender's domain (s)
    param2: processing_time  - 0 (we don't track gRPC round-trip separately)
    param3: accuracy         - 1-sigma metres, or NaN
    param4: empty
    x:      latitude (degE7)
    y:      longitude (degE7)
    z:      altitude  - NaN (not yet supported by the command)
    """
    # Wrap transmission time at 10000s (~2.7 hours) for ~1ms precision in f32
    transmission_time = (time.monotonic() - t0) % 10000.0
    accuracy = sigma_m if sigma_m is not None else float("nan")

    mav_conn.mav.command_int_send(
        mav_conn.target_system,
        mav_conn.target_component,
        mavutil.mavlink.MAV_FRAME_GLOBAL,  # frame
        MAV_CMD_EXTERNAL_POSITION_ESTIMATE,
        0,                              # current
        0,                              # autocontinue
        transmission_time,              # param1
        0,                              # param2  processing_time
        accuracy,                       # param3
        0,                              # param4  empty
        int(lat * 1e7),                 # x  latitude degE7
        int(lon * 1e7),                 # y  longitude degE7
        float("nan"),                   # z  altitude (unused)
    )


def send_gps_input(mav_conn, lat, lon, alt, sigma_m, sats):
    """Feed the Starlink fix to the FC as a MAVLink GPS via GPS_INPUT.

    FC side: GPS_TYPE2=14 (MAV) makes this appear as the second GPS instance,
    fused by the EKF like any other GPS. Velocity/hdop/vdop are flagged
    ignored (Starlink gives no course, so we can't form a velocity vector);
    satellites_visible is synthetic — Starlink isn't GNSS — sized to pass
    EK3_GPS_CHECK's sat-count gate.
    """
    ml = mavutil.mavlink
    ignore = (
        ml.GPS_INPUT_IGNORE_FLAG_HDOP
        | ml.GPS_INPUT_IGNORE_FLAG_VDOP
        | ml.GPS_INPUT_IGNORE_FLAG_VEL_HORIZ
        | ml.GPS_INPUT_IGNORE_FLAG_VEL_VERT
        | ml.GPS_INPUT_IGNORE_FLAG_SPEED_ACCURACY
        | ml.GPS_INPUT_IGNORE_FLAG_VERTICAL_ACCURACY
    )
    if alt is None:
        alt = 0.0
        ignore |= ml.GPS_INPUT_IGNORE_FLAG_ALT
    accuracy = sigma_m if sigma_m is not None else 10.0
    mav_conn.mav.gps_input_send(
        int(time.time() * 1e6),     # time_usec
        0,                          # gps_id
        ignore,
        0, 0,                       # time_week_ms, time_week (unknown)
        3,                          # fix_type: 3D fix
        int(lat * 1e7),
        int(lon * 1e7),
        float(alt),
        1.0, 1.0,                   # hdop, vdop (ignored)
        0.0, 0.0, 0.0,              # vn, ve, vd (ignored)
        0.0,                        # speed_accuracy (ignored)
        float(accuracy),            # horiz_accuracy = Starlink sigma
        0.0,                        # vert_accuracy (ignored)
        int(sats),
        0,                          # yaw: 0 = not available
    )


def drain_mavlink(mav_conn, ack_state):
    """Read all pending inbound messages. Returns the wall time of the newest
    HEARTBEAT seen (or None), and logs changes in how the FC is responding to
    our position estimates (COMMAND_ACK). ack_state is a dict carried between
    calls so transitions are logged once, not at every fix."""
    last_hb = None
    while True:
        msg = mav_conn.recv_match(blocking=False)
        if msg is None:
            return last_hb
        mtype = msg.get_type()
        if mtype == "HEARTBEAT":
            last_hb = time.time()
        elif mtype == "COMMAND_ACK" and msg.command == MAV_CMD_EXTERNAL_POSITION_ESTIMATE:
            if msg.result != ack_state.get("result"):
                ack_state["result"] = msg.result
                try:
                    result_name = mavutil.mavlink.enums["MAV_RESULT"][msg.result].name
                except KeyError:
                    result_name = str(msg.result)
                if msg.result == mavutil.mavlink.MAV_RESULT_ACCEPTED:
                    log.info("FC is accepting external position estimates")
                else:
                    log.warning(
                        "FC rejecting position estimates: %s "
                        "(EKF still fusing GPS, no EKF origin, or not aiding yet)",
                        result_name,
                    )


# ---------------------------------------------------------------------------
# Flight controller auto-discovery (--mavlink auto)
# ---------------------------------------------------------------------------

DISCOVER_CHUNK = 64          # probes per burst
DISCOVER_CHUNK_WAIT = 0.125  # listen window between bursts; ~512 probes/s keeps
                             # outstanding conntrack entries low on OpenWrt


def _heartbeat_probe():
    """One packed HEARTBEAT — the same first-contact packet ArduPilot's UDP
    server expects from a client before it starts talking back."""
    mav = mavutil.mavlink.MAVLink(None, srcSystem=254, srcComponent=1)
    return mav.heartbeat_encode(
        mavutil.mavlink.MAV_TYPE_ONBOARD_CONTROLLER,
        mavutil.mavlink.MAV_AUTOPILOT_INVALID,
        0, 0, 0,
    ).pack(mav)


def _heartbeat_fields(data):
    """Return (mav_type, autopilot) if data is a MAVLink v1/v2 HEARTBEAT frame,
    else None. Parsed by hand so both wire versions are recognised regardless
    of which protocol version pymavlink was loaded with."""
    try:
        if data[0] == 0xFE and data[5] == 0:
            # v1: 6-byte header; payload = custom_mode u32, type u8, autopilot u8, ...
            return data[10], data[11]
        if data[0] == 0xFD and (data[7] | (data[8] << 8) | (data[9] << 16)) == 0:
            payload = data[10:]  # v2: 10-byte header, payload may be zero-truncated
            return (
                payload[4] if len(payload) > 4 else 0,
                payload[5] if len(payload) > 5 else 0,
            )
    except IndexError:
        pass
    return None


def _local_networks():
    """IPv4 addresses and networks of all up interfaces (loopback excluded).
    Returns (own_addresses, networks)."""
    own, nets = set(), []
    try:
        out = subprocess.run(
            ["ip", "-o", "-4", "addr", "show"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        for line in out.splitlines():
            parts = line.split()
            try:
                cidr = parts[parts.index("inet") + 1]
            except (ValueError, IndexError):
                continue
            iface = ipaddress.ip_interface(cidr)
            if iface.network.is_loopback:
                continue
            own.add(str(iface.ip))
            nets.append(iface.network)
    except Exception as e:
        log.warning("Could not enumerate local networks: %s", e)
    return own, nets


def discover_fc(cidrs=None, port=14550, state_path=None, max_hosts=65534):
    """Find a MAVLink flight controller on the local network.

    Probes with real MAVLink heartbeats and listens for a heartbeat reply from
    anything identifying as an autopilot, in order of expected speed:
      1. the last address that worked (cached in state_path)
      2. subnet broadcast (finds FCs on the same L2 segment in seconds)
      3. a paced unicast sweep of every host address (finds FCs across
         routed/VPN hops where broadcast doesn't reach)
    Also listens passively on the probe port for FCs that broadcast heartbeats
    on their own. Returns 'udpout:<ip>:<port>' or None after one full round.
    """
    probe = _heartbeat_probe()
    own, auto_nets = _local_networks()
    if cidrs:
        nets = [ipaddress.ip_network(c, strict=False) for c in cidrs]
    else:
        nets = auto_nets
    if not nets:
        log.warning("No networks to scan for a flight controller")
        return None

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", 0))
    sock.setblocking(False)
    socks = [sock]
    try:
        # catches FCs that broadcast to the port on their own (UDP client mode)
        psock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        psock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        psock.bind(("0.0.0.0", port))
        psock.setblocking(False)
        socks.append(psock)
    except OSError:
        psock = None

    def listen(seconds):
        deadline = time.monotonic() + seconds
        while not shutdown_requested:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            readable, _, _ = select.select(socks, [], [], min(remaining, 0.2))
            for sk in readable:
                while True:
                    try:
                        data, addr = sk.recvfrom(2048)
                    except OSError:
                        break
                    if addr[0] in own:
                        continue  # our own broadcast probe echoed back
                    hb = _heartbeat_fields(data)
                    if (hb
                            and hb[1] != mavutil.mavlink.MAV_AUTOPILOT_INVALID
                            and hb[0] != mavutil.mavlink.MAV_TYPE_GCS):
                        return addr
        return None

    def send(ip):
        try:
            sock.sendto(probe, (str(ip), port))
        except OSError:
            pass

    found = None
    try:
        # 1. Last known address
        if state_path and os.path.exists(state_path):
            with open(state_path) as f:
                last = f.read().strip()
            if last:
                log.info("Probing last known FC at %s:%d ...", last, port)
                send(last)
                found = listen(2.0)

        # 2. Broadcast
        if found is None and not shutdown_requested:
            for net in nets:
                if net.prefixlen <= 30:
                    send(net.broadcast_address)
            send("255.255.255.255")
            log.info("Probing broadcast on %s ...", ", ".join(str(n) for n in nets))
            found = listen(3.0)

        # 3. Paced unicast sweep
        if found is None and not shutdown_requested:
            hosts = []
            for net in nets:
                for ip in net.hosts():
                    if str(ip) not in own:
                        hosts.append(ip)
                    if len(hosts) >= max_hosts:
                        break
                if len(hosts) >= max_hosts:
                    log.warning(
                        "Sweep capped at %d hosts — use --discover-cidr to narrow the range",
                        max_hosts,
                    )
                    break
            est = len(hosts) * DISCOVER_CHUNK_WAIT / DISCOVER_CHUNK
            log.info("Sweeping %d addresses on UDP %d (~%.0fs) ...", len(hosts), port, est)
            for i in range(0, len(hosts), DISCOVER_CHUNK):
                if shutdown_requested:
                    break
                for ip in hosts[i:i + DISCOVER_CHUNK]:
                    send(ip)
                found = listen(DISCOVER_CHUNK_WAIT)
                if found:
                    break
            if found is None and not shutdown_requested:
                found = listen(5.0)  # tail wait for stragglers
    finally:
        sock.close()
        if psock:
            psock.close()

    if found is None:
        return None

    conn = f"udpout:{found[0]}:{found[1]}"
    log.info("Found flight controller at %s", conn)
    if state_path:
        try:
            os.makedirs(os.path.dirname(state_path), exist_ok=True)
            with open(state_path, "w") as f:
                f.write(found[0])
        except OSError:
            pass
    return conn


# ---------------------------------------------------------------------------
# Self-install onto a remote aircraft companion computer
# ---------------------------------------------------------------------------

INITD_TEMPLATE = """\
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {{
    procd_open_instance
    procd_set_param command {cmd}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance
}}
"""


def _shq(s):
    """Minimal single-quote shell quoting."""
    return "'" + str(s).replace("'", "'\\''") + "'"


def install(args):
    """Copy this script to a remote host, install deps, and register as a service.

    Idempotent — safe to re-run to push script/config updates.
    Assumes OpenWrt with apk, procd, and passwordless SSH to the target.
    """
    import subprocess

    target = args.install
    remote_dir = args.remote_dir
    script_src = os.path.abspath(__file__)
    script_dst = f"{remote_dir}/starlink_mavlink.py"
    remote_log_dir = f"{remote_dir}/logs"
    initd_path = "/etc/init.d/starlink_mavlink"

    def ssh(cmd, stdin=None, check=True):
        logging.info("$ ssh %s %s", target, cmd)
        r = subprocess.run(
            ["ssh", target, cmd],
            input=stdin, text=True, capture_output=True,
        )
        if r.stdout.strip():
            logging.info(r.stdout.strip())
        if r.returncode != 0:
            logging.error(r.stderr.strip())
            if check:
                raise RuntimeError(f"remote command failed (rc={r.returncode}): {cmd}")
        return r

    def scp(src, dst):
        logging.info("$ scp -O %s %s:%s", src, target, dst)
        subprocess.run(["scp", "-O", src, f"{target}:{dst}"], check=True)

    # --- Preflight ---
    ssh("echo connected && uname -a")

    # --- Python + pip ---
    ssh(
        "command -v python3 >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1 "
        "|| (apk update && apk add python3 python3-pip)"
    )

    # --- Project directory ---
    ssh(f"mkdir -p {_shq(remote_dir)} {_shq(remote_log_dir)}")

    # --- Copy script ---
    scp(script_src, script_dst)
    ssh(f"chmod +x {_shq(script_dst)}")

    # --- Python deps (idempotent) ---
    ssh(
        "pip3 install --break-system-packages --quiet "
        "grpcio grpcio-reflection protobuf pymavlink"
    )

    # --- Build the procd service command line ---
    cmd_parts = [
        "python3", script_dst,
        "--mavlink", args.mavlink,
        "--baud", str(args.baud),
        "--interval", str(args.interval),
        "--log-dir", remote_log_dir,
        "--no-console",
    ]
    for a in args.starlink_addr or []:
        cmd_parts += ["--starlink-addr", a]
    cmd_str = " ".join(_shq(p) if " " in str(p) else str(p) for p in cmd_parts)

    initd = INITD_TEMPLATE.format(cmd=cmd_str)

    # --- Write init.d script ---
    ssh(
        f"cat > {_shq(initd_path)} && chmod +x {_shq(initd_path)}",
        stdin=initd,
    )

    # --- Enable + (re)start ---
    ssh(f"{_shq(initd_path)} enable")
    ssh(f"{_shq(initd_path)} restart")

    # --- Verify ---
    time.sleep(5)
    logging.info("--- service status ---")
    ssh(f"{_shq(initd_path)} status", check=False)
    logging.info("--- last log lines ---")
    ssh(f"tail -20 {_shq(remote_log_dir)}/starlink_mavlink.log", check=False)
    logging.info("Install complete. Service enabled at %s", initd_path)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Starlink → MAVLink external position estimator"
    )
    parser.add_argument(
        "--mavlink",
        default="/dev/serial0",
        help="MAVLink connection string (default: /dev/serial0). "
        "Examples: /dev/ttyAMA0, udp:127.0.0.1:14550, tcp:127.0.0.1:5760, "
        "or 'auto' to discover the flight controller on the local network",
    )
    parser.add_argument(
        "--discover-cidr",
        action="append",
        help="Network(s) to scan in auto mode, e.g. 10.221.0.0/16 "
        "(default: all connected subnets). May be repeated.",
    )
    parser.add_argument(
        "--discover-port",
        type=int,
        default=14550,
        help="UDP port to probe for MAVLink in auto mode (default: 14550)",
    )
    parser.add_argument(
        "--discover-max-hosts",
        type=int,
        default=65534,
        help="Cap on addresses swept per discovery round (default: 65534)",
    )
    parser.add_argument(
        "--discover-only",
        action="store_true",
        help="Run one discovery round, print the result, and exit",
    )
    parser.add_argument(
        "--gps-input",
        action="store_true",
        help="Send GPS_INPUT (appear as a MAVLink GPS instance; FC needs "
        "GPS_TYPE2=14) instead of MAV_CMD_EXTERNAL_POSITION_ESTIMATE. "
        "The latest fix is repeated at 5 Hz so the GPS instance stays "
        "healthy between Starlink polls.",
    )
    parser.add_argument(
        "--gps-input-sats",
        type=int,
        default=10,
        help="satellites_visible to report in GPS_INPUT mode (default: 10; "
        "synthetic — sized to pass the EKF's GPS quality gates)",
    )
    parser.add_argument(
        "--baud", type=int, default=57600, help="Serial baud rate (default: 57600)"
    )
    parser.add_argument(
        "--starlink-addr",
        action="append",
        help="Starlink dish address(es) to try (default: 192.168.100.1:9200, 100.64.0.1:9200)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="Polling interval in seconds (default: 2.0)",
    )
    parser.add_argument(
        "--log-dir",
        default="/var/log/starlink_mavlink",
        help="Directory for log files (default: /var/log/starlink_mavlink)",
    )
    parser.add_argument(
        "--no-console", action="store_true", help="Suppress console output"
    )
    parser.add_argument(
        "--install",
        metavar="HOST",
        help="Install as a boot service on remote host (e.g. root@10.221.0.1) "
        "instead of running locally. Passes through --mavlink/--baud/--interval/"
        "--starlink-addr into the installed service.",
    )
    parser.add_argument(
        "--remote-dir",
        default="/root/starlinkpnt",
        help="Install directory on remote host (default: /root/starlinkpnt)",
    )
    args = parser.parse_args()

    if args.install:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)-7s %(message)s",
            datefmt="%H:%M:%S",
        )
        install(args)
        return

    if args.discover_only:
        _lazy_imports_mavlink()  # discovery needs pymavlink but not grpc
    else:
        _lazy_imports()
    setup_logging(args.log_dir, console=not args.no_console)

    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)

    auto_discover = args.mavlink.strip().lower() == "auto"
    fc_state_path = os.path.join(args.log_dir, "last_fc.txt")

    if args.discover_only:
        result = discover_fc(
            args.discover_cidr, args.discover_port, fc_state_path,
            args.discover_max_hosts,
        )
        print(result or "not found")
        sys.exit(0 if result else 1)

    starlink_addrs = args.starlink_addr or STARLINK_ADDRS
    data_log = DataLog(args.log_dir)

    # Build MAVLink connection string with baud for serial devices
    mav_conn_str = args.mavlink
    if mav_conn_str.startswith("/dev/"):
        mav_conn_str = f"{mav_conn_str},{args.baud}"

    # Monotonic time reference for transmission_time param
    t0 = time.monotonic()

    starlink = StarlinkConnection(starlink_addrs)
    mav_conn = None

    try:
        while not shutdown_requested:
            # --- Ensure Starlink connection ---
            if starlink.channel is None:
                if not starlink.connect():
                    log.error("Cannot reach Starlink. Retrying in 5s ...")
                    time.sleep(5)
                    continue
                try:
                    starlink.inhibit_gps(True)
                except Exception as e:
                    log.warning("Failed to inhibit GPS: %s", e)

            # --- Ensure MAVLink connection ---
            if mav_conn is None:
                target = mav_conn_str
                if auto_discover:
                    target = discover_fc(
                        args.discover_cidr, args.discover_port, fc_state_path,
                        args.discover_max_hosts,
                    )
                    if target is None:
                        log.info("No flight controller found; rescanning in 5s ...")
                        time.sleep(5)
                        continue
                try:
                    mav_conn = connect_mavlink(target)
                except Exception as e:
                    log.error("MAVLink connection failed: %s. Retrying in 5s ...", e)
                    time.sleep(5)
                    continue
                last_heartbeat = time.time()
                ack_state = {}

            # --- Keep-alive + inbound (heartbeats, command ACKs) ---
            try:
                mav_conn.mav.heartbeat_send(
                    mavutil.mavlink.MAV_TYPE_ONBOARD_CONTROLLER,
                    mavutil.mavlink.MAV_AUTOPILOT_INVALID,
                    0, 0, 0,
                )
                hb = drain_mavlink(mav_conn, ack_state)
                if hb is not None:
                    last_heartbeat = hb
            except Exception as e:
                log.error("MAVLink receive failed: %s", e)
                mav_conn = None
                continue

            if time.time() - last_heartbeat > MAVLINK_HB_TIMEOUT:
                log.warning(
                    "No heartbeat from FC for %.0fs — reconnecting%s",
                    MAVLINK_HB_TIMEOUT,
                    " (will rediscover)" if auto_discover else "",
                )
                try:
                    mav_conn.close()
                except Exception:
                    pass
                mav_conn = None
                continue

            # --- Poll location ---
            try:
                fix = starlink.get_location()
            except grpc.RpcError as e:
                detail = e.details() if hasattr(e, "details") else str(e)
                code = e.code() if hasattr(e, "code") else None
                if code == grpc.StatusCode.UNAVAILABLE:
                    # Connection lost — tear down and reconnect
                    log.warning("Starlink connection lost: %s", detail)
                    starlink.close()
                else:
                    # Application error (e.g. location not enabled) — stay connected, retry
                    log.warning("Starlink gRPC error: %s", detail)
                time.sleep(args.interval)
                continue
            except Exception as e:
                log.warning("Starlink error: %s", e)
                starlink.close()
                time.sleep(args.interval)
                continue

            if fix is None:
                log.debug("No location fix from Starlink")
                time.sleep(args.interval)
                continue

            lat, lon, alt, sigma_m, speed_mps, source = fix
            now = time.time()

            log.info(
                "Fix: %.7f, %.7f  alt=%s  sigma=%.1fm  speed=%s  src=%s",
                lat,
                lon,
                f"{alt:.1f}" if alt is not None else "N/A",
                sigma_m if sigma_m is not None else float("nan"),
                f"{speed_mps:.1f}" if speed_mps is not None else "N/A",
                source or "N/A",
            )

            # --- Log to CSV ---
            data_log.write(
                now,
                lat,
                lon,
                alt if alt is not None else "",
                sigma_m if sigma_m is not None else "",
                speed_mps if speed_mps is not None else "",
                source or "",
            )

            # --- Send to flight controller ---
            try:
                if args.gps_input:
                    # Repeat the latest fix at 5 Hz until the next Starlink
                    # poll so AP_GPS doesn't declare the instance lost.
                    deadline = time.monotonic() + args.interval
                    while not shutdown_requested and time.monotonic() < deadline:
                        send_gps_input(
                            mav_conn, lat, lon, alt, sigma_m, args.gps_input_sats
                        )
                        time.sleep(0.2)
                    log.debug("Sent GPS_INPUT (repeated at 5 Hz)")
                else:
                    send_position_estimate(mav_conn, lat, lon, sigma_m, t0)
                    log.debug("Sent MAV_CMD_EXTERNAL_POSITION_ESTIMATE")
                    time.sleep(args.interval)
            except Exception as e:
                log.error("MAVLink send failed: %s", e)
                mav_conn = None
                time.sleep(args.interval)

    finally:
        log.info("Shutting down")
        starlink.close()
        if mav_conn:
            mav_conn.close()
        data_log.close()


if __name__ == "__main__":
    main()
