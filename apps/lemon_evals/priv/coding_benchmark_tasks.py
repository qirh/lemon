"""Harder, self-contained stdlib coding tasks for the live benchmark.

Verifiers belong to the runner, not to the disposable repositories. Each task
starts with a real behavioral defect; the embedded READMEs define its contract.
"""

import hashlib
import json
import random
from textwrap import dedent


def _source(text):
    return dedent(text).lstrip("\n")


def additional_tasks(task):
    """Build four fixtures using the runner's task(name, prompt, files, verify)."""
    return [
        _inventory_task(task),
        _policy_task(task),
        _migration_task(task),
        _log_task(task),
    ]


def _inventory_task(task):
    files = {
        "README.md": _source('''
            # Stockroom
            `python -m stockroom.cli --db stock.db add SKU QUANTITY` adds stock;
            `list` prints SKU-sorted JSON objects with sku and quantity fields.
            Keep those existing commands and their output unchanged.

            Implement atomic, durable order reservations through all five existing
            layers: validation.py, domain.py, repository.py, service.py, cli.py.
            Add standard-library unittest regression tests, including a legacy DB.

            Public contracts:
            * Stock(sku, quantity, reserved=0) has available = quantity - reserved.
            * Repository.stock(sku) returns Stock; missing SKU raises KeyError.
              Existing databases have only stocks(sku TEXT PRIMARY KEY,
              quantity INTEGER NOT NULL). Upgrade on open, retaining all stock.
            * Service.reserve(order_id, lines) accepts a nonblank string order ID
              and a nonempty list of {"sku": string, "quantity": positive int}.
              Reject bool quantities, nonintegers, blank/nonstring IDs or SKUs,
              missing fields, and non-list lines with ValueError. Strip surrounding
              whitespace on IDs/SKUs. Aggregate duplicate SKUs before checking stock.
            * Return {"order_id": normalized_id, "items": [{"sku": ..., "quantity":
              aggregated_quantity}, ...]}, sorted by SKU. Persist the order and
              each stock's reserved quantity in ONE transaction. Unknown SKUs raise
              KeyError; insufficient available stock raises ValueError. Any failure
              leaves both stock and orders unchanged.
            * Replaying the same normalized order and aggregated quantities is
              idempotent, even if input order/duplication differs and after reopening
              the database. Reusing its ID for different quantities raises ValueError.
              Check replay before checking current availability. Separate Repository
              instances must observe one another's committed reservations.
            * `reserve ORDER SKU:QUANTITY [SKU:QUANTITY ...]` uses Service.reserve
              and prints that result as JSON. Validation, unknown SKU and stock
              errors print one diagnostic to stderr, return status 2, and no stdout
              or traceback. Existing add/list success behavior remains unchanged.
            Repository.close() releases its SQLite connection. No external packages.
        '''),
        "stockroom/__init__.py": "",
        "stockroom/validation.py": _source('''
            def sku(value):
                if not isinstance(value, str) or not value.strip():
                    raise ValueError("SKU must be a nonblank string")
                return value.strip()


            def positive_quantity(value):
                if type(value) is not int or value <= 0:
                    raise ValueError("quantity must be a positive integer")
                return value
        '''),
        "stockroom/domain.py": _source('''
            from dataclasses import dataclass


            @dataclass(frozen=True)
            class Stock:
                sku: str
                quantity: int
        '''),
        "stockroom/repository.py": _source('''
            import sqlite3
            from .domain import Stock


            class Repository:
                def __init__(self, path):
                    self.connection = sqlite3.connect(path)
                    self.connection.execute(
                        "CREATE TABLE IF NOT EXISTS stocks "
                        "(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL)"
                    )
                    self.connection.commit()

                def add(self, sku, quantity):
                    with self.connection:
                        self.connection.execute(
                            "INSERT INTO stocks(sku, quantity) VALUES (?, ?) "
                            "ON CONFLICT(sku) DO UPDATE SET quantity=quantity+excluded.quantity",
                            (sku, quantity),
                        )
                    return self.stock(sku)

                def stock(self, sku):
                    row = self.connection.execute(
                        "SELECT sku, quantity FROM stocks WHERE sku=?", (sku,)
                    ).fetchone()
                    if row is None:
                        raise KeyError(sku)
                    return Stock(*row)

                def all(self):
                    return [Stock(*row) for row in self.connection.execute(
                        "SELECT sku, quantity FROM stocks ORDER BY sku"
                    )]

                def close(self):
                    self.connection.close()
        '''),
        "stockroom/service.py": _source('''
            from . import validation


            class Service:
                def __init__(self, repository):
                    self.repository = repository

                def add_stock(self, sku, quantity):
                    return self.repository.add(
                        validation.sku(sku), validation.positive_quantity(quantity)
                    )

                def inventory(self):
                    return self.repository.all()
        '''),
        "stockroom/cli.py": _source('''
            import argparse
            import json
            from .repository import Repository
            from .service import Service


            def main(argv=None):
                parser = argparse.ArgumentParser()
                parser.add_argument("--db", required=True)
                commands = parser.add_subparsers(dest="command", required=True)
                add = commands.add_parser("add")
                add.add_argument("sku")
                add.add_argument("quantity", type=int)
                commands.add_parser("list")
                args = parser.parse_args(argv)
                repository = Repository(args.db)
                service = Service(repository)
                try:
                    if args.command == "add":
                        stock = service.add_stock(args.sku, args.quantity)
                        result = {"sku": stock.sku, "quantity": stock.quantity}
                    else:
                        result = [{"sku": row.sku, "quantity": row.quantity}
                                  for row in service.inventory()]
                    print(json.dumps(result, sort_keys=True))
                    return 0
                finally:
                    repository.close()


            if __name__ == "__main__":
                raise SystemExit(main())
        '''),
        "test_stockroom.py": _source('''
            import tempfile
            import unittest
            from pathlib import Path
            from stockroom.repository import Repository
            from stockroom.service import Service


            class StockroomTests(unittest.TestCase):
                def test_add_and_list(self):
                    with tempfile.TemporaryDirectory() as directory:
                        repository = Repository(Path(directory) / "stock.db")
                        try:
                            service = Service(repository)
                            service.add_stock(" B ", 2)
                            service.add_stock("B", 3)
                            service.add_stock("A", 1)
                            self.assertEqual([(s.sku, s.quantity) for s in service.inventory()],
                                             [("A", 1), ("B", 5)])
                            with self.assertRaises(ValueError):
                                service.add_stock("A", True)
                        finally:
                            repository.close()
        '''),
    }
    verify = _source('''
        import json
        import sqlite3
        import subprocess
        import sys
        import tempfile
        from pathlib import Path
        from stockroom.domain import Stock
        from stockroom.repository import Repository
        from stockroom.service import Service

        def raises(kind, operation):
            try:
                operation()
            except kind:
                return
            raise AssertionError("expected " + kind.__name__)

        assert Stock("A", 9, 4).available == 5
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.db"
            with sqlite3.connect(path) as connection:
                connection.execute("CREATE TABLE stocks(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL)")
                connection.executemany("INSERT INTO stocks VALUES (?, ?)", [("A", 10), ("B", 4)])
            repository = Repository(path)
            service = Service(repository)
            assert repository.stock("A").reserved == 0
            expected = {"order_id": "one", "items": [{"sku": "A", "quantity": 5}, {"sku": "B", "quantity": 2}]}
            assert service.reserve(" one ", [{"sku": "B", "quantity": 2}, {"sku": " A ", "quantity": 2}, {"sku": "A", "quantity": 3}]) == expected
            assert (repository.stock("A").quantity, repository.stock("A").reserved, repository.stock("A").available) == (10, 5, 5)
            raises(ValueError, lambda: service.reserve("one", [{"sku": "A", "quantity": 4}]))
            raises(ValueError, lambda: service.reserve("two", [{"sku": "A", "quantity": 4}, {"sku": "B", "quantity": 3}]))
            raises(KeyError, lambda: service.reserve("two", [{"sku": "A", "quantity": 1}, {"sku": "missing", "quantity": 1}]))
            assert repository.stock("A").reserved == 5
            assert repository.stock("B").reserved == 2
            for bad_id in [None, " ", 7]:
                raises(ValueError, lambda: service.reserve(bad_id, [{"sku": "A", "quantity": 1}]))
            for lines in [None, {}, (), [], [{}], [{"sku": "A"}], [{"sku": " ", "quantity": 1}], [{"sku": 3, "quantity": 1}]]:
                raises(ValueError, lambda: service.reserve("bad", lines))
            for quantity in [True, False, 0, -1, 1.5, "2", None]:
                raises(ValueError, lambda: service.reserve("bad", [{"sku": "A", "quantity": quantity}]))
            raises(ValueError, lambda: service.reserve("duplicate-overflow", [{"sku": "A", "quantity": 3}, {"sku": "A", "quantity": 3}]))
            assert repository.stock("A").reserved == 5
            second = Repository(path)
            try:
                assert second.stock("A").reserved == 5
                Service(second).reserve("two", [{"sku": "A", "quantity": 5}])
                assert repository.stock("A").available == 0
                assert service.reserve("one", list(reversed(expected["items"]))) == expected
                raises(ValueError, lambda: service.reserve("third", [{"sku": "A", "quantity": 1}]))
                service.add_stock("A", 2)
                assert second.stock("A").available == 2
                assert service.reserve("third", [{"sku": "A", "quantity": 1}])["order_id"] == "third"
            finally:
                second.close()
                repository.close()
            reopened = Repository(path)
            try:
                assert Service(reopened).reserve("one", expected["items"]) == expected
                assert reopened.stock("A").reserved == 11
            finally:
                reopened.close()

            def cli(*args):
                return subprocess.run([sys.executable, "-m", "stockroom.cli", "--db", str(path), *args], capture_output=True, text=True)
            result = cli("reserve", "cli", "B:1", "B:1")
            assert result.returncode == 0, result.stderr
            assert json.loads(result.stdout) == {"order_id": "cli", "items": [{"sku": "B", "quantity": 2}]}
            for args in [("reserve", "bad", "B:1"), ("reserve", "bad", "missing:1"), ("reserve", "bad", "A:no"), ("reserve", "bad", "A:0")]:
                result = cli(*args)
                assert result.returncode == 2 and result.stdout == "" and result.stderr.strip()
                assert "Traceback" not in result.stderr
            result = cli("list")
            assert result.returncode == 0
            assert json.loads(result.stdout) == [{"sku": "A", "quantity": 12}, {"sku": "B", "quantity": 4}]
            result = cli("add", "C", "3")
            assert result.returncode == 0 and json.loads(result.stdout) == {"sku": "C", "quantity": 3}
    ''')
    return task(
        "inventory_atomic_reservations",
        "Implement the atomic reservation feature described in README.md across the existing stockroom layers. Preserve legacy add/list behavior and upgrade existing databases. Add unittest regression coverage for rollback, validation, persistence, and idempotency.",
        files,
        verify,
    )


