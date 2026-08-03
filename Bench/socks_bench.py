#!/usr/bin/env python3
"""Stdlib SOCKS5 host oracle. Normal modes use an external proxy."""

import argparse
import hashlib
import json
import math
import socket
import statistics
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor

UPLOAD_BYTES = 17_000_003
DOWNLOAD_BYTES = 13_000_007
CHUNK_SIZE = 64 * 1024
_PATTERN_BASE = bytes((index * 31 + 17) & 0xFF for index in range(256))
_CHUNK = _PATTERN_BASE * (CHUNK_SIZE // len(_PATTERN_BASE))
SUSTAINED_MODES = ("upload", "download", "mixed")
# Exact mode half-closes the client's write side once the upload is done. Set
# False by --no-half-close to isolate whether that FIN is what lets the target
# connection finish closing before the proxy has drained its receive buffer.
HALF_CLOSE = True


def pattern(offset, length):
    start = offset % len(_PATTERN_BASE)
    repeats = (start + length + len(_PATTERN_BASE) - 1) // len(_PATTERN_BASE)
    return (_PATTERN_BASE * repeats)[start : start + length]


def recv_exact(sock, length):
    output = bytearray()
    while len(output) < length:
        chunk = sock.recv(min(CHUNK_SIZE, length - len(output)))
        if not chunk:
            raise ConnectionError("truncated payload")
        output.extend(chunk)
    return bytes(output)


def send_pattern(sock, length):
    digest = hashlib.sha256()
    total = 0
    while total < length:
        chunk = _CHUNK[: min(CHUNK_SIZE, length - total)]
        sock.sendall(chunk)
        digest.update(chunk)
        total += len(chunk)
    return total, digest.hexdigest()


def receive_pattern(sock, length):
    digest = hashlib.sha256()
    total = 0
    while total < length:
        chunk = sock.recv(min(CHUNK_SIZE, length - total))
        if not chunk:
            raise ConnectionError("peer closed before payload completed")
        if chunk != pattern(total, len(chunk)):
            raise ValueError("payload mismatch")
        digest.update(chunk)
        total += len(chunk)
    return total, digest.hexdigest()


def receive_evidence(sock, length):
    """Read `length` bytes, returning structured evidence instead of raising.

    A truncated session must not abort its siblings: an exception here tears down
    the whole run and RSTs connections that were still streaming, which looks
    exactly like the relay bug we are trying to measure.
    """
    digest = hashlib.sha256()
    total = 0
    failure = None
    while total < length:
        try:
            chunk = sock.recv(min(CHUNK_SIZE, length - total))
        except OSError as error:
            failure = type(error).__name__
            break
        if not chunk:
            failure = "truncated"
            break
        if chunk != pattern(total, len(chunk)):
            failure = "payload_mismatch"
            break
        digest.update(chunk)
        total += len(chunk)
    return {
        "requested_bytes": length,
        "observed_bytes": total,
        "complete": failure is None and total == length,
        "sha256": digest.hexdigest(),
        "failure_category": failure,
    }


def send_evidence(sock, length):
    digest = hashlib.sha256()
    total = 0
    failure = None
    while total < length:
        chunk = _CHUNK[: min(CHUNK_SIZE, length - total)]
        try:
            sock.sendall(chunk)
        except OSError as error:
            failure = type(error).__name__
            break
        digest.update(chunk)
        total += len(chunk)
    return {
        "requested_bytes": length,
        "observed_bytes": total,
        "complete": failure is None and total == length,
        "sha256": digest.hexdigest(),
        "failure_category": failure,
    }


def send_parts(sock, data, split_at=None, one_byte=False):
    if one_byte:
        for value in data:
            sock.sendall(bytes((value,)))
    elif split_at is not None:
        sock.sendall(data[:split_at])
        sock.sendall(data[split_at:])
    else:
        sock.sendall(data)


def socks_connect(
    proxy_host,
    proxy_port,
    target_host,
    target_port,
    *,
    greeting_split=None,
    request_split=None,
    one_byte=False,
    coalesced_payload=b"",
    coalesce_all=False,
):
    sock = socket.create_connection((proxy_host, proxy_port), timeout=20)
    sock.settimeout(20)
    greeting = b"\x05\x01\x00"
    request = b"\x05\x01\x00\x01" + socket.inet_aton(target_host) + target_port.to_bytes(2, "big")

    if coalesce_all:
        sock.sendall(greeting + request + coalesced_payload)
    else:
        send_parts(sock, greeting, greeting_split, one_byte)
    if recv_exact(sock, 2) != b"\x05\x00":
        sock.close()
        raise ValueError("NO AUTH rejected")

    if not coalesce_all:
        if coalesced_payload:
            send_parts(sock, request + coalesced_payload, request_split, one_byte)
        else:
            send_parts(sock, request, request_split, one_byte)
    reply = recv_exact(sock, 10)
    if reply[:4] != b"\x05\x00\x00\x01":
        sock.close()
        raise ValueError("CONNECT rejected")
    return sock


class TargetServer:
    def __init__(self, bind_host, mode, seconds, upload_bytes=UPLOAD_BYTES, download_bytes=DOWNLOAD_BYTES):
        self.mode = mode
        self.seconds = seconds
        self.upload_bytes = upload_bytes
        self.download_bytes = download_bytes
        self.results = []
        self.condition = threading.Condition()
        self.stop_event = threading.Event()
        self.begin_event = threading.Event()
        self.deadline = None
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind((bind_host, 0))
        self.listener.listen(64)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    @property
    def port(self):
        return self.listener.getsockname()[1]

    def begin(self):
        started = time.monotonic()
        self.deadline = started + self.seconds
        self.begin_event.set()
        return started, self.deadline

    def _accept_loop(self):
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self._run_connection, args=(connection,), daemon=True).start()

    def _run_connection(self, connection):
        try:
            result = self._handle(connection)
        except Exception as error:
            result = {
                "failure": f"{type(error).__name__}: {error}",
                "upload_bytes": 0,
                "download_bytes": 0,
            }
        finally:
            # How long close() lingered is the evidence that separates "the relay
            # dropped bytes" from "the linger deadline expired and the kernel RST".
            closing = time.monotonic()
            try:
                connection.close()
            except OSError:
                pass
            result["close_seconds"] = round(time.monotonic() - closing, 3)
        with self.condition:
            self.results.append(result)
            self.condition.notify_all()

    def _handle(self, connection):
        connection.settimeout(max(20, self.seconds + 20))
        if self.mode == "exact":
            # sendall() only means the bytes are buffered locally. Linger so close()
            # waits for delivery instead of discarding the send buffer. Must be set
            # before shutdown(); macOS rejects it afterwards with EINVAL.
            #
            # The timeout is generous on purpose: on expiry the kernel sends RST and
            # discards whatever is still in flight, which looks exactly like a proxy
            # truncating the stream. Four concurrent verified sessions can starve one
            # reader for seconds, so a short linger turns harness backpressure into a
            # fake relay defect. Stays inside the 180s client/result deadlines.
            connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 120)
            )
            upload = receive_evidence(connection, self.upload_bytes)
            if upload["complete"] and HALF_CLOSE and connection.recv(1):
                upload["complete"] = False
                upload["failure_category"] = "unexpected_extra_data"
            download = send_evidence(connection, self.download_bytes)
            try:
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            # Decides which side aborted. ECONNRESET here means the phone reset the
            # connection; 0 means this socket stayed healthy and whatever the relay
            # failed to deliver was lost above the peer's kernel, not on the wire.
            return {
                "so_error": connection.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR),
                "upload_bytes": upload["observed_bytes"],
                "download_bytes": download["observed_bytes"],
                "upload_sha256": upload["sha256"],
                "download_sha256": download["sha256"],
                "upload": upload,
                "download": download,
            }
        if self.mode in ("echo", "mixed"):
            uploaded = downloaded = 0
            while True:
                chunk = connection.recv(CHUNK_SIZE)
                if not chunk:
                    break
                if chunk != pattern(uploaded, len(chunk)):
                    raise ValueError("payload mismatch")
                uploaded += len(chunk)
                connection.sendall(chunk)
                downloaded += len(chunk)
            connection.shutdown(socket.SHUT_WR)
            return {"upload_bytes": uploaded, "download_bytes": downloaded}

        if not self.begin_event.wait(timeout=20) or self.deadline is None:
            raise TimeoutError("workload did not start")
        if self.mode == "upload":
            uploaded = 0
            while True:
                chunk = connection.recv(CHUNK_SIZE)
                if not chunk:
                    break
                if chunk != pattern(uploaded, len(chunk)):
                    raise ValueError("payload mismatch")
                uploaded += len(chunk)
            return {"upload_bytes": uploaded}
        if self.mode == "download":
            downloaded = 0
            while time.monotonic() < self.deadline:
                connection.sendall(_CHUNK)
                downloaded += len(_CHUNK)
            connection.shutdown(socket.SHUT_WR)
            return {"download_bytes": downloaded}
        raise ValueError("unknown target mode")

    def wait_results(self, count, timeout):
        deadline = time.monotonic() + timeout
        with self.condition:
            while len(self.results) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    if self.mode != "exact":
                        raise TimeoutError(f"target completed {len(self.results)} of {count} sessions")
                    break
                self.condition.wait(remaining)
            results = list(self.results[:count])
        if self.mode == "exact":
            # Report what every session actually did; never abort the siblings.
            empty = {"upload_bytes": 0, "download_bytes": 0, "failure_category": "missing"}
            return results + [dict(empty) for _ in range(count - len(results))]
        failures = [result["failure"] for result in results if "failure" in result]
        if failures:
            raise RuntimeError("target failure: " + failures[0])
        return results

    def close(self):
        self.stop_event.set()
        try:
            self.listener.close()
        except OSError:
            pass


