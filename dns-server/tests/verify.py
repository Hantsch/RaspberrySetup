"""Offline tests: python3 dns-server/tests/verify.py (requires PyYAML)."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import urllib.error
import zipfile

import yaml

spec = importlib.util.spec_from_file_location("adguard", Path(__file__).parents[1] / "scripts" / "adguard.py")
adguard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adguard)


class AdGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "AdGuardHome"
        self.root.mkdir()
        self.config = {
            "schema_version": 32,
            "users": [{"name": "admin", "password": "existing-password-hash"}],
            "http": {"address": "127.0.0.1:3000", "session_ttl": "720h"},
            "dns": {"cache_size": 4194304, "upstream_dns": ["1.1.1.1"]},
            "filtering": {"protection_enabled": True, "filtering_enabled": True},
            "filters": [{"id": 1, "enabled": True, "url": "https://example.org/list.txt"}],
            "user_rules": ["@@||keep.example.org^"],
            "clients": [{"name": "keep-me", "ids": ["192.168.50.10"]}],
        }
        adguard.write_config(self.root, self.config)
        (self.root / "AdGuardHome").write_bytes(b"test-executable")
        self.filter = self.root / "data" / "filters" / "1.txt"
        self.filter.parent.mkdir(parents=True)
        self.filter.write_text("||ads.example.org^\n", encoding="utf-8")

    def configure(self):
        adguard.configure(self.root, "192.168.50.2", '["https://dns.quad9.net/dns-query"]',
                          '["9.9.9.9"]', "192.168.50.0/24")

    def test_rerun_preserves_users_lists_clients_and_is_idempotent(self):
        self.configure()
        once = (self.root / "AdGuardHome.yaml").read_bytes()
        self.configure()
        self.assertEqual(once, (self.root / "AdGuardHome.yaml").read_bytes())
        result = adguard.read_config(self.root)
        for field in ("users", "filters", "user_rules", "clients", "schema_version"):
            self.assertEqual(result[field], self.config[field])
        self.assertEqual(result["dns"]["allowed_clients"], ["127.0.0.1", "192.168.50.0/24"])
        self.assertEqual(result["dns"]["bind_hosts"], ["127.0.0.1", "192.168.50.2"])
        self.assertFalse(result["dhcp"]["enabled"])

    def test_backup_contains_restore_files_and_excludes_nested_backups(self):
        (self.root / "backup").mkdir()
        (self.root / "backup" / "old").write_text("old")
        archive = self.root.parent / "backup.zip"
        adguard.backup(self.root, archive)
        with zipfile.ZipFile(archive) as backup:
            self.assertEqual(backup.read("AdGuardHome/AdGuardHome"), b"test-executable")
            self.assertEqual(yaml.safe_load(backup.read("AdGuardHome/AdGuardHome.yaml")), self.config)
            self.assertIn("AdGuardHome/data/filters/1.txt", backup.namelist())
            self.assertFalse(any(name.startswith("AdGuardHome/backup") for name in backup.namelist()))

    def test_health_rejects_disabled_filtering_or_empty_cache(self):
        adguard.health(self.root)
        self.config["filtering"]["protection_enabled"] = False
        adguard.write_config(self.root, self.config)
        with self.assertRaisesRegex(ValueError, "disabled"):
            adguard.health(self.root)
        self.config["filtering"]["protection_enabled"] = True
        adguard.write_config(self.root, self.config)
        self.filter.unlink()
        with self.assertRaisesRegex(ValueError, "cache"):
            adguard.health(self.root)

    def test_rejects_unauthenticated_config(self):
        self.config["users"] = []
        adguard.write_config(self.root, self.config)
        with self.assertRaisesRegex(ValueError, "admin account"):
            self.configure()

    def test_initialize_uses_official_api_and_always_stops_process(self):
        (self.root / "AdGuardHome.yaml").unlink()
        process = Mock()
        process.poll.return_value = None
        client = Mock()
        calls = []

        def request(value, timeout):
            calls.append(value)
            if isinstance(value, str):
                self.assertTrue(value.endswith("/control/install/get_addresses"))
            else:
                self.assertEqual(value.full_url, "http://127.0.0.1:3000/control/install/configure")
                payload = json.loads(value.data)
                self.assertEqual(payload["username"], "admin")
                self.assertEqual(payload["web"], {"ip": "127.0.0.1", "port": 3000})
                self.assertEqual(payload["dns"], {"ip": "192.168.50.2", "port": 53})
                adguard.write_config(self.root, self.config)
            return io.BytesIO(b"{}")

        client.open.side_effect = request
        with patch.object(adguard.getpass, "getpass", return_value="test-only-password"), \
             patch.object(adguard.urllib.request, "build_opener", return_value=client), \
             patch.object(adguard.subprocess, "Popen", return_value=process) as popen:
            adguard.initialize(self.root, "192.168.50.2")
        arguments = popen.call_args.args[0]
        self.assertNotIn("test-only-password", arguments)
        self.assertIn("127.0.0.1:3000", arguments)
        process.terminate.assert_called_once()
        process.wait.assert_called_once()
        self.assertEqual(len(calls), 2)

    def test_failed_initialize_stops_process(self):
        (self.root / "AdGuardHome.yaml").unlink()
        process = Mock()
        process.poll.return_value = None
        client = Mock()
        client.open.side_effect = [io.BytesIO(b"{}"), urllib.error.HTTPError("localhost", 400, "bad request", {}, None)]
        with patch.object(adguard.getpass, "getpass", return_value="test-only-password"), \
             patch.object(adguard.urllib.request, "build_opener", return_value=client), \
             patch.object(adguard.subprocess, "Popen", return_value=process):
            with self.assertRaises(urllib.error.HTTPError):
                adguard.initialize(self.root, "192.168.50.2")
        process.terminate.assert_called_once()
        self.assertFalse((self.root / "AdGuardHome.yaml").exists())


if __name__ == "__main__":
    unittest.main()
