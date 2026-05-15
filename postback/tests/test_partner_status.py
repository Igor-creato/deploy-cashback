"""
Partner-status postback (Advcake v14): worker должен сохранять raw payload
с event_type='partner_status' и пропускать transaction-creation pipeline.
Плагин-side обработчик `Cashback_Advcake_Partner_Status_Sync` подберёт row.

Также проверяем defensive column-presence check в save_raw_webhook:
если плагин-миграция v14 ещё не отработала и колонки event_type нет —
fallback на старую SQL (без event_type) + WARN в лог.
"""
import json
import logging
import os
import sys
import unittest
from contextlib import contextmanager
from unittest.mock import MagicMock, patch

_HERE = os.path.dirname(os.path.abspath(__file__))
_POSTBACK_ROOT = os.path.dirname(_HERE)
if _POSTBACK_ROOT not in sys.path:
    sys.path.insert(0, _POSTBACK_ROOT)


def _make_mock_conn(rowcount: int = 1, lastrowid: int = 42, fetchone_return=None):
    """Возвращает (fake_get_conn, executed_sqls, executed_params)."""
    executed_sqls: list[str] = []
    executed_params: list = []

    cursor = MagicMock()
    cursor.rowcount = rowcount
    cursor.lastrowid = lastrowid

    def _execute(sql, params=None):
        executed_sqls.append(sql)
        executed_params.append(params)

    cursor.execute = MagicMock(side_effect=_execute)
    cursor.fetchone = MagicMock(return_value=fetchone_return)

    cursor_cm = MagicMock()
    cursor_cm.__enter__ = MagicMock(return_value=cursor)
    cursor_cm.__exit__ = MagicMock(return_value=False)

    conn_obj = MagicMock()
    conn_obj.cursor = MagicMock(return_value=cursor_cm)
    conn_obj.commit = MagicMock()

    @contextmanager
    def fake_get_conn():
        yield conn_obj

    return fake_get_conn, executed_sqls, executed_params


def _reset_event_type_cache():
    """Сбрасываем TTL-cache _has_event_type_column между тестами."""
    import app.db
    app.db._event_type_column_cache = (0.0, False)


class TestSaveRawWebhookEventType(unittest.TestCase):
    """save_raw_webhook должен поддерживать event_type с defensive column check."""

    def setUp(self):
        _reset_event_type_cache()

    def test_default_event_type_is_transaction(self):
        """Без явного event_type — INSERT идёт с 'transaction' (если колонка есть)."""
        fake_get_conn, sqls, params = _make_mock_conn(
            rowcount=1, lastrowid=42, fetchone_return={"1": 1}
        )
        with patch("app.db.get_conn", fake_get_conn):
            from app.db import save_raw_webhook
            result = save_raw_webhook('{"k":"v"}', "advcake")
        self.assertEqual(result, 42)

        # Первый exec — INFORMATION_SCHEMA check; второй — INSERT.
        self.assertGreaterEqual(len(sqls), 2)
        insert_sql = sqls[-1].upper()
        self.assertIn("EVENT_TYPE", insert_sql, "INSERT должен содержать колонку event_type")
        self.assertEqual(params[-1][2], "transaction")

    def test_partner_status_event_type_passes_through(self):
        """event_type='partner_status' попадает в payload INSERT'а."""
        fake_get_conn, sqls, params = _make_mock_conn(
            rowcount=1, lastrowid=99, fetchone_return={"1": 1}
        )
        with patch("app.db.get_conn", fake_get_conn):
            from app.db import save_raw_webhook
            result = save_raw_webhook(
                '{"offer_id":"6","status":"stopped"}',
                "advcake",
                event_type="partner_status",
            )
        self.assertEqual(result, 99)
        self.assertEqual(params[-1][2], "partner_status")

    def test_falls_back_when_column_missing(self):
        """Колонка event_type отсутствует → fallback на старый INSERT без event_type."""
        # fetchone возвращает None — колонки нет.
        fake_get_conn, sqls, params = _make_mock_conn(
            rowcount=1, lastrowid=42, fetchone_return=None
        )
        with patch("app.db.get_conn", fake_get_conn):
            from app.db import save_raw_webhook
            result = save_raw_webhook('{"k":"v"}', "advcake")
        self.assertEqual(result, 42)
        insert_sql = sqls[-1].upper()
        self.assertNotIn("EVENT_TYPE", insert_sql, "Fallback не должен упоминать event_type")
        # Параметры fallback'а: (payload, slug) — без event_type.
        self.assertEqual(len(params[-1]), 2)

    def test_warns_when_partner_status_called_without_column(self):
        """event_type='partner_status' без колонки в БД → WARN в лог."""
        fake_get_conn, _sqls, _params = _make_mock_conn(
            rowcount=1, lastrowid=42, fetchone_return=None
        )
        with patch("app.db.get_conn", fake_get_conn):
            from app.db import save_raw_webhook
            with self.assertLogs("webhook.db", level="WARNING") as logs:
                save_raw_webhook('{}', "advcake", event_type="partner_status")
        joined = " ".join(logs.output)
        self.assertIn("partner_status", joined)
        self.assertIn("plugin v14 migration", joined)