def client_echo(proxy, target_host, target_port, payload_length=4096, **connect_options):
    payload = pattern(0, payload_length)
    coalesced = connect_options.get("coalesced_payload", b"")
    sock = socks_connect(*proxy, target_host, target_port, **connect_options)
    try:
        if not coalesced:
            sock.sendall(payload)
        received = recv_exact(sock, payload_length)
        if received != payload:
            raise ValueError("echo mismatch")
    finally:
        sock.close()


def run_exact(proxy, target_host, target):
    def one_session(ordinal):
        try:
            sock = socks_connect(*proxy, target_host, target.port)
        except OSError as error:
            empty = {"requested_bytes": 0, "observed_bytes": 0, "complete": False,
                     "sha256": None, "failure_category": type(error).__name__}
            return {"ordinal": ordinal, "upload_bytes": 0, "download_bytes": 0,
                    "upload": dict(empty), "download": dict(empty)}
        sock.settimeout(180)
        try:
            upload = send_evidence(sock, target.upload_bytes)
            if HALF_CLOSE:
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError as error:
                    upload["complete"] = False
                    upload["failure_category"] = type(error).__name__
            download = receive_evidence(sock, target.download_bytes)
            return {
                "ordinal": ordinal,
                "upload_bytes": upload["observed_bytes"],
                "download_bytes": download["observed_bytes"],
                "upload": upload,
                "download": download,
            }
        finally:
            sock.close()

    with ThreadPoolExecutor(max_workers=4) as executor:
        client_results = list(executor.map(one_session, range(1, 5)))
    target_results = target.wait_results(4, 180)
    client_upload = sum(row["upload_bytes"] for row in client_results)
    client_download = sum(row["download_bytes"] for row in client_results)
    target_upload = sum(row["upload_bytes"] for row in target_results)
    target_download = sum(row["download_bytes"] for row in target_results)
    return {
        "workload": "exact",
        "ok": (
            client_upload == target_upload == target.upload_bytes * 4
            and client_download == target_download == target.download_bytes * 4
        ),
        "sessions": client_results,
        "target_sessions": target_results,
        "endpoint_oracle": {
            "expected_upload_bytes": target.upload_bytes * 4,
            "expected_download_bytes": target.download_bytes * 4,
            "client_upload_bytes": client_upload,
            "client_download_bytes": client_download,
            "target_upload_bytes": target_upload,
            "target_download_bytes": target_download,
        },
    }


