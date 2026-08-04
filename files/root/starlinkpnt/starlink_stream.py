#!/usr/bin/env python3
"""
Stream Starlink dish data via gRPC using server reflection.
No proto files needed - uses reflection to discover and call methods.
"""

import grpc
from grpc_reflection.v1alpha import reflection_pb2, reflection_pb2_grpc
from google.protobuf import descriptor_pb2
from google.protobuf.descriptor_pool import DescriptorPool
from google.protobuf.message_factory import GetMessageClass
from google.protobuf.json_format import MessageToDict
import json
import time
import argparse

STARLINK_ADDR = "192.168.100.1:9200"


def get_reflection_stub(channel):
    """Get the reflection service stub."""
    return reflection_pb2_grpc.ServerReflectionStub(channel)


def list_services(stub):
    """List all available services via reflection."""
    request = reflection_pb2.ServerReflectionRequest(list_services="")
    responses = stub.ServerReflectionInfo(iter([request]))
    
    services = []
    for response in responses:
        if response.HasField("list_services_response"):
            for service in response.list_services_response.service:
                services.append(service.name)
    return services


def build_descriptor_pool(stub, start_symbol="SpaceX.API.Device.Device", verbose=False):
    """Build a descriptor pool with all needed types from reflection."""
    pool = DescriptorPool()
    
    all_fds = {}  # name -> FileDescriptorProto
    to_fetch = set()
    fetched_symbols = set()
    fetched_files = set()
    
    # Start by fetching the main symbol
    to_fetch.add(("symbol", start_symbol))
    
    while to_fetch:
        fetch_type, fetch_val = to_fetch.pop()
        
        if fetch_type == "symbol":
            if fetch_val in fetched_symbols:
                continue
            fetched_symbols.add(fetch_val)
            req = reflection_pb2.ServerReflectionRequest(file_containing_symbol=fetch_val)
        else:  # file
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
                            # Queue dependencies
                            for dep in fd.dependency:
                                if dep not in fetched_files:
                                    to_fetch.add(("file", dep))
        except Exception as e:
            if verbose:
                print(f"Failed to fetch {fetch_type} {fetch_val}: {e}")
    
    # Topologically sort and add to pool
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
            except Exception as e:
                if verbose:
                    print(f"Could not add {name}: {e}")
    
    for name in all_fds:
        add_fd(name)
    
    return pool


def call_handle_method(channel, request_type, verbose=False):
    """
    Call the SpaceX.API.Device.Device/Handle method.
    Uses dynamic protobuf message construction via reflection.
    """
    stub = get_reflection_stub(channel)
    
    # Build descriptor pool from reflection
    pool = build_descriptor_pool(stub, verbose=verbose)
    
    # Get message classes
    try:
        request_desc = pool.FindMessageTypeByName("SpaceX.API.Device.Request")
        response_desc = pool.FindMessageTypeByName("SpaceX.API.Device.Response")
    except Exception as e:
        print(f"Could not find message types: {e}")
        return None
    
    RequestClass = GetMessageClass(request_desc)
    ResponseClass = GetMessageClass(response_desc)
    
    # Create request
    request_msg = RequestClass()
    
    # Set the appropriate field based on request_type
    if request_type == "get_status":
        request_msg.get_status.SetInParent()
    elif request_type == "get_history":
        request_msg.get_history.SetInParent()
    elif request_type == "get_device_info":
        request_msg.get_device_info.SetInParent()
    elif request_type == "get_location":
        request_msg.get_location.SetInParent()
    elif request_type == "dish_get_context":
        request_msg.dish_get_context.SetInParent()
    else:
        print(f"Unknown request type: {request_type}")
        return None
    
    # Make the call
    method = channel.unary_unary(
        "/SpaceX.API.Device.Device/Handle",
        request_serializer=RequestClass.SerializeToString,
        response_deserializer=ResponseClass.FromString,
    )
    
    response = method(request_msg)
    return MessageToDict(response, preserving_proto_field_name=True)


