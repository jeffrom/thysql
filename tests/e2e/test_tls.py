"""TLS and socket options, against MySQL 8.4 and MariaDB 11.4.

The servers present a certificate signed by a throwaway CA (see
`harness.tls_material`). `Ssl_cipher` reports the cipher of the current
connection, so an empty value means the connection is plaintext.

Socket tests cover error handling only. A host-side client cannot reach a
server through a Unix socket in a bind-mounted directory on Docker Desktop
for macOS: the socket file appears on the host but refuses connections.
"""

import os

from harness import ROOT_USER, TEST_DB, E2ETestCase, password_env, run_thysql, tls_material

SSL_CIPHER = "SHOW STATUS LIKE 'Ssl_cipher'"
CIPHER_VALUE = r"Ssl_cipher\t(\S+)"
PLAINTEXT = r"Ssl_cipher\t\n"


class TlsTests(E2ETestCase):
    def tls_run(self, server, extra, query=SSL_CIPHER):
        """Runs thysql against `server` with TLS options `extra`, as root."""
        self.require_capability(server, "tls_inspection")
        args = server.connect_args(ROOT_USER) + extra + ["-e", query]
        return run_thysql(args, env=password_env(ROOT_USER))

    def test_default_connection_uses_tls_when_offered(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, [])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_skip_ssl_alone_is_plaintext(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--skip-ssl"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, PLAINTEXT)

    def test_ca_alone_verifies_the_server(self):
        # As in mysql.cc, giving a CA turns verification on without the flag.
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl-ca", material.wrong_ca])
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("Connect to database failed", result.stderr)

    def test_ca_with_verify_connects_over_tls(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl-ca", material.ca, "--ssl-verify-server-cert"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_wrong_ca_fails_verification(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl-ca", material.wrong_ca, "--ssl-verify-server-cert"])
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("Connect to database failed", result.stderr)

    def test_verify_off_accepts_a_wrong_ca(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl-ca", material.wrong_ca, "--ssl-verify-server-cert=0"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_bare_ssl_encrypts_without_verifying(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_skip_ssl_turns_tls_off_after_ca(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(
                    server,
                    ["--ssl-ca", material.ca, "--ssl-verify-server-cert", "--skip-ssl"],
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, PLAINTEXT)

    def test_client_certificate_and_key_are_accepted(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, [
                    "--ssl-ca", material.ca,
                    "--ssl-cert", material.client_cert,
                    "--ssl-key", material.client_key,
                    "--ssl-verify-server-cert",
                ])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_ca_directory_is_searched(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, ["--ssl-capath", material.capath, "--ssl-verify-server-cert"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, CIPHER_VALUE)

    def test_tls_version_and_cipher_are_applied(self):
        material = tls_material()
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = self.tls_run(server, [
                    "--ssl-ca", material.ca,
                    "--ssl-verify-server-cert",
                    "--tls-version=TLSv1.2",
                    "--ssl-cipher=ECDHE-RSA-AES128-GCM-SHA256",
                ])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"Ssl_cipher\tECDHE-RSA-AES128-GCM-SHA256\n")


class SocketTests(E2ETestCase):
    def test_missing_socket_file_fails_for_localhost(self):
        missing = os.path.join(self.home, "missing.sock")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    ["-h", "localhost", "-u", ROOT_USER, "-S", missing, "-e", "select 1"],
                    env=password_env(ROOT_USER),
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("Connect to database failed", result.stderr)
                self.assertIn("through socket", result.stderr)

    def test_socket_is_ignored_for_a_non_localhost_host(self):
        # libmariadb uses the socket only for host localhost (or no host), so
        # with -h 127.0.0.1 the -S path is never opened and TCP is used.
        missing = os.path.join(self.home, "missing.sock")
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    server.connect_args(ROOT_USER) + ["-S", missing, "-D", TEST_DB, "-e", "select 1 as one"],
                    env=password_env(ROOT_USER),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("one", result.stdout)

    def test_protocol_tcp_connects_with_localhost(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    ["-h", "localhost", "--protocol=tcp", "-P", str(server.port), "-u", ROOT_USER,
                     "-e", "select 1 as one"],
                    env=password_env(ROOT_USER),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("one", result.stdout)

    def test_unknown_protocol_is_rejected(self):
        for server in self.each_server():
            with self.subTest(server=server.name):
                result = run_thysql(
                    server.connect_args(ROOT_USER) + ["--protocol=pipe", "-e", "select 1"],
                    env=password_env(ROOT_USER),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid protocol", result.stdout + result.stderr)
