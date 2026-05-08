"""
F-S1-001 webhook receiver — атомарный upsert вместо DELETE+INSERT IGNORE.

Регрессия на race condition: при retryable processing_status (user_mismatch /
click_not_found / error) старая логика делала SELECT → DELETE → COMMIT → INSERT
IGNORE через два TX. Между DELETE и INSERT параллельный воркер мог встать на
INSERT первым → первый воркер получал rowcount=0 и возвращал None, теряя
postback. Также между DELETE и UPDATE-status-from-another-worker терялась
связь webhook_id, нарушая аудит-цепочку.

Fix: одна `INSERT ... ON DUPLICATE KEY UPDATE` с условным IF на
processing_status — single-statement atomic upsert.
"""

import os
import sys
import unittest
from unittest.mock import MagicMock, patch
from contextlib import contextmanager

# Гарантируем postback/ в sys.path.
_HERE = os.path.dirname(os.path.abspath(__file__))
_POSTBACK_ROOT = os.path.dirname(_HERE)
if _POSTBACK_ROOT not in sys.path:
    sys.path.insert(0, _POSTBACK_ROOT)


def _make_mock_conn(rowcount: int, lastrowid: int):
    """Build a (conn, executed_sqls) pair where conn behaves like a pymysql
    Connection used in `with get_conn() as conn` + `with conn.cursor() as cur`.
    """
    executed_sqls: list[str] = []
    cursor = MagicMock()
    cursor.rowcount = rowcount
    cursor.lastrowid = lastrowid
    cursor.execute = MagicMock(side_effect=lambda sql, params=None: executed_sqls.append(sql))

    cursor_cm = MagicMock()
    cursor_cm.__enter__ = MagicMock(return_value=cursor)
    cursor_cm.__exit__ = MagicMock(return_value=False)

    conn_obj = MagicMock()
    conn_obj.cursor = MagicMock(return_value=cursor_cm)
    conn_obj.commit = MagicMock()

    @contextmanager
    def fake_get_conn():
        yield conn_obj

    return fake_get_conn, executed_sqls


class TestSaveRawWebhookAtomicity(unittest.TestCase):
    """F-S1-001: save_raw_webhook должен использовать atomic upsert, не DELETE+INSERT."""

    def _run(self, rowcount: int, lastrowid: int):
        fake_get_conn, sqls = _make_mock_conn(rowcount, lastrowid)
        with patch("app.db.get_conn", fake_get_conn):
            from app.db import save_raw_webhook
            result = save_raw_webhook('{"k":"v"}', "adm")
        return result, sqls

    def test_no_delete_statement_executed(self):
        """save_raw_webhook не делает DELETE — атомарный upsert вместо TOCTOU SELECT+DELETE+INSERT."""
        _result, sqls = self._run(rowcount=1, lastrowid=42)
        joined = " ".join(sqls).upper()
        self.assertNotIn("DELETE", joined,
                         f"DELETE не должен использоваться. Executed SQLs: {sqls}")

    def test_uses_on_duplicate_key_update(self):
        """save_raw_webhook использует INSERT … ON DUPLICATE KEY UPDATE."""
        _result, sqls = self._run(rowcount=1, lastrowid=42)
        joined = " ".join(sqls).upper()
        self.assertIn("INSERT INTO", joined)
        self.assertIn("ON DUPLICATE KEY UPDATE", joined)

    def test_single_sql_statement_no_separate_select(self):
        """Атомарный upsert = ровно один execute() вызов на всю операцию (без SELECT-первого)."""
        _result, sqls = self._run(rowcount=1, lastrowid=42)
        self.assertEqual(len(sqls), 1,
                         f"Ожидался 1 SQL (atomic upsert), получено {len(sqls)}: {sqls}")

    def test_returns_id_on_new_insert_rowcount_1(self):
        """rowcount=1 = INSERT новой строки → возвращаем id для обработки."""
        result, _sqls = self._run(rowcount=1, lastrowid=42)
        self.assertEqual(result, 42)

    def test_returns_id_on_rearmed_retry_rowcount_2(self):
        """rowcount=2 = UPDATE сбросил retryable status → возвращаем id для повторной обработки."""
        result, _sqls = self._run(rowcount=2, lastrowid=99)
        self.assertEqual(result, 99)

    def test_returns_none_on_no_op_rowcount_0(self):
        """rowcount=0 = строка существует с status='ok'/NULL, IF не дал изменить → skip."""
        result, _sqls = self._run(rowcount=0, lastrowid=42)
        self.assertIsNone(result)

    def test_status_filter_only_retryable_in_update(self):
        """UPDATE-часть переключает status в NULL только для retryable (user_mismatch / click_not_found / error)."""
        _result, sqls = self._run(rowcount=2, lastrowid=42)
        joined = " ".join(sqls)
        # Все три retryable статуса должны быть упомянуты в IF/CASE условии.
        self.assertIn("user_mismatch", joined)
        self.assertIn("click_not_found", joined)
        self.assertIn("error", joined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