def run_churn(proxy, target_host, target, count):
    samples = []
    for index in range(count):
        started = time.monotonic()
        client_echo(proxy, target_host, target.port, one_byte=index % 2 == 0)
        samples.append((time.monotonic() - started) * 1000)
    target.wait_results(count, max(120, count * 2))
    return {
        "workload": "churn",
        "connections": count,
        "p50_ms": statistics.median(samples),
        "p95_ms": sorted(samples)[max(0, math.ceil(0.95 * len(samples)) - 1)],
    }


def run_sustained(proxy, target_host, target, mode, seconds):
    started, deadline = target.begin()
    client_totals = {"upload_bytes": 0, "download_bytes": 0}
    lock = threading.Lock()

    def worker():
        sock = socks_connect(*proxy, target_host, target.port)
        sock.settimeout(seconds + 20)
        uploaded = downloaded = 0
        try:
            if mode == "upload":
                while time.monotonic() < deadline:
                    sock.sendall(_CHUNK)
                    uploaded += len(_CHUNK)
                sock.shutdown(socket.SHUT_WR)
            elif mode == "download":
                while True:
                    chunk = sock.recv(CHUNK_SIZE)
                    if not chunk:
                        break
                    if chunk != pattern(downloaded, len(chunk)):
                        raise ValueError("payload mismatch")
                    downloaded += len(chunk)
            else:
                while time.monotonic() < deadline:
                    sock.sendall(_CHUNK)
                    uploaded += len(_CHUNK)
                    chunk = recv_exact(sock, len(_CHUNK))
                    if chunk != _CHUNK:
                        raise ValueError("mixed payload mismatch")
                    downloaded += len(chunk)
                sock.shutdown(socket.SHUT_WR)
        finally:
            sock.close()
        with lock:
            client_totals["upload_bytes"] += uploaded
            client_totals["download_bytes"] += downloaded

    session_count = 8 if mode in ("upload", "download") else 32
    with ThreadPoolExecutor(max_workers=session_count) as executor:
        futures = [executor.submit(worker) for _ in range(session_count)]
        for future in futures:
            future.result(timeout=seconds + 40)
    target_results = target.wait_results(session_count, seconds + 60)
    finished = time.monotonic()
    target_upload = sum(row.get("upload_bytes", 0) for row in target_results)
    target_download = sum(row.get("download_bytes", 0) for row in target_results)

    if mode in ("upload", "mixed") and client_totals["upload_bytes"] != target_upload:
        raise ValueError("upload endpoint oracle mismatch")
    if mode in ("download", "mixed") and client_totals["download_bytes"] != target_download:
        raise ValueError("download endpoint oracle mismatch")

    upload_bytes = target_upload if mode in ("upload", "mixed") else 0
    download_bytes = client_totals["download_bytes"] if mode in ("download", "mixed") else 0
    delivered_bytes = upload_bytes + download_bytes
    return {
        "workload": mode,
        "sessions": session_count,
        "upload_bytes": upload_bytes,
        "download_bytes": download_bytes,
        "delivered_bytes": delivered_bytes,
        "goodput_bps": delivered_bytes / (finished - started),
        "monotonic_start": started,
        "monotonic_end": finished,
    }


