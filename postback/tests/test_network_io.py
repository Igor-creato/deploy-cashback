"""
Экспорт / импорт настроек одной сети в админке Webhook Receiver.

Покрывает чистые helpers app/config.py:
  - network_export_view: секреты не выгружаются, конверт _type/_version,
    исходный network не мутируется;
  - sanitize_imported_network: строгий gate, whitelist+коэрция типов,
    секреты (secret_path / signing.secret / db_network_id) берутся из
    existing, а не из файла.
"""

import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_POSTBACK_ROOT = os.path.dirname(_HERE)
if _POSTBACK_ROOT not in sys.path:
    sys.path.insert(0, _POSTBACK_ROOT)

from app.config import (  # noqa: E402
    EXPORT_TYPE,
    EXPORT_VERSION,
    network_export_view,
    sanitize_imported_network,
)


def _sample_network() -> dict:
    return {
        "name": "Advcake",
        "slug": "advcake",
        "secret_path": "TOP_SECRET_PATH_xyz",
        "is_active": True,
        "webhook_method": "GET&POST",
        "webhook_base_url": "https://www.admitad.com",
        "rate_limit": 5000,
        "db_network_id": 9,
        "mapping": {"click_id": "click_id", "uniq_id": "uniq_id"},
        "status_mapping": {"1": "waiting", "2": "completed"},
        "field_transforms": {"action_date": "unix_timestamp"},
        "signing": {
            "enabled": True,
            "algorithm": "hmac-sha256",
            "secret": "SUPER_HMAC_SECRET",
            "header": "X-Signature",
            "format": "hex",
            "source": "body",
        },
    }


class ExportViewTest(unittest.TestCase):
    def test_envelope_and_secret_stripping(self):
        net = _sample_network()
        view = network_export_view("advcake", net)

        self.assertEqual(view["_type"], EXPORT_TYPE)
        self.assertEqual(view["_version"], EXPORT_VERSION)
        self.assertEqual(view["slug"], "advcake")

        exported = view["network"]
        self.assertNotIn("secret_path", exported)
        self.assertNotIn("secret", exported["signing"])
        # Несекретные signing-подполя остаются.
        self.assertEqual(exported["signing"]["algorithm"], "hmac-sha256")
        self.assertEqual(exported["mapping"], net["mapping"])

    def test_source_not_mutated(self):
        net = _sample_network()
        network_export_view("advcake", net)
        self.assertEqual(net["secret_path"], "TOP_SECRET_PATH_xyz")
        self.assertEqual(net["signing"]["secret"], "SUPER_HMAC_SECRET")


class ImportSanitizeTest(unittest.TestCase):
    def test_rejects_bad_type(self):
        existing = _sample_network()
        clean, err = sanitize_imported_network(
            {"_type": "nope", "_version": 1, "network": {}}, existing
        )
        self.assertIsNone(clean)
        self.assertEqual(err, "bad_format")

    def test_rejects_bad_version(self):
        existing = _sample_network()
        clean, err = sanitize_imported_network(
            {"_type": EXPORT_TYPE, "_version": 999, "network": {}}, existing
        )
        self.assertIsNone(clean)
        self.assertEqual(err, "bad_format")

    def test_rejects_non_dict(self):
        clean, err = sanitize_imported_network("not a dict", _sample_network())
        self.assertIsNone(clean)
        self.assertEqual(err, "bad_format")

    def test_rejects_missing_network(self):
        clean, err = sanitize_imported_network(
            {"_type": EXPORT_TYPE, "_version": EXPORT_VERSION}, _sample_network()
        )
        self.assertIsNone(clean)
        self.assertEqual(err, "bad_format")

    def test_secrets_taken_from_existing_not_file(self):
        existing = _sample_network()
        payload = {
            "_type": EXPORT_TYPE,
            "_version": EXPORT_VERSION,
            "network": {
                "name": "Advcake",
                "secret_path": "ATTACKER_PATH",
                "db_network_id": 999,
                "mapping": {"click_id": "click_id"},
                "signing": {
                    "enabled": True,
                    "algorithm": "hmac-sha256",
                    "secret": "ATTACKER_SECRET",
                    "header": "X-Signature",
                    "format": "hex",
                    "source": "body",
                },
            },
        }
        clean, err = sanitize_imported_network(payload, existing)
        self.assertEqual(err, "")
        self.assertEqual(clean["secret_path"], "TOP_SECRET_PATH_xyz")
        self.assertEqual(clean["db_network_id"], 9)
        self.assertEqual(clean["signing"]["secret"], "SUPER_HMAC_SECRET")

    def test_whitelist_and_coercion(self):
        existing = _sample_network()
        payload = {
            "_type": EXPORT_TYPE,
            "_version": EXPORT_VERSION,
            "network": {
                "name": "  Renamed  ",
                "rate_limit": -5,
                "webhook_method": "HEAD",
                "mapping": {"a": "b", "bad": 123, 7: "x", "ok": "y"},
                "status_mapping": {"1": "waiting"},
                "field_transforms": {},
                "signing": {
                    "enabled": "yes",
                    "algorithm": "rot13",
                    "header": "bad header!!",
                    "format": "weird",
                    "source": "nope",
                },
                "evil_extra_key": "dropped",
            },
        }
        clean, err = sanitize_imported_network(payload, existing)
        self.assertEqual(err, "")
        self.assertEqual(clean["name"], "Renamed")
        self.assertEqual(clean["rate_limit"], 200)  # negative → default
        self.assertEqual(clean["webhook_method"], "GET&POST")  # invalid → kept
        # Невалидные пары маппинга отброшены, валидные сохранены.
        self.assertEqual(clean["mapping"], {"a": "b", "ok": "y"})
        # signing: невалидные значения → дефолты, enabled bool-коэрция.
        self.assertTrue(clean["signing"]["enabled"])
        self.assertEqual(clean["signing"]["algorithm"], "hmac-sha256")
        self.assertEqual(clean["signing"]["header"], "X-Signature")
        self.assertEqual(clean["signing"]["format"], "hex")
        self.assertEqual(clean["signing"]["source"], "body")
        self.assertNotIn("evil_extra_key", clean)

    def test_roundtrip_export_then_import(self):
        existing = _sample_network()
        view = network_export_view("advcake", existing)
        clean, err = sanitize_imported_network(view, existing)
        self.assertEqual(err, "")
        self.assertEqual(clean["mapping"], existing["mapping"])
        self.assertEqual(clean["status_mapping"], existing["status_mapping"])
        self.assertEqual(clean["webhook_method"], "GET&POST")
        # Секреты восстановлены из existing даже после strip в экспорте.
        self.assertEqual(clean["secret_path"], "TOP_SECRET_PATH_xyz")
        self.assertEqual(clean["signing"]["secret"], "SUPER_HMAC_SECRET")


if __name__ == "__main__":
    unittest.main()