def _policy_task(task):
    files = {
        "README.md": _source('''
            # Policy checks that fail depending on test order
            Run `python repro.py --seed 0` and compare other seeds or individual
            test_policy.PolicyTests methods. Tests must remain enabled and their
            assertions must not be weakened. Fix production code, not the runner.
            Add regression tests for the actual causes.

            Engine(config) snapshots a mapping of policy names to {allow: [roles],
            deny: [roles]}; later caller mutation must not change that engine.
            Engine.allows(policy, role, extra_roles=()) returns a bool. An unknown
            policy denies everything. Extra roles grant access ONLY on that call,
            and explicit deny always wins, including over extra_roles.
            Policies with the same name in different engines must remain isolated.
            Compilation may be cached, but its identity must include all semantic
            policy inputs, and evaluation must never mutate compiled state. Do not
            disable caching or clear global caches between calls/tests to hide leaks.
            compile_policy(name, spec) remains public and must return the identical
            cached object for semantically equivalent inputs (role ordering and
            duplicate roles are irrelevant). No dependencies are needed.
        '''),
        "policy.py": _source('''
            from copy import deepcopy

            _CACHE = {}


            def compile_policy(name, spec):
                if name not in _CACHE:
                    _CACHE[name] = {
                        "allow": set(spec.get("allow", [])),
                        "deny": set(spec.get("deny", [])),
                    }
                return _CACHE[name]


            class Engine:
                def __init__(self, config):
                    self.config = deepcopy(config)

                def allows(self, policy, role, extra_roles=()):
                    if policy not in self.config:
                        return False
                    compiled = compile_policy(policy, self.config[policy])
                    allowed = compiled["allow"]
                    allowed.update(extra_roles)
                    return role in allowed and role not in compiled["deny"]
        '''),
        "test_policy.py": _source('''
            import unittest
            from policy import Engine, compile_policy


            class PolicyTests(unittest.TestCase):
                def setUp(self):
                    self.engine = Engine({"edit": {"allow": ["reader"], "deny": ["blocked"]}})

                def test_temporary_grant(self):
                    self.assertTrue(self.engine.allows("edit", "writer", ["writer"]))

                def test_default_denies_writer(self):
                    self.assertFalse(self.engine.allows("edit", "writer"))

                def test_other_tenant(self):
                    other = Engine({"edit": {"allow": ["writer"], "deny": ["reader"]}})
                    self.assertTrue(other.allows("edit", "writer"))
                    self.assertFalse(other.allows("edit", "reader"))

                def test_deny_wins(self):
                    self.assertFalse(self.engine.allows("edit", "blocked", ["blocked"]))

                def test_unknown(self):
                    self.assertFalse(self.engine.allows("unknown", "writer", ["writer"]))

                def test_snapshot(self):
                    config = {"snapshot": {"allow": ["one"]}}
                    engine = Engine(config)
                    config["snapshot"]["allow"].append("two")
                    self.assertFalse(engine.allows("snapshot", "two"))
                    self.assertTrue(engine.allows("snapshot", "one"))
        '''),
        "repro.py": _source('''
            import argparse
            import random
            import unittest


            def flatten(suite):
                for item in suite:
                    if isinstance(item, unittest.TestSuite):
                        yield from flatten(item)
                    else:
                        yield item


            def main():
                parser = argparse.ArgumentParser()
                parser.add_argument("--seed", type=int, default=0)
                args = parser.parse_args()
                cases = list(flatten(unittest.defaultTestLoader.discover(".", pattern="test*.py")))
                random.Random(args.seed).shuffle(cases)
                result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(cases))
                return 0 if result.wasSuccessful() else 1


            if __name__ == "__main__":
                raise SystemExit(main())
        '''),
    }
    verify = _source('''
        import itertools
        import os
        import subprocess
        import sys
        from policy import Engine, compile_policy

        first = compile_policy("canonical", {"allow": ["b", "a", "a"], "deny": ["z"]})
        second = compile_policy("canonical", {"deny": ["z", "z"], "allow": ["a", "b"]})
        assert first is second, "semantic compilation cache was removed"
        for order in itertools.permutations(range(3)):
            engines = [Engine({"shared": spec}) for spec in [
                {"allow": ["a"], "deny": ["x"]},
                {"allow": ["b"], "deny": ["a"]},
                {"allow": [], "deny": ["b"]},
            ]]
            allowed = [{"a"}, {"b"}, set()]
            denied = [{"x"}, {"a"}, {"b"}]
            for index in order:
                engine = engines[index]
                for role in ["a", "b", "x", "temporary"]:
                    assert engine.allows("shared", role) == (role in allowed[index] and role not in denied[index])
                    assert engine.allows("shared", role, [role]) == (role not in denied[index])
                    assert engine.allows("shared", role) == (role in allowed[index] and role not in denied[index])
                    assert engine.allows("missing", role, [role]) is False
            for index in reversed(order):
                assert engines[index].allows("shared", "temporary") is False
        config = {"before": {"allow": ["yes"], "deny": []}}
        engine = Engine(config)
        config["before"]["allow"].clear()
        config["before"]["deny"].append("yes")
        assert engine.allows("before", "yes") is True
        assert Engine(config).allows("before", "yes") is False
        for seed in range(8):
            environment = dict(os.environ, PYTHONHASHSEED=str(seed + 1))
            result = subprocess.run([sys.executable, "repro.py", "--seed", str(seed)], env=environment, capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
        # Explicit opposite orders also exercise the original tests, independent of repro.py.
        names = ["temporary_grant", "default_denies_writer", "other_tenant", "deny_wins", "unknown", "snapshot"]
        for order in [names, list(reversed(names)), names[2:] + names[:2]]:
            result = subprocess.run([sys.executable, "-m", "unittest", *["test_policy.PolicyTests.test_" + name for name in order]], capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
    ''')
    return task(
        "order_dependent_policy_cache",
        "Diagnose and fix the reproducibly order-dependent policy tests. Use repro.py with multiple seeds, preserve caching and all existing assertions, and add regression tests. README.md defines isolation, deny precedence, snapshot, and per-call grant semantics.",
        files,
        verify,
    )