def expect_method_rejection(proxy, greeting):
    sock = socket.create_connection(proxy, timeout=20)
    sock.settimeout(20)
    try:
        sock.sendall(greeting)
        sock.shutdown(socket.SHUT_WR)
        try:
            response = sock.recv(2)
        except ConnectionResetError:
            response = b""
        if response == b"\x05\x00":
            raise ValueError("invalid greeting accepted")
    finally:
        sock.close()


def expect_request_rejection(proxy, request):
    sock = socket.create_connection(proxy, timeout=20)
    sock.settimeout(20)
    try:
        sock.sendall(b"\x05\x01\x00")
        if recv_exact(sock, 2) != b"\x05\x00":
            raise ValueError("NO AUTH rejected")
        sock.sendall(request)
        reply = recv_exact(sock, 10)
        if reply[1] == 0:
            raise ValueError("invalid request accepted")
    finally:
        sock.close()


def check_udp_association(proxy, target_host):
    """UDP ASSOCIATE, a datagram round trip, and teardown on control close.

    The correctness gate feeds `all_modes_protocol_ok` into the branch selector,
    so without this an engine whose UDP path is entirely broken could still be
    reported protocol-correct and be selected for CONNECT/UDP parity it does not
    have.
    """
    echo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    echo.bind(("0.0.0.0", 0))
    echo_port = echo.getsockname()[1]

    def serve():
        while True:
            try:
                data, peer = echo.recvfrom(65535)
                echo.sendto(data, peer)
            except OSError:
                return

    threading.Thread(target=serve, daemon=True).start()

    payload = bytes(range(251))
    packet = (b"\x00\x00\x00\x01" + socket.inet_aton(target_host)
              + echo_port.to_bytes(2, "big") + payload)
    control = socket.create_connection(proxy, timeout=20)
    control.settimeout(20)
    try:
        control.sendall(b"\x05\x01\x00")
        if recv_exact(control, 2) != b"\x05\x00":
            raise ValueError("NO AUTH rejected for UDP ASSOCIATE")
        control.sendall(b"\x05\x03\x00\x01" + b"\x00\x00\x00\x00" + b"\x00\x00")
        reply = recv_exact(control, 10)
        if reply[1] != 0x00:
            raise ValueError("UDP ASSOCIATE rejected")
        udp_port = int.from_bytes(reply[8:10], "big")

        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.settimeout(5)
        try:
            for _ in range(5):
                client.sendto(packet, (proxy[0], udp_port))
                try:
                    data, _ = client.recvfrom(65535)
                except socket.timeout:
                    continue
                if len(data) > 10 and data[10:] == payload:
                    break
            else:
                raise ValueError("UDP round trip failed")
        finally:
            client.close()
    finally:
        control.close()

    # Closing the control connection must release the association.
    time.sleep(0.5)
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.settimeout(1.5)
    try:
        probe.sendto(packet, (proxy[0], udp_port))
        probe.recvfrom(65535)
        raise ValueError("association survived control connection close")
    except socket.timeout:
        pass
    finally:
        probe.close()
        echo.close()


