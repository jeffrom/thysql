"""Lost connections and Ctrl-C when a new connection stalls during TLS."""

import contextlib
import os
import select
import signal
import socket
import struct
import threading

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env


class StalledTlsProxy:
    """Relays the first connection; later connections stall at the TLS handshake.

    The greeting comes from the real server. After receiving an SSLRequest and
    TLS ClientHello, the proxy leaves the socket open without answering. This
    exercises libmariadb's real TLS timeout rather than injecting an error string.
    """

    def __init__(self, server):
        self.server = server
        self.stopped = threading.Event()
        self.drop_requested = threading.Event()
        self.dropped = threading.Event()
        self.tls_started = threading.Event()
        self.errors = []
        self.sockets = []
        self.threads = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]

    def start(self):
        self.spawn(self.accept)

    def spawn(self, target, *args):
        thread = threading.Thread(target=target, args=args, daemon=True)
        self.threads.append(thread)
        thread.start()

    def accept(self):
        first = True
        while not self.stopped.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stopped.is_set():
                    return
                raise
            self.sockets.append(client)
            self.spawn(self.handle, client, first)
            first = False

    @staticmethod
    def read_exact(sock, size):
        data = b""
        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                raise EOFError("connection closed during handshake")
            data += chunk
        return data

    def read_packet(self, sock):
        header = self.read_exact(sock, 4)
        return header + self.read_exact(sock, int.from_bytes(header[:3], "little"))

    def handle(self, client, first):
        upstream = None
        try:
            upstream = socket.create_connection(("127.0.0.1", self.server.port), timeout=5)
            self.sockets.append(upstream)
            if self.stopped.is_set():
                return
            client.settimeout(5)
            if first:
                self.relay(client, upstream)
                return

            client.sendall(self.read_packet(upstream))
            request = self.read_packet(client)[4:]
            if len(request) != 32 or not int.from_bytes(request[:4], "little") & 0x0800:
                raise AssertionError(f"expected MySQL SSLRequest, got {request!r}")
            hello = self.read_exact(client, 5)
            if hello[0] != 0x16:
                raise AssertionError(f"expected TLS ClientHello record, got {hello!r}")
            self.read_exact(client, int.from_bytes(hello[3:5], "big"))
            self.tls_started.set()
            while not self.stopped.is_set():
                if not client.recv(4096):
                    return
        except (OSError, EOFError, AssertionError) as err:
            if not self.stopped.is_set():
                self.errors.append(repr(err))
        finally:
            client.close()
            if upstream is not None:
                upstream.close()

    def relay(self, client, upstream):
        while not self.stopped.is_set():
            if self.drop_requested.is_set():
                # A reset before the next statement produces CR_SERVER_GONE_ERROR
                # even on TLS, matching the reported initial error 2006.
                client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                client.close()
                upstream.close()
                self.dropped.set()
                return
            for source in select.select([client, upstream], [], [], 0.01)[0]:
                data = source.recv(65536)
                if not data:
                    return
                destination = upstream if source is client else client
                destination.sendall(data)

    def close(self):
        self.stopped.set()
        self.listener.close()
        # Stop accepting before walking the sockets and connection threads.
        if self.threads:
            self.threads[0].join(timeout=2)
        for sock in self.sockets:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            sock.close()
        for thread in self.threads:
            # A worker may still be opening its upstream socket when teardown
            # starts. Let that bounded connect finish and run its finally block
            # before the next Interactive session calls forkpty.
            thread.join(timeout=6)
        if any(thread.is_alive() for thread in self.threads):
            raise RuntimeError("TLS proxy threads did not stop")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class ReconnectTimeoutTests(E2ETestCase):
    def start(self, proxy):
        session = self.interactive(
            ["-h", "127.0.0.1", "-P", str(proxy.port), "-u", ROOT_USER,
             "--connect-timeout=2", "-A", TEST_DB],
            env=password_env(ROOT_USER),
        )
        # forkpty must run before the proxy starts its worker threads.
        proxy.start()
        prompt = f"root@127.0.0.1:{proxy.port}/{TEST_DB}> "
        session.expect(prompt)
        session.send("set @members = 'alice,bob', @pattern = '^alice$';\r")
        session.expect("Query OK")
        session.expect(prompt)
        return session, prompt

    def wait_for(self, event, proxy):
        self.assertTrue(event.wait(timeout=5), f"proxy did not reach expected phase: {proxy.errors}")
        self.assertEqual(proxy.errors, [])

    def lose_connection(self, proxy):
        session, prompt = self.start(proxy)
        proxy.drop_requested.set()
        self.wait_for(proxy.dropped, proxy)
        session.send(
            "select name from people where find_in_set(name, @members) "
            "and name regexp @pattern;\r"
        )
        session.expect("ERROR 2006 (HY000): Server has gone away")
        self.wait_for(proxy.tls_started, proxy)
        return session, prompt

    def test_lost_connection_reports_tls_reconnect_timeout_after_ctrl_c(self):
        for server in self.each_server():
            with self.subTest(server=server.name), StalledTlsProxy(server) as proxy:
                session, prompt = self.lose_connection(proxy)

                # SIGINT is the signal generated by Ctrl-C while SQL is running.
                os.kill(session.pid, signal.SIGINT)
                text = session.expect("ERROR: Can't connect to the server", timeout=8)
                self.assertIn("No connection. Trying to reconnect...", text)
                self.assertRegex(text, r"ERROR 2026 \(HY000\): TLS/SSL error: .*timed out")
                session.expect(prompt)
                session.send("\x04")
                self.assertEqual(session.wait_exit(), 0)

    def test_lost_connection_reports_reconnect_before_tls_timeout(self):
        for server in self.each_server():
            with self.subTest(server=server.name), StalledTlsProxy(server) as proxy:
                session, _ = self.lose_connection(proxy)
                # The handshake has started but cannot finish. The reconnect
                # notice must already be visible, before the two-second timeout.
                session.expect("No connection. Trying to reconnect...", timeout=0.5)