def _migration_task(task):
    files = {
        "README.md": _source('''
            # Local shelf dependency upgrade
            Migrate export.py, lookup.py and manifest.py from vendor.shelf_v1 to
            vendor.shelf_v2. Delete vendor/shelf_v1.py after migrating every consumer;
            do not add aliases, compatibility shims, or change the v2 implementation.
            Both versions are vendored; no installation or network access is needed.
            Add unittest regression tests and update this README's usage notes.

            The new Store(records) accepts an iterable of record dictionaries.
            Regular records contain key, value, optional deleted and etag fields;
            {"checkpoint": true} records model empty provider partitions.
            Store.session() is a context manager. Session.scan(*, prefix="",
            cursor=None, page_size=2) returns Page(entries, next_cursor). Entries
            contain key, UTF-8 JSON payload bytes, etag and deleted. The opaque
            cursor MUST be passed unchanged; only None means end, even if entries
            is empty. Tombstones consume page space but are not exported. A session
            must be open for scan/read; always close it, including on decoding errors.
            Session.read(key) raises MissingKey for missing/deleted keys; a stored
            JSON null is present, and must not be confused with absence.

            Preserve these application APIs, now accepting shelf_v2.Store:
            * export_records(store, prefix="", page_size=2): return all live matching
              {"key": key, "value": decoded_value} records, sorted by key. Respect
              caller page_size and prefix, traverse empty pages, and do not leak
              tombstones or metadata into the result.
            * lookup_value(store, key, default=None): decode a present value; return
              default ONLY for MissingKey. Preserve false, zero, empty strings and
              JSON null. Decode errors must propagate as ValueError.
            * build_manifest(store, prefix=""): {"count": live_count, "keys": sorted
              live_keys, "total_bytes": sum of len(json.dumps(value, ensure_ascii=False,
              sort_keys=True, separators=(",", ":")).encode("utf-8")) over live values}.
              This is canonical JSON byte size, not Python repr or provider payload
              size. It must handle all JSON value types. Do not bypass sessions to
              read private Store fields.
        '''),
        "vendor/__init__.py": "",
        "vendor/shelf_v1.py": _source('''
            def scan(store, prefix="", offset=0, limit=2):
                rows = [row for row in store._records if "key" in row
                        and row["key"].startswith(prefix) and not row.get("deleted")]
                page = rows[offset:offset + limit]
                following = offset + limit if offset + limit < len(rows) else None
                return {"items": [{"key": row["key"], "value": row["value"]} for row in page],
                        "next": following}


            def get(store, key):
                for row in store._records:
                    if row.get("key") == key and not row.get("deleted"):
                        return row["value"]
                return None
        '''),
        "vendor/shelf_v2.py": _source('''
            """Vendored provider: treat as immutable during the migration."""
            import json
            from copy import deepcopy
            from dataclasses import dataclass


            class MissingKey(LookupError):
                pass


            @dataclass(frozen=True)
            class Entry:
                key: str
                payload: bytes
                etag: str
                deleted: bool


            @dataclass(frozen=True)
            class Page:
                entries: tuple
                next_cursor: object


            class Store:
                def __init__(self, records):
                    self._records = deepcopy(list(records))
                    self.active_sessions = 0
                    self.scan_sizes = []

                def session(self):
                    return Session(self)


            class Session:
                def __init__(self, store):
                    self.store = store
                    self.open = False

                def __enter__(self):
                    if self.open:
                        raise RuntimeError("session already open")
                    self.open = True
                    self.store.active_sessions += 1
                    return self

                def __exit__(self, *exc):
                    self.open = False
                    self.store.active_sessions -= 1

                def _require_open(self):
                    if not self.open:
                        raise RuntimeError("session is closed")

                def _entry(self, row):
                    payload = row.get("raw_payload")
                    if payload is None:
                        payload = json.dumps(row.get("value"), ensure_ascii=False).encode("utf-8")
                    return Entry(row["key"], payload, row.get("etag", "etag-1"), bool(row.get("deleted")))

                def scan(self, *, prefix="", cursor=None, page_size=2):
                    self._require_open()
                    if type(page_size) is not int or page_size <= 0:
                        raise ValueError("page_size must be a positive integer")
                    self.store.scan_sizes.append(page_size)
                    rows = [row for row in self.store._records
                            if row.get("checkpoint") or row["key"].startswith(prefix)]
                    if cursor is None:
                        start = 0
                    elif isinstance(cursor, str) and cursor.startswith("shelf@"):
                        start = int(cursor[6:], 16)
                    else:
                        raise ValueError("opaque cursor required")
                    end = start + page_size
                    entries = tuple(self._entry(row) for row in rows[start:end] if not row.get("checkpoint"))
                    following = "shelf@%x" % end if end < len(rows) else None
                    return Page(entries, following)

                def read(self, key):
                    self._require_open()
                    for row in self.store._records:
                        if row.get("key") == key:
                            if row.get("deleted"):
                                break
                            return self._entry(row)
                    raise MissingKey(key)
        '''),
        "export.py": _source('''
            from vendor.shelf_v1 import scan


            def export_records(store, prefix="", page_size=2):
                offset = 0
                result = []
                while True:
                    page = scan(store, prefix, offset, page_size)
                    result.extend(page["items"])
                    if page["next"] is None:
                        return sorted(result, key=lambda row: row["key"])
                    offset = page["next"]
        '''),
        "lookup.py": _source('''
            from vendor.shelf_v1 import get


            def lookup_value(store, key, default=None):
                return get(store, key) or default
        '''),
        "manifest.py": _source('''
            from vendor.shelf_v1 import scan


            def build_manifest(store, prefix=""):
                page = scan(store, prefix, 0, 100)
                rows = sorted(page["items"], key=lambda row: row["key"])
                return {"count": len(rows), "keys": [row["key"] for row in rows],
                        "total_bytes": sum(len(str(row["value"])) for row in rows)}
        '''),
        "test_export.py": _source('''
            import unittest
            from export import export_records
            from lookup import lookup_value
            from vendor.shelf_v2 import Store


            class ExportTests(unittest.TestCase):
                def test_basic(self):
                    store = Store([{"key": "b", "value": {"n": 2}}, {"key": "a", "value": {"n": 1}}])
                    self.assertEqual(export_records(store), [{"key": "a", "value": {"n": 1}}, {"key": "b", "value": {"n": 2}}])
                    self.assertEqual(lookup_value(store, "absent", "fallback"), "fallback")
        '''),
    }
    verify = _source('''
        import hashlib
        import importlib.abc
        import json
        import random
        import sys
        from pathlib import Path

        class RejectOld(importlib.abc.MetaPathFinder):
            def find_spec(self, fullname, path=None, target=None):
                if fullname == "vendor.shelf_v1":
                    raise AssertionError("old provider is still used")
                return None
        sys.meta_path.insert(0, RejectOld())
        from export import export_records
        from lookup import lookup_value
        from manifest import build_manifest
        from vendor.shelf_v2 import Store

        assert not Path("vendor/shelf_v1.py").exists(), "remove the obsolete dependency"
        assert hashlib.sha256(Path("vendor/shelf_v2.py").read_bytes()).hexdigest() == "__PROVIDER_SHA256__", "do not alter the vendored v2 contract"
        values = [None, False, 0, "", "café", {"z": [1, False], "a": "雪"}, [1, None]]
        for seed in range(5):
            rows = [{"key": ("app/" if i % 3 else "other/") + str(i), "value": values[i % len(values)], "deleted": i % 7 == 4} for i in range(127 + seed)]
            random.Random(seed).shuffle(rows)
            # The first page is empty and a later page consists only of tombstones.
            rows = [{"checkpoint": True}] * 3 + [{"key": "app/dead", "value": 9, "deleted": True}] + rows
            for prefix in ["", "app/", "other/", "absent/"]:
                expected = sorted([{"key": row["key"], "value": row["value"]} for row in rows if "key" in row and row["key"].startswith(prefix) and not row.get("deleted")], key=lambda row: row["key"])
                for size in [1, 2, 5, 200]:
                    store = Store(rows)
                    assert export_records(store, prefix, size) == expected
                    assert store.active_sessions == 0
                    assert store.scan_sizes and set(store.scan_sizes) == {size}
                store = Store(rows)
                assert build_manifest(store, prefix) == {
                    "count": len(expected), "keys": [row["key"] for row in expected],
                    "total_bytes": sum(len(json.dumps(row["value"], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")) for row in expected),
                }
                assert store.active_sessions == 0 and store.scan_sizes
            store = Store([{"key": str(i), "value": value} for i, value in enumerate(values)] + [{"key": "gone", "deleted": True, "value": 1}])
            marker = object()
            for i, value in enumerate(values):
                assert lookup_value(store, str(i), marker) == value
            assert lookup_value(store, "missing", marker) is marker
            assert lookup_value(store, "gone", marker) is marker
            assert store.active_sessions == 0
        for operation in [lambda s: lookup_value(s, "bad"), lambda s: export_records(s), lambda s: build_manifest(s)]:
            store = Store([{"key": "bad", "raw_payload": b"not-json"}])
            try:
                operation(store)
            except ValueError:
                pass
            else:
                raise AssertionError("decode error was suppressed")
            assert store.active_sessions == 0, "failed decode leaked a session"
    ''').replace("__PROVIDER_SHA256__", hashlib.sha256(files["vendor/shelf_v2.py"].encode("utf-8")).hexdigest())
    return task(
        "vendored_cursor_migration",
        "Complete the local shelf v1-to-v2 migration specified in README.md. Migrate every application consumer to native v2 sessions, opaque pagination, tombstone and byte-decoding semantics; remove the old provider without shims. Preserve public application signatures and add regression tests.",
        files,
        verify,
    )