def run_correctness(proxy, target_host, target):
    checks = []
    for split in range(1, 3):
        client_echo(proxy, target_host, target.port, payload_length=32, greeting_split=split)
        checks.append(f"greeting_split_{split}")
    for split in range(1, 10):
        client_echo(proxy, target_host, target.port, payload_length=32, request_split=split)
        checks.append(f"request_split_{split}")
    client_echo(proxy, target_host, target.port, payload_length=32, one_byte=True)
    checks.append("one_byte_frames")
    payload = pattern(0, 32)
    client_echo(
        proxy,
        target_host,
        target.port,
        payload_length=len(payload),
        coalesced_payload=payload,
        coalesce_all=True,
    )
    checks.append("greeting_request_payload_coalesced")

    complete_methods = bytes((5, 255)) + bytes((0,)) * 255
    socket_for_methods = socket.create_connection(proxy, timeout=20)
    socket_for_methods.settimeout(20)
    try:
        socket_for_methods.sendall(complete_methods)
        if recv_exact(socket_for_methods, 2) != b"\x05\x00":
            raise ValueError("NMETHODS=255 rejected")
    finally:
        socket_for_methods.close()
    checks.append("nmethods_255_complete")

    expect_method_rejection(proxy, b"\x05\x01\x02")
    expect_method_rejection(proxy, b"\x04\x01\x00")
    truncated = socket.create_connection(proxy, timeout=20)
    truncated.settimeout(20)
    truncated.sendall(bytes((5, 255)) + bytes((0,)) * 254)
    truncated.shutdown(socket.SHUT_WR)
    try:
        truncated_response = truncated.recv(1)
    except ConnectionResetError:
        truncated_response = b""
    if truncated_response:
        raise ValueError("truncated NMETHODS frame produced data")
    truncated.close()
    checks.extend(("username_password_only", "invalid_greeting_version", "nmethods_255_truncated"))

    valid_address = socket.inet_aton(target_host) + target.port.to_bytes(2, "big")
    expect_request_rejection(proxy, b"\x04\x01\x00\x01" + valid_address)
    expect_request_rejection(proxy, b"\x05\x01\x01\x01" + valid_address)
    expect_request_rejection(proxy, b"\x05\x02\x00\x01" + valid_address)
    # ATYP 0x02 is unassigned. The previous case sent ATYP 0x03 with domain "a",
    # a perfectly valid request that only failed because "a" does not resolve --
    # so it never exercised address-type rejection and would have started passing
    # traffic on any network where that name resolves.
    expect_request_rejection(proxy, b"\x05\x01\x00\x02" + valid_address)
    checks.extend(("invalid_request_version", "invalid_rsv", "invalid_cmd", "invalid_atyp"))

    check_udp_association(proxy, target_host)
    checks.extend(("udp_associate", "udp_round_trip", "udp_teardown_on_control_close"))

    target.wait_results(13, 120)
    return {"workload": "correctness", "ok": True, "checks": checks}


