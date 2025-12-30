#!/usr/bin/env python3
"""
Banjo permission hook for Claude Code.

This script is invoked by Claude Code's PermissionRequest hook system.
It forwards permission requests to Banjo via Unix socket, which then
forwards them to Zed via ACP for user approval.

Environment:
  BANJO_PERMISSION_SOCKET - Path to Banjo's Unix socket

Input (stdin): JSON with tool_name, tool_input, tool_use_id, session_id
Output (stdout): JSON with hookSpecificOutput decision
"""

import json
import os
import socket
import sys


def main():
    socket_path = os.environ.get("BANJO_PERMISSION_SOCKET")
    if not socket_path:
        # No socket configured - defer to default behavior (ask user)
        sys.exit(0)

    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
        sys.exit(1)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})
    tool_use_id = input_data.get("tool_use_id", "")
    session_id = input_data.get("session_id", "")

    # Build request for Banjo
    request = {
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": tool_use_id,
        "session_id": session_id,
    }

    try:
        # Connect to Banjo socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(60)  # 60 second timeout for user decision
        sock.connect(socket_path)

        # Send request
        request_bytes = json.dumps(request).encode("utf-8") + b"\n"
        sock.sendall(request_bytes)

        # Read response (single line JSON)
        response_bytes = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_bytes += chunk
            if b"\n" in response_bytes:
                break

        sock.close()

        if not response_bytes:
            print("Error: Empty response from Banjo", file=sys.stderr)
            sys.exit(0)  # Defer to default

        response = json.loads(response_bytes.decode("utf-8").strip())
        decision = response.get("decision", "ask")
        message = response.get("message", "")

        # Build Claude Code hook output
        if decision == "allow":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
        elif decision == "deny":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": message or "Permission denied by user",
                    },
                }
            }
        else:
            # "ask" or unknown - defer to default
            sys.exit(0)

        print(json.dumps(output))
        sys.exit(0)

    except socket.timeout:
        print("Error: Timeout waiting for permission decision", file=sys.stderr)
        sys.exit(0)  # Defer to default
    except socket.error as e:
        print(f"Error: Socket error: {e}", file=sys.stderr)
        sys.exit(0)  # Defer to default
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON response: {e}", file=sys.stderr)
        sys.exit(0)  # Defer to default


if __name__ == "__main__":
    main()