def _sample_log():
    """Generate noisy, out-of-order retry evidence without a checked-in blob."""
    records = []
    failures = []
    counts = {"E_TIMEOUT": 0, "E_SCHEMA": 0, "E_COMMIT": 0}
    for index in range(1200):
        job = "job-%04d" % index
        base = index * 20
        records.append({"type": "attempt", "id": job + ":start", "job": job,
                        "attempt": 1, "seq": base, "stage": "fetch", "status": "ok"})
        if index % 4 == 0:
            error = {"type": "attempt", "id": job + ":timeout", "job": job,
                     "attempt": 1, "seq": base + 1, "stage": "fetch",
                     "status": "error", "code": "E_TIMEOUT"}
            records.extend([error, dict(error)])
            counts["E_TIMEOUT"] += 1
            records.append({"type": "complete", "id": job + ":old", "job": job,
                            "attempt": 1, "seq": base + 2, "status": "failed"})
            records.append({"type": "complete", "id": job + ":done", "job": job,
                            "attempt": 2, "seq": base + 8, "status": "success"})
        elif index % 4 == 1:
            for stage, code, offset in [("parse", "E_SCHEMA", 3), ("commit", "E_COMMIT", 4)]:
                records.append({"type": "attempt", "id": job + ":" + stage, "job": job,
                                "attempt": 1, "seq": base + offset, "stage": stage,
                                "status": "error", "code": code})
                counts[code] += 1
            terminal = {"type": "complete", "id": job + ":done", "job": job,
                        "attempt": 1, "seq": base + 8, "status": "failed"}
            records.extend([terminal, dict(terminal)])
            failures.append({"job": job, "attempt": 1, "code": "E_SCHEMA",
                             "stage": "parse", "seq": base + 3})
        elif index % 4 == 2:
            records.append({"type": "complete", "id": job + ":done", "job": job,
                            "attempt": 1, "seq": base + 8, "status": "success"})
        else:
            records.append({"type": "attempt", "id": job + ":timeout", "job": job,
                            "attempt": 1, "seq": base + 1, "stage": "fetch",
                            "status": "error", "code": "E_TIMEOUT"})
            counts["E_TIMEOUT"] += 1
    for index in range(16000):
        records.append({"type": "heartbeat", "severity": "error" if index % 5 == 0 else "info",
                        "seq": index, "message": "cache probe E_TIMEOUT; not an attempt failure",
                        "worker": "worker-%02d" % (index % 19)})
    random.Random(7321).shuffle(records)
    lines = [json.dumps(row, sort_keys=True) for row in records]
    for index in range(37):
        lines.insert(index * 419, '{"truncated":')
    expected = {"completed": 900, "succeeded": 600, "failed": 300, "recovered": 300,
                "pending": 300, "malformed": 37, "error_counts": counts,
                "failures": failures}
    return "\n".join(lines) + "\n", expected