def relay(client, target_host, target_port):
    target = None
    try:
        target = socket.create_connection((target_host, target_port), timeout=20)
        client.sendall(b"\x05\x00\x00\x01" + socket.inet_aton(target_host) + target_port.to_bytes(2, "big"))

        def pump(source, destination):
            # Linux GHA runners can raise ENOTCONN (107) on send after the peer
            # has already torn down the socket; macOS more often surfaces EPIPE /
            # BrokenPipe. Treat all OSError here as a closed relay, not a hard fail.
            try:
                while True:
                    chunk = source.recv(CHUNK_SIZE)
                    if not chunk:
                        break
                    destination.sendall(chunk)
            except OSError:
                pass
            finally:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = (executor.submit(pump, client, target), executor.submit(pump, target, client))
            for future in futures:
                future.result(timeout=180)
    finally:
        client.close()
        if target is not None:
            target.close()


def udp_associate(client):
    """Minimum UDP ASSOCIATE for the reference proxy.

    Exists so the correctness gate's UDP checks can run against this stand-in as
    well as against a real relay; without it the gate could only be exercised on
    a device. Same shape as the real one: no NAT table, the first well-formed
    sender is the client, everything else is a peer reply.
    """
    relay_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    relay_socket.bind(("127.0.0.1", 0))
    bound_port = relay_socket.getsockname()[1]
    client_address = None

    def pump():
        nonlocal client_address
        while True:
            try:
                data, source = relay_socket.recvfrom(65535)
            except OSError:
                return
            if client_address is None and len(data) > 10 and data[:3] == b"\x00\x00\x00":
                client_address = source
            if client_address is None:
                continue
            try:
                if source == client_address:
                    if len(data) < 11 or data[3] != 1:
                        continue
                    host = socket.inet_ntoa(data[4:8])
                    port = int.from_bytes(data[8:10], "big")
                    relay_socket.sendto(data[10:], (host, port))
                else:
                    header = (b"\x00\x00\x00\x01" + socket.inet_aton(source[0])
                              + source[1].to_bytes(2, "big"))
                    relay_socket.sendto(header + data, client_address)
            except OSError:
                return

    threading.Thread(target=pump, daemon=True).start()
    client.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1")
                   + bound_port.to_bytes(2, "big"))
    try:
        # The association lives exactly as long as its control connection.
        while client.recv(1):
            pass
    except OSError:
        pass
    finally:
        relay_socket.close()


