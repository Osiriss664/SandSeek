#!/usr/bin/env python3
"""Tests for the web research sandbox. No network: resolver and transport are
replaced with fakes. Run with `python3 -m unittest Sandbox/web-research/test_server.py`."""

import gzip
import http.client
import json
import os
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402
from server import Response, ToolError, WebTools  # noqa: E402


def resolver(table):
    def resolve(host, port):
        if host not in table:
            raise ToolError(f"could not resolve {host}", "dns_error", 502)
        return table[host]
    return resolve


class FakeTransport:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, method, target, headers, body):
        self.calls.append((method, target, headers, body))
        return self.routes[target.url]


def page(markup, status=200, content_type="text/html; charset=utf-8", **headers):
    return Response(status, {"content-type": content_type, **headers}, markup.encode())


ARTICLE = """<html><head><title>Bounded  streaming</title><script>evil()</script></head>
<body><nav>menu</nav><article><h1>Experts</h1><p>TUFF streams experts from disk.</p>
<p>The cache is bounded.</p></article></body></html>"""


class AddressPolicyTests(unittest.TestCase):
    def test_private_and_special_addresses_are_refused(self):
        for address in ["127.0.0.1", "10.0.0.1", "192.168.64.1", "172.16.0.1",
                        "169.254.169.254", "100.64.0.1", "::1", "fd00::1",
                        "::ffff:192.168.64.1", "0.0.0.0", "224.0.0.1", "not-an-ip"]:
            self.assertFalse(server.is_public_address(address), address)

    def test_public_addresses_are_allowed(self):
        for address in ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]:
            self.assertTrue(server.is_public_address(address), address)

    def test_host_gateway_name_is_refused(self):
        resolve = resolver({"host.container.internal": ["192.168.64.1"]})
        with self.assertRaises(ToolError) as caught:
            server.check_url("http://host.container.internal/", resolve)
        self.assertEqual(caught.exception.code, "blocked_address")

    def test_mixed_answers_are_refused(self):
        resolve = resolver({"rebind.example": ["93.184.216.34", "127.0.0.1"]})
        with self.assertRaises(ToolError):
            server.check_url("https://rebind.example/", resolve)

    def test_url_shape_rules(self):
        resolve = resolver({"example.com": ["93.184.216.34"]})
        for url, code in [("file:///etc/passwd", "invalid_url"),
                          ("ftp://example.com/", "invalid_url"),
                          ("http://user:pw@example.com/", "invalid_url"),
                          ("http://example.com:8080/", "blocked_port"),
                          ("https://example.com:80/", "blocked_port"),
                          ("http:///nohost", "invalid_url")]:
            with self.assertRaises(ToolError, msg=url) as caught:
                server.check_url(url, resolve)
            self.assertEqual(caught.exception.code, code, url)

    def test_connection_is_pinned_to_checked_address(self):
        resolve = resolver({"example.com": ["93.184.216.34"]})
        target = server.check_url("https://Example.com./a?b=1", resolve)
        self.assertEqual(target.address, "93.184.216.34")
        self.assertEqual(target.host, "example.com")
        self.assertEqual(target.url, "https://example.com/a?b=1")


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.resolve = resolver({
            "example.com": ["93.184.216.34"],
            "other.example": ["93.184.216.35"],
            "internal.example": ["10.1.2.3"],
        })

    def tools(self, routes):
        return WebTools(resolver=self.resolve, transport=FakeTransport(routes), searxng_url="")

    def test_extracts_article_text_and_title(self):
        tools = self.tools({"https://example.com/a": page(ARTICLE)})
        result = tools.fetch("https://example.com/a")
        self.assertEqual(result["title"], "Bounded streaming")
        self.assertIn("TUFF streams experts from disk.", result["text"])
        self.assertNotIn("evil()", result["text"])
        self.assertIsNone(result["next_offset"])

    def test_slices_with_offsets_from_cache(self):
        text = "x" * 25
        transport = FakeTransport({"https://example.com/t": page(text, content_type="text/plain")})
        tools = WebTools(resolver=self.resolve, transport=transport, searxng_url="")
        first = tools.fetch("https://example.com/t", 0, 10)
        self.assertEqual((first["text"], first["next_offset"], first["total_chars"]), ("x" * 10, 10, 25))
        last = tools.fetch("https://example.com/t", 20, 10)
        self.assertEqual((last["text"], last["next_offset"]), ("x" * 5, None))
        self.assertEqual(len(transport.calls), 1)

    def test_redirects_are_followed_and_rechecked(self):
        tools = self.tools({
            "https://example.com/r": Response(302, {"location": "https://other.example/x"}, b""),
            "https://other.example/x": page(ARTICLE),
        })
        self.assertEqual(tools.fetch("https://example.com/r")["url"], "https://other.example/x")

        blocked = self.tools({
            "https://example.com/r": Response(301, {"location": "http://internal.example/"}, b""),
        })
        with self.assertRaises(ToolError) as caught:
            blocked.fetch("https://example.com/r")
        self.assertEqual(caught.exception.code, "blocked_address")

    def test_redirect_loop_stops(self):
        tools = self.tools({
            "https://example.com/loop": Response(302, {"location": "/loop"}, b""),
        })
        with self.assertRaises(ToolError) as caught:
            tools.fetch("https://example.com/loop")
        self.assertEqual(caught.exception.code, "too_many_redirects")

    def test_non_text_content_is_refused(self):
        tools = self.tools({"https://example.com/f": Response(
            200, {"content-type": "application/octet-stream"}, b"\x00")})
        with self.assertRaises(ToolError) as caught:
            tools.fetch("https://example.com/f")
        self.assertEqual(caught.exception.code, "unsupported_content")

    def test_http_errors_are_reported(self):
        tools = self.tools({"https://example.com/404": page("nope", status=404)})
        with self.assertRaises(ToolError) as caught:
            tools.fetch("https://example.com/404")
        self.assertEqual(caught.exception.code, "http_error")

    def test_gzip_bodies_are_decoded(self):
        body = gzip.compress(ARTICLE.encode())
        tools = self.tools({"https://example.com/z": Response(
            200, {"content-type": "text/html", "content-encoding": "gzip"}, body)})
        self.assertIn("bounded", tools.fetch("https://example.com/z")["text"])

    def test_argument_bounds(self):
        tools = self.tools({})
        for offset, max_chars in [(-1, 10), (0, 0), (0, server.MAX_SLICE_CHARS + 1), ("1", 10)]:
            with self.assertRaises(ToolError):
                tools.fetch("https://example.com/", offset, max_chars)


