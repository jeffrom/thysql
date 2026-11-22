"""Kept TLS bundles must remain valid and invalidate stale server processes."""

import contextlib
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent / "e2e"))

import harness


class KeptTlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.source.cleanup)
        harness.make_tls_material(cls.source.name)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = temporary.name
        shutil.copytree(self.source.name, self.directory, dirs_exist_ok=True)
        self.tls = harness.tls_paths(self.directory)
        for patch in (mock.patch.dict(os.environ, {"THYSQL_E2E_KEEP": "1"}),
                      mock.patch.object(harness, "TLS_KEEP_DIR", self.directory)):
            patch.start()
            self.addCleanup(patch.stop)

    def prepare(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return harness._prepare_tls()

    def expire(self, cert, key):
        # Explicit historical dates work with OpenSSL versions that reject -days 0.
        is_ca = cert in ("ca.pem", "wrong-ca.pem")
        shutil.copyfile(Path(self.directory, cert if is_ca else "ca.pem"),
                        Path(self.directory, "signing-ca.pem"))
        Path(self.directory, "index.txt").write_text("")
        Path(self.directory, "serial.txt").write_text("01\n")
        Path(self.directory, "issued").mkdir(exist_ok=True)
        Path(self.directory, "expire.cnf").write_text(
            "[ca]\ndefault_ca = local\n[local]\n"
            "database = index.txt\nserial = serial.txt\nnew_certs_dir = issued\n"
            "certificate = signing-ca.pem\n"
            f"private_key = {key if is_ca else 'ca-key.pem'}\n"
            "default_md = sha256\npolicy = policy\n"
            "[policy]\ncommonName = supplied\n"
            "[ca_extensions]\nbasicConstraints = critical,CA:TRUE\n"
        )
        harness._openssl(
            ["x509", "-in", cert, "-x509toreq", "-signkey", key, "-out", "expired.csr"],
            self.directory,
        )
        options = ["-selfsign", "-extensions", "ca_extensions"] if is_ca else []
        harness._openssl(
            ["ca", "-batch", "-config", "expire.cnf", "-in", "expired.csr", "-out", cert,
             "-startdate", "20000101000000Z", "-enddate", "20000102000000Z", *options],
            self.directory,
        )

    def test_valid_bundle_is_reused_without_regenerating_keys(self):
        before = harness._tls_fingerprint(self.tls)
        with mock.patch.object(harness, "make_tls_material", wraps=harness.make_tls_material) as generate:
            self.assertEqual(self.prepare(), self.tls)

        generate.assert_not_called()
        self.assertEqual(harness._tls_fingerprint(self.tls), before)

    def test_expired_leaf_is_renewed_even_with_a_valid_ca_and_existing_key(self):
        self.expire("server-cert.pem", "server-key.pem")
        before = {
            target.name: harness._configuration_fingerprint(target, self.tls)
            for target in harness.TARGETS.values()
        }
        self.assertTrue(Path(self.tls.server_key).exists())
        self.assertFalse(harness._tls_reusable(self.tls))

        renewed = self.prepare()

        self.assertEqual(renewed.directory, self.directory)
        self.assertTrue(harness._tls_reusable(renewed))
        for target in harness.TARGETS.values():
            with self.subTest(target=target.name):
                self.assertNotEqual(harness._configuration_fingerprint(target, renewed), before[target.name])

    def test_expired_ca_or_client_certificate_requires_renewal(self):
        for cert, key in (("ca.pem", "ca-key.pem"), ("wrong-ca.pem", "wrong-key.pem"),
                          ("client-cert.pem", "client-key.pem")):
            with self.subTest(cert=cert):
                shutil.copytree(self.source.name, self.directory, dirs_exist_ok=True)
                self.expire(cert, key)
                self.assertFalse(harness._tls_reusable(self.tls))

    def test_missing_certificate_is_repaired(self):
        Path(self.tls.client_cert).unlink()

        renewed = self.prepare()

        self.assertTrue(harness._tls_reusable(renewed))

    def test_broken_key_or_hashed_ca_is_not_reused(self):
        Path(self.tls.client_key).write_text("not a private key")
        self.assertFalse(harness._tls_reusable(self.tls))

        shutil.copytree(self.source.name, self.directory, dirs_exist_ok=True)
        shutil.rmtree(self.tls.capath)
        self.assertFalse(harness._tls_reusable(self.tls))


if __name__ == "__main__":
    unittest.main()
