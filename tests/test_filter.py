"""Tests for the cache-refresh policy in scripts/filter.py."""
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_filter(cache_dir: Path, ttl: int = 300):
    os.environ["alfred_workflow_cache"] = str(cache_dir)
    os.environ["PP_CACHE_TTL"] = str(ttl)
    spec = importlib.util.spec_from_file_location("pp_filter", HERE.parent / "scripts" / "filter.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CachePolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.tmp.name)
        self.mod = load_filter(self.cache_dir)
        self.calls = []
        self.mod.run_indexer = lambda force=False, background=False: self.calls.append(
            {"force": force, "background": background})

    def tearDown(self):
        self.tmp.cleanup()

    def write_cache(self, data: dict, age: float):
        f = self.cache_dir / "index.json"
        f.write_text(json.dumps(data))
        t = time.time() - age
        os.utime(f, (t, t))

    ERROR_ONLY = {"items": [], "errors": ["not logged in (run: pass-cli login)"]}
    WITH_ITEMS = {"items": [{"id": "i", "share_id": "s", "title": "x"}], "errors": []}

    def test_error_only_cache_is_retried_well_before_ttl(self):
        self.write_cache(self.ERROR_ONLY, age=15)
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": True, "background": False}])

    def test_error_only_cache_is_not_retried_on_every_keystroke(self):
        self.write_cache(self.ERROR_ONLY, age=2)
        self.mod.load_cache()
        self.assertEqual(self.calls, [])

    def test_fresh_items_are_not_refreshed(self):
        self.write_cache(self.WITH_ITEMS, age=15)
        self.mod.load_cache()
        self.assertEqual(self.calls, [])

    def test_stale_items_refresh_in_background(self):
        self.write_cache(self.WITH_ITEMS, age=301)
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": False, "background": True}])

    def test_missing_cache_is_built_synchronously(self):
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": True, "background": False}])


if __name__ == "__main__":
    unittest.main()
