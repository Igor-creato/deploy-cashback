"""
Линкификация голых URL в теле постбэк-письма — паритет с PHP-плагином.

Регрессия: Python webhook-worker слал письмо «Ваша покупка зафиксирована»
с URL личного кабинета как плоским НЕкликабельным текстом, тогда как
PHP-плагин (Cashback_Email_Sender::render_html_template) прогоняет тело
через make_clickable() + recolor-callback и URL становится <a> с
брендовым цветом. Из-за двух независимых отправителей одного и того же
уведомления пользователь получал визуально разные письма.

Эталон паритета:
  wp-content/plugins/cash-back/notifications/class-cashback-email-sender.php:220-232
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

_HISTORY_URL = "https://savelloclub.ru/my-account/cashback-history/"
_BRAND = "#4555e8"


class TestMakeClickable(unittest.TestCase):

    def test_bare_url_becomes_styled_anchor(self):
        body = f"Отслеживайте статус в личном кабинете: {_HISTORY_URL}"
        out = email_sender._make_clickable(body, _BRAND)
        self.assertIn(
            f'<a href="{_HISTORY_URL}" '
            f'style="color:{_BRAND};text-decoration:underline;">'
            f'{_HISTORY_URL}</a>',
            out,
        )
        # «голого» URL без href остаться не должно.
        self.assertNotIn(f": {_HISTORY_URL}", out)

    def test_plain_text_without_url_is_escaped_and_has_no_anchor(self):
        out = email_sender._make_clickable("Магазин: aptekiplus.ru\nСумма: 33,80 ₽", _BRAND)
        self.assertNotIn("<a ", out)
        self.assertIn("aptekiplus.ru", out)

    def test_html_special_chars_in_non_url_part_are_escaped(self):
        out = email_sender._make_clickable('Тест <b> & "кавычки"', _BRAND)
        self.assertIn("&lt;b&gt;", out)
        self.assertIn("&amp;", out)
        self.assertIn("&quot;", out)

    def test_trailing_punctuation_stays_outside_anchor(self):
        out = email_sender._make_clickable(f"Ссылка: {_HISTORY_URL}.", _BRAND)
        self.assertIn(f'href="{_HISTORY_URL}"', out)
        self.assertNotIn(f'href="{_HISTORY_URL}."', out)
        self.assertTrue(out.endswith("</a>."), out)

    def test_unbalanced_closing_paren_stays_outside_anchor(self):
        out = email_sender._make_clickable(f"(см. {_HISTORY_URL})", _BRAND)
        self.assertIn(f'href="{_HISTORY_URL}"', out)
        self.assertTrue(out.endswith("</a>)"), out)


class TestRenderHtmlLinkified(unittest.TestCase):

    def setUp(self):
        email_sender._branding_cache = {}
        email_sender._branding_cache_ts = 0.0

    def test_render_html_body_url_is_clickable_once(self):
        body = (
            "Здравствуйте, egorius!\n\n"
            "Ваша покупка зафиксирована.\n\n"
            "Магазин: aptekiplus.ru\n"
            "Сумма заказа: 264,30 ₽\n"
            "Статус: В ожидании\n\n"
            f"Отслеживайте статус в личном кабинете: {_HISTORY_URL}"
        )
        branding = {
            "brand_color": _BRAND,
            "text_color": "#ffffff",
            "logo_url": None,
            "signature": "",
        }
        with mock.patch.object(email_sender, "_get_branding", return_value=branding):
            html = email_sender._render_html("Новая покупка", body, "Савелло Клуб", 42)

        self.assertEqual(html.count(f'<a href="{_HISTORY_URL}"'), 1)
        # В теле не должно остаться неотлинкованного вхождения URL.
        self.assertNotIn(f": {_HISTORY_URL}<", html)
        self.assertNotIn(f": {_HISTORY_URL}</p>", html)


if __name__ == "__main__":
    unittest.main()