def _log_task(task):
    log, expected = _sample_log()
    files = {
        "README.md": _source('''
            # Retry incident analyzer
            `python analyze.py logs/worker.jsonl` currently confuses noisy probe
            messages, retried jobs, root failures, and duplicated/out-of-order events.
            Fix analyze(lines), which accepts ANY iterable of text lines and returns
            the JSON-compatible summary below. Keep the CLI: exactly one JSON object
            on stdout, with no progress/debug output. Add unittest regression tests.
            The supplied large log is deterministic evidence, not the only input;
            do not hard-code job IDs, counts, paths or root causes.

            Parsing contract:
            * Ignore blank lines. Invalid JSON or a non-object JSON value contributes
              one to malformed. Unknown object types (e.g. heartbeat) are ignored,
              regardless of message/severity/code. Recognized types are attempt and
              complete. Invalid recognized records contribute one to malformed.
            * Both recognized types require nonempty string id and job, integer
              seq >= 0 and integer attempt >= 1 (bool is not an integer here).
              attempt records require stage in fetch/parse/commit and status in
              ok/error; an error additionally requires a nonempty string code.
              complete records require status in success/failed. Extra fields are OK.
            * Deduplicate valid recognized records by id. Repeated IDs always have
              identical contents. Malformed lines are counted per occurrence.
            * Job outcome is its complete event with greatest (seq, id), NOT last
              line seen. Known jobs without any complete event are pending.
            * error_counts counts ALL unique valid attempt/error events by code,
              including pending jobs and events later than the selected completion.
            * A successful job is recovered iff it has any attempt/error with seq
              <= its selected completion seq (across any attempts).
            * For each failed job, root cause is the earliest (seq, id) attempt/error
              from the selected completion's attempt with seq <= completion seq.
              Earlier attempts and downstream errors are NOT extra failed jobs.
              If no qualifying error exists, code="unknown", stage=null, and seq
              is the selected completion seq.
            * Summary keys: completed, succeeded, failed, recovered, pending,
              malformed, error_counts (only codes actually counted), failures.
              Each failures entry has job, attempt, code, stage, seq. Sort failures
              by (root seq, job); all counts are integers. completed=succeeded+failed.
        '''),
        "logs/worker.jsonl": log,
        "analyze.py": _source('''
            import json
            import sys
            from collections import Counter


            def analyze(lines):
                errors = Counter()
                succeeded = failed = malformed = 0
                for line in lines:
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        malformed += 1
                        continue
                    if event.get("status") == "error" or event.get("severity") == "error":
                        errors[event.get("code", "E_TIMEOUT")] += 1
                    if event.get("type") == "complete":
                        if event["status"] == "success":
                            succeeded += 1
                        else:
                            failed += 1
                return {"completed": succeeded + failed, "succeeded": succeeded,
                        "failed": failed, "recovered": 0, "pending": 0,
                        "malformed": malformed, "error_counts": dict(errors), "failures": []}


            if __name__ == "__main__":
                with open(sys.argv[1], encoding="utf-8") as source:
                    print(json.dumps(analyze(source), sort_keys=True))
        '''),
        "test_analyze.py": _source('''
            import unittest
            from analyze import analyze


            class AnalyzeTests(unittest.TestCase):
                def test_empty(self):
                    self.assertEqual(analyze(iter(["\\n"])), {
                        "completed": 0, "succeeded": 0, "failed": 0, "recovered": 0,
                        "pending": 0, "malformed": 0, "error_counts": {}, "failures": [],
                    })
        '''),
    }
    verify = _source('''
        import json
        import random
        import subprocess
        import sys
        import tempfile
        from pathlib import Path
        from analyze import analyze

        expected_sample = __EXPECTED_SAMPLE__
        with open("logs/worker.jsonl", encoding="utf-8") as stream:
            assert analyze(stream) == expected_sample
        result = subprocess.run([sys.executable, "analyze.py", "logs/worker.jsonl"], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == expected_sample

        def attempt(id, job, number, seq, code, stage="fetch"):
            return {"type": "attempt", "id": id, "job": job, "attempt": number,
                    "seq": seq, "stage": stage, "status": "error", "code": code}
        def complete(id, job, number, seq, status):
            return {"type": "complete", "id": id, "job": job, "attempt": number,
                    "seq": seq, "status": status}

        for seed in range(7):
            rng = random.Random(811 + seed)
            records = []
            failures = []
            counts = {}
            def error(id, job, number, seq, code, stage="fetch"):
                record = attempt(id, job, number, seq, code, stage)
                records.extend([record, dict(record)])
                counts[code] = counts.get(code, 0) + 1
            width = 9 + seed
            for index in range(width):
                base = index * 100 + seed
                job = "case-%s-%s" % (seed, index)
                error(job + ":old", job, 1, base, "OLD")
                records.append(complete(job + ":old-done", job, 1, base + 1, "failed"))
                error(job + ":b", job, 2, base + 10, "SECONDARY", "commit")
                error(job + ":a", job, 2, base + 10, "ROOT-%d" % seed, "parse")
                error(job + ":late", job, 2, base + 99, "LATE")
                terminal = complete(job + ":done", job, 2, base + 20, "failed")
                records.extend([terminal, dict(terminal)])
                failures.append({"job": job, "attempt": 2, "code": "ROOT-%d" % seed,
                                 "stage": "parse", "seq": base + 10})
            error("recovery-error", "recovered", 1, 2, "TEMP")
            records.extend([complete("recovery-old", "recovered", 1, 4, "failed"),
                            complete("recovery-new", "recovered", 2, 8, "success"),
                            complete("unknown", "unknown", 3, 7, "failed"),
                            complete("tie-a", "tie", 1, 15, "failed"),
                            complete("tie-z", "tie", 1, 15, "success"),
                            complete("clean", "clean", 1, 1, "success")])
            error("after-success", "clean", 1, 9, "TOO_LATE")
            error("pending", "pending", 1, 1, "WAIT")
            error("wrong-attempt", "unknown", 1, 3, "NOT_ROOT")
            failures.append({"job": "unknown", "attempt": 3, "code": "unknown", "stage": None, "seq": 7})
            records.extend([{"type": "heartbeat", "severity": "error", "code": "NOT_AN_ERROR"}, {}])
            rng.shuffle(records)
            invalid = ["broken json", "[]", "null", "42", json.dumps({"type": "attempt"}),
                       json.dumps(attempt("bad-bool", "bad", True, 1, "BAD")),
                       json.dumps(attempt("bad-seq", "bad", 1, -1, "BAD")),
                       json.dumps(attempt("bad-stage", "bad", 1, 1, "BAD", "other")),
                       json.dumps(attempt("bad-code", "bad", 1, 1, "")),
                       json.dumps(complete("bad-status", "bad", 1, 1, "ok"))]
            lines = [json.dumps(record) + "\\n" for record in records] + invalid + ["", "  "]
            rng.shuffle(lines)
            expected = {"completed": width + 4, "failed": width + 1,
                        "succeeded": 3, "recovered": 1, "pending": 1,
                        "malformed": len(invalid), "error_counts": counts,
                        "failures": sorted(failures, key=lambda row: (row["seq"], row["job"]))}
            assert analyze(iter(lines)) == expected
            assert analyze(iter(reversed(lines))) == expected
            if seed == 3:
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "different.jsonl"
                    path.write_text("\\n".join(line.rstrip("\\n") for line in lines), encoding="utf-8")
                    result = subprocess.run([sys.executable, "analyze.py", str(path)], capture_output=True, text=True)
                    assert result.returncode == 0, result.stderr
                    assert json.loads(result.stdout) == expected
        assert analyze(iter([])) == {"completed": 0, "succeeded": 0, "failed": 0,
            "recovered": 0, "pending": 0, "malformed": 0, "error_counts": {}, "failures": []}
    ''').replace("__EXPECTED_SAMPLE__", repr(expected))
    return task(
        "noisy_retry_log_analysis",
        "Investigate logs/worker.jsonl and repair analyze.py according to README.md. Correctly distinguish noise, malformed records, duplicate delivery, retry recovery, pending work, and final-attempt root causes. Preserve the JSON CLI and add unittest regression coverage; implement the general analyzer, not a fixed report for this log.",
        files,
        verify,
    )