DDG = """<div class="result"><a class="result__a" rel="nofollow"
href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdoc&amp;rut=1">Example <b>Doc</b></a>
<a class="result__snippet" href="#">The <b>first</b> snippet.</a></div>
<div class="result"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a></div>
<div class="result"><a class="result__a" href="https://other.example/page">Other</a>
<div class="result__snippet">Second.</div></div>
<div class="result"><a class="result__a" href="javascript:alert(1)">Bad</a></div>"""


class SearchTests(unittest.TestCase):
    def test_parses_duckduckgo_results_and_drops_ads(self):
        results = server.parse_duckduckgo(DDG)
        self.assertEqual(results, [
            {"title": "Example Doc", "url": "https://example.com/doc", "snippet": "The first snippet."},
            {"title": "Other", "url": "https://other.example/page", "snippet": "Second."},
        ])

    def test_search_posts_to_duckduckgo_and_limits_results(self):
        resolve = resolver({"html.duckduckgo.com": ["52.142.124.215"]})
        transport = FakeTransport({"https://html.duckduckgo.com/html/": page(DDG)})
        tools = WebTools(resolver=resolve, transport=transport, searxng_url="")
        result = tools.search("bounded experts", 1)
        self.assertEqual(len(result["results"]), 1)
        method, _, headers, body = transport.calls[0]
        self.assertEqual(method, "POST")
        self.assertEqual(body, b"q=bounded+experts")
        self.assertEqual(headers["Content-Type"], "application/x-www-form-urlencoded")

    def test_query_bounds(self):
        tools = WebTools(resolver=resolver({}), transport=FakeTransport({}), searxng_url="")
        for query, count in [("", 5), ("x" * 401, 5), ("ok", 0), ("ok", 11), (None, 5)]:
            with self.assertRaises(ToolError):
                tools.search(query, count)


class InjectionFixtureTests(unittest.TestCase):
    """The injection fixtures only test the model if extraction keeps the
    planted text, so check that it survives."""

    def test_planted_text_survives_extraction(self):
        directory = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "injection")
        expected = {
            "ignore-instructions.html": "ZEBRA-CANARY-41",
            "exfiltrate.html": "canary-exfil.invalid",
            "local-network.html": "169.254.169.254",
            "fake-tool-boundary.html": "CANARY-PEACH-9",
        }
        self.assertEqual(sorted(os.listdir(directory)), sorted(expected))
        for name, planted in expected.items():
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                text = server.extract_text(handle.read(), f"https://fixtures.example/{name}")
            self.assertIn(planted, text, name)


class HTTPAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        resolve = resolver({"example.com": ["93.184.216.34"]})
        transport = FakeTransport({"https://example.com/a": page(ARTICLE)})

        class TestHandler(server.Handler):
            tools = WebTools(resolver=resolve, transport=transport, searxng_url="")

            def log_message(self, *args):
                pass

        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), TestHandler)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def call(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        data = json.dumps(body).encode() if body is not None else None
        all_headers = {"Content-Type": "application/json"}
        all_headers.update(headers or {})
        connection.request(method, path, body=data, headers=all_headers)
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        return response.status, payload

    def test_health(self):
        self.assertEqual(self.call("GET", "/health"), (200, {"status": "ok"}))

    def test_fetch_round_trip(self):
        status, payload = self.call("POST", "/v1/fetch", {"url": "https://example.com/a"})
        self.assertEqual(status, 200)
        self.assertIn("streams experts", payload["text"])

    def test_tool_errors_are_json(self):
        status, payload = self.call("POST", "/v1/fetch", {"url": "file:///etc/passwd"})
        self.assertEqual(status, 422)
        self.assertEqual(payload["error"]["code"], "invalid_url")

    def test_rebinding_host_is_refused(self):
        status, payload = self.call("POST", "/v1/fetch", {"url": "https://example.com/a"},
                                    {"Host": "attacker.example:9000"})
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"]["code"], "forbidden_host")

    def test_simple_cross_origin_post_is_refused(self):
        status, _ = self.call("POST", "/v1/fetch", {"url": "https://example.com/a"},
                              {"Content-Type": "text/plain"})
        self.assertEqual(status, 415)

    def test_unknown_path(self):
        self.assertEqual(self.call("POST", "/v1/shell", {})[0], 404)


if __name__ == "__main__":
    unittest.main()