class TestProcessMessagePartnerStatusBranch(unittest.TestCase):
    """process_message должен распознавать event_type=partner_status и не лезть
    в transaction-pipeline."""

    def setUp(self):
        _reset_event_type_cache()

    def _build_message(self, event_type: str = "partner_status") -> str:
        params = {
            "event_type": event_type,
            "offer_id": "6",
            "status": "stopped",
        }
        return json.dumps({"slug": "advcake", "params": params, "received_at": 1700000000})

    def test_partner_status_calls_save_raw_webhook_with_event_type(self):
        from worker.processor import process_message

        with patch("worker.processor.get_network", return_value={"name": "Advcake"}), \
             patch("worker.processor.save_raw_webhook", return_value=10) as mock_save, \
             patch("worker.processor.transaction_exists_for_action") as mock_tx_exists, \
             patch("worker.processor.insert_transaction") as mock_insert:
            process_message(self._build_message())

        mock_save.assert_called_once()
        # Проверяем что вызвался с keyword event_type='partner_status'
        kwargs = mock_save.call_args.kwargs
        self.assertEqual(kwargs.get("event_type"), "partner_status")

        # transaction-pipeline функции НЕ должны быть вызваны.
        mock_tx_exists.assert_not_called()
        mock_insert.assert_not_called()

    def test_partner_status_case_insensitive(self):
        from worker.processor import process_message

        with patch("worker.processor.get_network", return_value={"name": "Advcake"}), \
             patch("worker.processor.save_raw_webhook", return_value=11) as mock_save, \
             patch("worker.processor.transaction_exists_for_action") as mock_tx_exists:
            process_message(self._build_message(event_type="Partner_Status"))

        mock_save.assert_called_once()
        self.assertEqual(mock_save.call_args.kwargs.get("event_type"), "partner_status")
        mock_tx_exists.assert_not_called()

    def test_partner_status_duplicate_returns_silently(self):
        """save_raw_webhook вернул None (дубль) → ничего не падает, transaction code не дёргается."""
        from worker.processor import process_message

        with patch("worker.processor.get_network", return_value={"name": "Advcake"}), \
             patch("worker.processor.save_raw_webhook", return_value=None), \
             patch("worker.processor.transaction_exists_for_action") as mock_tx_exists, \
             patch("worker.processor.insert_transaction") as mock_insert:
            process_message(self._build_message())

        mock_tx_exists.assert_not_called()
        mock_insert.assert_not_called()

    def test_transaction_postback_unaffected_by_event_type_branch(self):
        """Без event_type=partner_status — обычный transaction pipeline должен дёрнуть mapping и далее."""
        from worker.processor import process_message

        msg = json.dumps({
            "slug": "advcake",
            "params": {
                "click_id": "11111111111111111111111111111111",
                "user_id": "22222222222222222222222222222222",
                "uniq_id": "test-action-1",
                "order_number": "ORD-1",
                "comission": "42",
                "sum_order": "700",
                "order_status": "2",
                "currency": "RUB",
            },
            "received_at": 1700000000,
        })

        network_cfg = {
            "name": "Advcake",
            "mapping": {
                "click_id": "click_id",
                "user_id": "user_id",
                "uniq_id": "uniq_id",
                "order_number": "order_number",
                "comission": "comission",
                "sum_order": "sum_order",
                "order_status": "order_status",
                "currency": "currency",
            },
            "status_mapping": {"1": "waiting", "2": "completed", "3": "declined"},
        }
        # transaction_exists_for_action возвращает True → ранний skip, чтобы не
        # лезть в check_click_id_and_get_user. Это докажет что мы прошли по
        # transaction-pipeline (а не на partner_status branch). uniq_id
        # ('test-action-1') непустой → universal resolver = native passthrough
        # (dedup_identity отсутствует в network_cfg → None → legacy native).
        with patch("worker.processor.get_network", return_value=network_cfg), \
             patch("worker.processor.save_raw_webhook", return_value=42) as mock_save, \
             patch("worker.processor.transaction_exists_for_action", return_value=True) as mock_tx_exists, \
             patch("worker.processor.update_webhook_processing_status"):
            process_message(msg)

        # save_raw_webhook вызван БЕЗ event_type kwarg (default).
        self.assertNotIn("event_type", mock_save.call_args.kwargs)
        # И transaction_exists_for_action вызван — мы прошли по transaction-pipeline.
        mock_tx_exists.assert_called_once()


if __name__ == "__main__":
    unittest.main()
