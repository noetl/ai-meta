#!/usr/bin/env python3
"""Speak the EHDB tier-service wire protocol (noetl/ai-meta#257 PR 1/3).

The tier service is length-framed binary TCP, not HTTP, so the gate cannot drive
it with curl:

    u32 big-endian length || <length> bytes of payload

This exists so the gate drives the REAL serve path — the accept loop, the frame
codec, the decode, the store, the encode — rather than calling a recorder
directly.  A gate that called the metric recorder would pass against the
un-instrumented module #260 was filed about, which is the whole point of the
exercise.

Usage:
  tierctl.py <host:port> health
  tierctl.py <host:port> append <execution_id> <json-payload>
  tierctl.py <host:port> read   <execution_id>
  tierctl.py <host:port> scan   [limit]
  tierctl.py <host:port> raw    <text>        # arbitrary op name -> unsupported
  tierctl.py <host:port> badframe             # over-long length prefix, no body
"""
import json
import socket
import struct
import sys

# Must match MAX_FRAME_BYTES in src/ehdb/tier_service.rs.
MAX_FRAME_BYTES = 1024 * 1024


def _recvn(sock, n):
    """Read exactly n bytes, or return None if the peer closed first."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def call(addr, payload, expect_reply=True, timeout=15):
    host, port = addr.rsplit(":", 1)
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    try:
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        if not expect_reply:
            return None
        header = _recvn(sock, 4)
        if header is None:
            return None
        (length,) = struct.unpack(">I", header)
        return _recvn(sock, length)
    finally:
        sock.close()


def badframe(addr, timeout=15):
    """Claim a frame larger than the cap and send no body.

    The server must close the connection rather than allocate for it. Returns
    True when it closed, which is the correct behaviour.
    """
    host, port = addr.rsplit(":", 1)
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    try:
        sock.sendall(struct.pack(">I", MAX_FRAME_BYTES + 1))
        return sock.recv(1) == b""
    except OSError:
        # A reset is also a close, and also correct.
        return True
    finally:
        sock.close()


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    addr, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]

    if cmd == "health":
        payload = b"health"
    elif cmd == "append":
        payload = json.dumps(
            {"op": "append", "execution_id": rest[0], "payload": rest[1]}
        ).encode()
    elif cmd == "read":
        payload = json.dumps({"op": "read_execution", "execution_id": rest[0]}).encode()
    elif cmd == "scan":
        limit = int(rest[0]) if rest else 100
        payload = json.dumps({"op": "scan", "limit": limit}).encode()
    elif cmd == "raw":
        payload = rest[0].encode()
    elif cmd == "badframe":
        print("closed" if badframe(addr) else "STILL-OPEN")
        return 0
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2

    reply = call(addr, payload)
    if reply is None:
        print("NO-REPLY", file=sys.stderr)
        return 1
    sys.stdout.write(reply.decode("utf-8", "replace"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
