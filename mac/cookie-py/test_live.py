"""Live smoke test (the network). Skipped unless COOKIE_LIVE=1:

    COOKIE_LIVE=1 vendor/python/bin/python3 -I -B cookie-py/test_live.py -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402


@unittest.skipUnless(os.environ.get("COOKIE_LIVE") == "1", "set COOKIE_LIVE=1 to touch the network")
class Live(unittest.TestCase):
    def test_example_com(self):
        page = server.tool_fetch_page({"url": "https://example.com"})
        print("\n", {k: page[k] for k in ("final_url", "title", "fetched_at", "sha256", "chars")}, file=sys.stderr)
        self.assertEqual(page["title"], "Example Domain")
        out = server.tool_check_quote({"url": "https://example.com", "quote": "This domain is for use in"})
        print(" ", out["sentence"], file=sys.stderr)
        self.assertTrue(out["found"] and out["from_cache"])


if __name__ == "__main__":
    unittest.main()
