"""
Brand-color / logo override parity с PHP-плагином.

Регрессия: Python webhook-worker слал постбэк-письма без брендинга,
потому что _get_brand_color()/_get_logo_url() не читали ручные
override-опции (`cashback_email_brand_color`, `cashback_email_logo_id`),
которые PHP Cashback_Theme_Color::get_brand_color() /
Cashback_Email_Sender::get_logo_url() читают первым шагом.

Эталон паритета:
  wp-content/plugins/cash-back/includes/class-cashback-theme-color.php
  wp-content/plugins/cash-back/notifications/class-cashback-email-sender.php
"""
import os
import sys
import unittest
from unittest import mock

# Гарантируем, что postback/ в sys.path (тест может быть запущен из любого CWD).
_HERE = os.path.dirname(os.path.abspath(__file__))
_POSTBACK_ROOT = os.path.dirname(_HERE)
if _POSTBACK_ROOT not in sys.path:
    sys.path.insert(0, _POSTBACK_ROOT)

from app import email_sender  # noqa: E402


def _option_stub(values: dict[str, str | None]):
    """Фабрика side_effect для _get_wp_option: вернуть из dict, иначе None."""
    def _inner(name: str):
        return values.get(name)
    return _inner


class _BrandingTestBase(unittest.TestCase):
    def setUp(self):
        # Кэши брендинга/настроек не должны протекать между кейсами.
        email_sender._branding_cache = {}
        email_sender._branding_cache_ts = 0.0
        email_sender._wp_settings_cache = {}
        email_sender._wp_settings_ts = 0.0


class TestBrandColorOverride(_BrandingTestBase):

    def test_manual_override_wins_over_woodmart_and_theme_mods(self):
        opts = {
            "cashback_email_brand_color": "#4555e8",
            # Даже если woodmart/theme_mods заданы другим цветом — override главнее.
            "xts-woodmart-options": None,
            "stylesheet": "woodmart-child",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)):
            self.assertEqual(email_sender._get_brand_color(), "#4555e8")

    def test_invalid_override_falls_through_to_next_step(self):
        opts = {
            "cashback_email_brand_color": "not-a-color",
            "xts-woodmart-options": None,
            "stylesheet": "",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)):
            # невалидный override → fallback (woodmart/theme_mods пусты)
            self.assertEqual(email_sender._get_brand_color(),
                             email_sender._BRAND_FALLBACK_COLOR)

    def test_fallback_matches_php_default(self):
        # Паритет с PHP Cashback_Theme_Color::get_brand_color() fallback.
        self.assertEqual(email_sender._BRAND_FALLBACK_COLOR, "#4555e8")

    def test_no_override_uses_woodmart_primary_color(self):
        opts = {
            "cashback_email_brand_color": None,
            "stylesheet": "woodmart-child",
        }

        def _unser(value):
            if value == "WOODMART":
                return {"primary-color": "#83b735"}
            return None

        opts["xts-woodmart-options"] = "WOODMART"
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)), \
             mock.patch.object(email_sender, "_php_unserialize",
                               side_effect=_unser):
            self.assertEqual(email_sender._get_brand_color(), "#83b735")


class TestLogoIdOverride(_BrandingTestBase):

    def test_logo_id_override_resolved_via_attachment_guid(self):
        opts = {
            "cashback_email_logo_id": "445",
            "whb_main_header": None,
            "stylesheet": "woodmart-child",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)), \
             mock.patch.object(email_sender, "_attachment_guid",
                               return_value="https://example.test/logo.png") as guid:
            self.assertEqual(email_sender._get_logo_url(),
                             "https://example.test/logo.png")
            guid.assert_called_once_with(445)

    def test_logo_id_override_wins_over_header_builder(self):
        opts = {
            "cashback_email_logo_id": "445",
            # Header Builder задан, но override приоритетнее → _get_woodmart_logo_url не вызывается.
            "whb_main_header": "123",
            "stylesheet": "woodmart-child",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)), \
             mock.patch.object(email_sender, "_attachment_guid",
                               return_value="https://example.test/override.png"), \
             mock.patch.object(email_sender, "_get_woodmart_logo_url") as whb:
            self.assertEqual(email_sender._get_logo_url(),
                             "https://example.test/override.png")
            whb.assert_not_called()

    def test_empty_logo_id_falls_through(self):
        opts = {
            "cashback_email_logo_id": "0",
            "whb_main_header": None,
            "stylesheet": "",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)), \
             mock.patch.object(email_sender, "_attachment_guid") as guid:
            # logo_id=0 → следующий шаг; всё пусто → None
            self.assertIsNone(email_sender._get_logo_url())
            guid.assert_not_called()

    def test_non_numeric_logo_id_falls_through(self):
        opts = {
            "cashback_email_logo_id": "abc",
            "whb_main_header": None,
            "stylesheet": "",
        }
        with mock.patch.object(email_sender, "_get_wp_option",
                               side_effect=_option_stub(opts)), \
             mock.patch.object(email_sender, "_attachment_guid") as guid:
            self.assertIsNone(email_sender._get_logo_url())
            guid.assert_not_called()


if __name__ == "__main__":
    unittest.main()
