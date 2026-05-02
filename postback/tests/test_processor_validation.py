"""
F-S3-04 webhook receiver — unix_timestamp sanity-валидация.

Регрессия на silent-fail: action_date=0 (unix-epoch) проходил через
`_convert_unix_timestamp` как строка "0", INSERT в MySQL DATETIME падал, но
webhook processing_status уже был установлен в 'ok' до insert'а — деньги
пропадали без алерта.

Источник плана: plans/sparkling-yawning-lamport.md §P0.2 (G7 + G9-bis TDD).
"""
import os
import sys
import time
import unittest

# Гарантируем, что postback/ в sys.path (тест может быть запущен из любого CWD).
_HERE = os.path.dirname(os.path.abspath(__file__))
_POSTBACK_ROOT = os.path.dirname(_HERE)
if _POSTBACK_ROOT not in sys.path:
    sys.path.insert(0, _POSTBACK_ROOT)

from worker.processor import (  # noqa: E402
    MIN_UNIX_TIMESTAMP,
    _validate_unix_timestamp_fields,
)


class TestMinTimestampConstant(unittest.TestCase):
    """G7 регрессия: floor должен быть строго 2020-01-01 UTC.

    Refund-webhooks от CPA-сетей приходят с задержкой 30-60 дней, потому
    floor нельзя ужесточать (например до now-1d) без рефанд-протокола.
    """

    def test_min_timestamp_is_2020_01_01_utc(self):
        # 1577836800 = datetime(2020, 1, 1, 0, 0, tzinfo=UTC).timestamp()
        self.assertEqual(MIN_UNIX_TIMESTAMP, 1577836800)


class TestUnixTimestampValidator(unittest.TestCase):
    """Pure unit тесты на `_validate_unix_timestamp_fields`."""

    # --- негативные кейсы (expected: rejected) ---

    def test_unix_epoch_zero_int_rejected(self):
        """action_date=0 (int) — главный F-S3-04 баг."""
        result = _validate_unix_timestamp_fields(
            {"action_date": 0, "uniq_id": "X-1"},
            {"action_date": "unix_timestamp"},
        )
        self.assertEqual(result, "action_date")

    def test_unix_epoch_zero_string_rejected(self):
        """action_date='0' (строка) — webhook'и часто шлют значения как str."""
        result = _validate_unix_timestamp_fields(
            {"action_date": "0"},
            {"action_date": "unix_timestamp"},
        )
        self.assertEqual(result, "action_date")

    def test_one_second_below_floor_rejected(self):
        """Граница MIN_UNIX_TIMESTAMP - 1 сек отбита (защита от boundary-bypass)."""
        result = _validate_unix_timestamp_fields(
            {"action_date": MIN_UNIX_TIMESTAMP - 1},
            {"action_date": "unix_timestamp"},
        )
        self.assertEqual(result, "action_date")

    def test_negative_timestamp_rejected(self):
        """Отрицательное значение (нонсенс) — rejected."""
        result = _validate_unix_timestamp_fields(
            {"action_date": -1},
            {"action_date": "unix_timestamp"},
        )
        self.assertEqual(result, "action_date")

    def test_returns_first_invalid_field_only(self):
        """Если несколько полей, возвращается имя первого invalid'а (deterministic order)."""
        result = _validate_unix_timestamp_fields(
            {"action_date": 0, "click_time": 0},
            {"action_date": "unix_timestamp", "click_time": "unix_timestamp"},
        )
        # действует order словаря (insertion order в Python 3.7+)
        self.assertIn(result, ("action_date", "click_time"))
        self.assertIsNotNone(result)

    # --- позитивные кейсы (expected: passed) ---

    def test_floor_boundary_accepted(self):
        """Граница MIN_UNIX_TIMESTAMP включительно проходит."""
        result = _validate_unix_timestamp_fields(
            {"action_date": MIN_UNIX_TIMESTAMP},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_30d_old_refund_accepted(self):
        """G7: refund-webhook 30 дней назад должен проходить."""
        ts = int(time.time()) - 30 * 86400
        result = _validate_unix_timestamp_fields(
            {"action_date": ts},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_60d_old_refund_accepted(self):
        """G7: long-tail refund 60 дней (CPA-сети шлют постбэки с задержкой)."""
        ts = int(time.time()) - 60 * 86400
        result = _validate_unix_timestamp_fields(
            {"action_date": ts},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_recent_timestamp_accepted(self):
        """Свежий webhook (now) проходит."""
        ts = int(time.time())
        result = _validate_unix_timestamp_fields(
            {"action_date": ts},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    # --- pass-through кейсы (валидатор не его дело) ---

    def test_missing_field_passes(self):
        """Отсутствие поля action_date в payload не его дело — caller отвечает за required."""
        result = _validate_unix_timestamp_fields(
            {"uniq_id": "X-1"},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_empty_string_passes(self):
        """Пустая строка пропускается — downstream insert_transaction обработает default."""
        result = _validate_unix_timestamp_fields(
            {"action_date": ""},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_none_value_passes(self):
        """None пропускается."""
        result = _validate_unix_timestamp_fields(
            {"action_date": None},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_already_formatted_datetime_string_passes(self):
        """Уже отформатированный datetime '2026-04-30 12:00:00' пропускается.

        Сети могут слать datetime-строкой; `_convert_unix_timestamp` тоже её
        пропускает (try/except ValueError). Не наше дело валидировать формат.
        """
        result = _validate_unix_timestamp_fields(
            {"action_date": "2026-04-30 12:00:00"},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    def test_iso_datetime_string_passes(self):
        """ISO 8601 строка тоже пропускается (downstream insert handles)."""
        result = _validate_unix_timestamp_fields(
            {"action_date": "2026-04-30T12:00:00Z"},
            {"action_date": "unix_timestamp"},
        )
        self.assertIsNone(result)

    # --- transforms config edge cases ---

    def test_no_transforms_dict_passes(self):
        """Network без field_transforms (пустой dict) — валидатор noop."""
        self.assertIsNone(
            _validate_unix_timestamp_fields({"action_date": 0}, {})
        )

    def test_none_transforms_passes(self):
        """transforms=None (отсутствие конфига) — валидатор noop."""
        self.assertIsNone(
            _validate_unix_timestamp_fields({"action_date": 0}, None)
        )

    def test_non_unix_transform_ignored(self):
        """Транзишены не-unix_timestamp не проверяются."""
        result = _validate_unix_timestamp_fields(
            {"some_field": 0},
            {"some_field": "uppercase"},  # гипотетический не-unix transform
        )
        self.assertIsNone(result)

    def test_mixed_transforms_only_unix_checked(self):
        """В смешанном transforms-конфиге проверяются ТОЛЬКО unix_timestamp поля."""
        result = _validate_unix_timestamp_fields(
            {"action_date": int(time.time()), "some_text": ""},
            {
                "action_date": "unix_timestamp",
                "some_text": "uppercase",
            },
        )
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