def print_status_summary(response):
    """Print a summary of the dish status."""
    if not response:
        print("No response data")
        return
    
    if "dish_get_status" in response:
        status = response["dish_get_status"]
        
        # Device info
        if "device_info" in status:
            info = status["device_info"]
            print(f"  Device ID: {info.get('id', 'N/A')}")
            print(f"  Hardware: {info.get('hardware_version', 'N/A')}")
            print(f"  Software: {info.get('software_version', 'N/A')}")
        
        # Device state
        if "device_state" in status:
            state = status["device_state"]
            uptime = state.get("uptime_s", 0)
            hours = uptime // 3600
            mins = (uptime % 3600) // 60
            secs = uptime % 60
            print(f"  Uptime: {hours}h {mins}m {secs}s")
        
        # Outage info
        if "outage" in status:
            outage = status["outage"]
            cause = outage.get("cause", "NONE")
            if cause and cause != "NO_SCHEDULE":
                print(f"  Outage: {cause}")
        
        # Alerts
        if "alerts" in status:
            alerts = status["alerts"]
            active_alerts = [k for k, v in alerts.items() if v]
            if active_alerts:
                print(f"  Alerts: {', '.join(active_alerts)}")
        
        # GPS
        if "gps_stats" in status:
            gps = status["gps_stats"]
            print(f"  GPS Valid: {gps.get('gps_valid', False)}, Sats: {gps.get('gps_sats', 0)}")
        
        # Signal quality
        if "pop_ping_drop_rate" in status:
            print(f"  Ping Drop Rate: {status['pop_ping_drop_rate']:.4f}")
        if "pop_ping_latency_ms" in status:
            print(f"  Ping Latency: {status['pop_ping_latency_ms']:.1f} ms")
        if "downlink_throughput_bps" in status:
            dl = status["downlink_throughput_bps"] / 1_000_000
            print(f"  Downlink: {dl:.2f} Mbps")
        if "uplink_throughput_bps" in status:
            ul = status["uplink_throughput_bps"] / 1_000_000
            print(f"  Uplink: {ul:.2f} Mbps")
        
        # Obstruction
        if "obstruction_stats" in status:
            obs = status["obstruction_stats"]
            obstructed = obs.get("currently_obstructed", False)
            frac = obs.get("fraction_obstructed", 0)
            print(f"  Obstructed: {obstructed} ({frac * 100:.1f}%)")
    else:
        # Just dump the raw response
        print(json.dumps(response, indent=2))


def stream_starlink_data(addr, interval=2.0, verbose=False):
    """Stream data from Starlink dish."""
    print(f"Connecting to Starlink at {addr}...")
    
    channel = grpc.insecure_channel(addr)
    
    # List services
    try:
        stub = get_reflection_stub(channel)
        services = list_services(stub)
        print(f"Services: {services}")
    except Exception as e:
        print(f"Could not list services: {e}")
    
    print(f"\nStreaming status (interval: {interval}s) - Ctrl+C to stop")
    print("=" * 60)
    
    iteration = 0
    while True:
        iteration += 1
        try:
            response = call_handle_method(channel, "get_status", verbose)
            
            if response:
                print(f"\n[{iteration}] {time.strftime('%H:%M:%S')}")
                print("-" * 40)
                print_status_summary(response)
            
            if interval <= 0:
                break
                
            time.sleep(interval)
            
        except KeyboardInterrupt:
            print("\n\nStopped.")
            break
        except grpc.RpcError as e:
            print(f"gRPC error: {e.code()} - {e.details()}")
            if interval <= 0:
                break
            time.sleep(interval)
        except Exception as e:
            print(f"Error: {e}")
            if verbose:
                import traceback
                traceback.print_exc()
            if interval <= 0:
                break
            time.sleep(interval)
    
    channel.close()


def main():
    parser = argparse.ArgumentParser(description="Stream Starlink dish data via gRPC")
    parser.add_argument("-a", "--addr", default=STARLINK_ADDR,
                        help=f"Starlink dish address (default: {STARLINK_ADDR})")
    parser.add_argument("-t", "--interval", type=float, default=2.0,
                        help="Polling interval in seconds (0 for single query)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Verbose output")
    parser.add_argument("--raw", action="store_true",
                        help="Print raw JSON response")
    parser.add_argument("-r", "--request", default="get_status",
                        help="Request type: get_status, get_location, get_history, get_device_info, dish_get_context")
    
    args = parser.parse_args()
    
    if args.raw:
        print(f"Connecting to {args.addr}...")
        channel = grpc.insecure_channel(args.addr)
        response = call_handle_method(channel, args.request, args.verbose)
        print(json.dumps(response, indent=2))
        channel.close()
    else:
        stream_starlink_data(args.addr, args.interval, args.verbose)


if __name__ == "__main__":
    main()
