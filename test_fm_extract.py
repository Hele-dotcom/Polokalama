"""Unit tests for the pure helper functions in fm_extract.py.

Stubs pyodbc and psycopg2 in sys.modules before import, since neither driver
is installed on a dev machine away from the extraction host.
"""

import sys
import types
import unittest


def _stub_module(name, **attrs):
    if name not in sys.modules:
        module = types.ModuleType(name)
        for key, value in attrs.items():
            setattr(module, key, value)
        sys.modules[name] = module
    return sys.modules[name]


_stub_module("pyodbc", Error=Exception, connect=lambda *a, **k: None)
_psycopg2 = _stub_module("psycopg2", connect=lambda *a, **k: None)
_psycopg2.extras = _stub_module("psycopg2.extras", execute_values=lambda *a, **k: None)

import fm_extract  # noqa: E402


class QuoteTests(unittest.TestCase):
    def test_wraps_in_double_quotes(self):
        self.assertEqual(fm_extract.quote("Table"), '"Table"')

    def test_escapes_embedded_double_quotes(self):
        self.assertEqual(fm_extract.quote('Weird"Name'), '"Weird""Name"')

    def test_preserves_case(self):
        self.assertEqual(fm_extract.quote("MixedCase"), '"MixedCase"')


class PgqTests(unittest.TestCase):
    def test_folds_to_lower_case(self):
        self.assertEqual(fm_extract.pgq("MyColumn"), '"mycolumn"')

    def test_escapes_embedded_double_quotes(self):
        self.assertEqual(fm_extract.pgq('Weird"Name'), '"weird""name"')


class BuildSelectTests(unittest.TestCase):
    def test_unbounded_has_no_predicate(self):
        sql = fm_extract.build_select("Tbl", ["A", "B"], "Modified", incremental=False)
        self.assertEqual(sql, 'SELECT "A", "B" FROM "Tbl"')

    def test_bounded_adds_watermark_predicate(self):
        sql = fm_extract.build_select("Tbl", ["A", "B"], "Modified", incremental=True)
        self.assertEqual(
            sql,
            'SELECT "A", "B" FROM "Tbl" WHERE "Modified" > ? AND "Modified" <= ?',
        )


if __name__ == "__main__":
    unittest.main()