def local_socks(target_host, target_port):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)
    stop_event = threading.Event()

    def handle(client):
        try:
            client.settimeout(20)
            version, count = recv_exact(client, 2)
            if version != 5:
                return
            methods = recv_exact(client, count)
            if 0 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x00")
            version, command, reserved, address_type = recv_exact(client, 4)
            reply = 0
            if version != 5 or reserved != 0:
                reply = 1
            elif command not in (1, 3):
                reply = 7
            elif address_type != 1:
                reply = 8
            if not reply and command == 3:
                recv_exact(client, 6)                    # declared client endpoint
                udp_associate(client)
                return
            if reply:
                client.sendall(b"\x05" + bytes((reply,)) + b"\x00\x01" + b"\x00" * 6)
                return
            requested_host = socket.inet_ntoa(recv_exact(client, 4))
            requested_port = int.from_bytes(recv_exact(client, 2), "big")
            if requested_host != target_host or requested_port != target_port:
                client.sendall(b"\x05\x04\x00\x01" + b"\x00" * 6)
                return
            relay(client, target_host, target_port)
        except (ConnectionError, OSError, TimeoutError, ValueError):
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass

    def accept_loop():
        while not stop_event.is_set():
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=handle, args=(client,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    return listener, stop_event


def self_test():
    target = TargetServer("127.0.0.1", "echo", 2, upload_bytes=1_000_003, download_bytes=700_007)
    proxy_listener, proxy_stop = local_socks("127.0.0.1", target.port)
    proxy = ("127.0.0.1", proxy_listener.getsockname()[1])
    try:
        result = run_correctness(proxy, "127.0.0.1", target)
        return {
            "ok": result["ok"],
            "external_client_target_path": True,
            "correctness_checks": len(result["checks"]),
        }
    finally:
        proxy_stop.set()
        proxy_listener.close()
        target.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "SOCKS5 host oracle; normal modes require an external proxy. "
            "Works for both iOS and Android: pass the phone listen IP/port "
            "(Android: hotspot IP after Start, e.g. 192.168.43.1:9876)."
        )
    )
    parser.add_argument("--mode", choices=("self-test", "correctness", "exact", "churn", *SUSTAINED_MODES), default="self-test")
    parser.add_argument(
        "--proxy-host",
        help="SOCKS5 proxy host (iPhone Wi-Fi/hotspot IP or Android hotspot IP)",
    )
    parser.add_argument(
        "--proxy-port",
        type=int,
        help="SOCKS5 proxy port (default app port is 9876)",
    )
    parser.add_argument("--target-bind", default="0.0.0.0")
    parser.add_argument("--target-host")
    parser.add_argument("--seconds", type=float, default=45.0)
    parser.add_argument("--churn-count", type=int, default=500)
    parser.add_argument("--redact", action="store_true")
    # Diagnostic: keeps the client's write side open through the download, so the
    # relay never propagates a FIN and the target connection cannot complete its
    # close while bytes are still buffered unread on the proxy.
    parser.add_argument("--no-half-close", action="store_true")
    args = parser.parse_args(argv)
    global HALF_CLOSE
    HALF_CLOSE = not args.no_half_close

    try:
        exit_status = 0
        if args.mode == "self-test":
            output = self_test()
        else:
            if not args.proxy_host or not args.proxy_port or not args.target_host:
                raise ValueError("normal mode requires --proxy-host --proxy-port --target-host")
            socket.inet_aton(args.target_host)
            target_mode = "echo" if args.mode in ("correctness", "churn") else args.mode
            target = TargetServer(args.target_bind, target_mode, args.seconds)
            target_port = target.port
            proxy = (args.proxy_host, args.proxy_port)
            try:
                if args.mode == "correctness":
                    output = run_correctness(proxy, args.target_host, target)
                elif args.mode == "exact":
                    output = run_exact(proxy, args.target_host, target)
                    if not output["ok"]:
                        exit_status = 2
                elif args.mode == "churn":
                    output = run_churn(proxy, args.target_host, target, args.churn_count)
                else:
                    output = run_sustained(proxy, args.target_host, target, args.mode, args.seconds)
            finally:
                target.close()
            if not args.redact:
                output["target_host"] = args.target_host
                output["target_port"] = target_port
        print(json.dumps(output, separators=(",", ":"), sort_keys=True))
        return exit_status
    except Exception as error:
        detail = type(error).__name__ if getattr(args, "redact", False) else f"{type(error).__name__}: {error}"
        print(json.dumps({"failure": detail}, separators=(",", ":"), sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
