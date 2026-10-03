#!/usr/bin/env python3
"""Web tool server for `tuff research`.

This process is the only part of web research that touches the internet. It
runs inside an Apple `container` Linux VM and is published to the Mac's
loopback address, so the host-side research loop calls in. The model never
sees raw HTML: pages come back as extracted text in bounded slices, with
control characters removed.

Endpoints (JSON in, JSON out):
  GET  /health
  POST /v1/search  {"query": str, "max_results": int?}
  POST /v1/fetch   {"url": str, "offset": int?, "max_chars": int?}

Fetches refuse anything but http(s) on ports 80 and 443, and refuse every
address that is not globally routable. The resolved address is the one
connected to, so a DNS answer cannot change between the check and the
connection. Redirects are followed by hand and checked the same way. That keeps
the Mac (the VM's gateway), the local network and cloud metadata addresses out
of reach.

Those checks live in this process, so they would not bind code that took it
over. firewall.nft, loaded by entrypoint.sh before this server starts, applies
the same rule to the whole VM, and the server then drops root and every Linux
capability so it cannot change the firewall.
"""

from __future__ import annotations

import codecs
import ctypes
import errno
import gzip
import html
import http.client
import ipaddress
import json
import multiprocessing
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import zlib
from collections import OrderedDict
from dataclasses import dataclass, field
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

try:
    import trafilatura
except ImportError:  # The extractor is optional so tests can run without it.
    trafilatura = None

PORT = int(os.environ.get("PORT", "9000"))
SEARXNG_URL = os.environ.get("SEARXNG_URL", "").rstrip("/")
USER_AGENT = os.environ.get(
    "USER_AGENT",
    "Mozilla/5.0 (compatible; TUFF-web-research/1.0; +https://github.com/rexmhall09/TUFF)")
FETCH_TIMEOUT = float(os.environ.get("FETCH_TIMEOUT", "15"))
# The whole request, so a server that drips one byte at a time cannot hold a
# fetch open; FETCH_TIMEOUT alone only limits each wait.
FETCH_DEADLINE = float(os.environ.get("FETCH_DEADLINE", "45"))
# Extraction runs in a separate process with its own limit, because a
# hostile page can keep the extractor busy for a long time and Python threads
# cannot be stopped. Only the first MAX_EXTRACT_CHARS of a page are read.
EXTRACT_TIMEOUT = float(os.environ.get("EXTRACT_TIMEOUT", "15"))
MAX_EXTRACT_CHARS = 2_000_000
MAX_DOWNLOAD_BYTES = int(os.environ.get("MAX_DOWNLOAD_BYTES", str(5 * 1024 * 1024)))
MAX_REDIRECTS = 5
MAX_REQUEST_BYTES = 64 * 1024
DEFAULT_SLICE_CHARS = 6000
MAX_SLICE_CHARS = 20000
MAX_SEARCH_RESULTS = 10
PAGE_CACHE_SIZE = 32
ALLOWED_PORTS = {"http": 80, "https": 443}
TEXT_TYPES = ("text/html", "application/xhtml+xml", "text/plain")
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "[::1]", "::1"}
# Titles sit in the head; searching further only gives a hostile page more
# text to make the search slow.
TITLE_SEARCH_CHARS = 32 * 1024
SANDBOX_UID = 10001
# Names Python decodes as text. Anything else (idna, rot13, base64...) falls
# back to UTF-8 instead of failing or decoding into something odd.
TEXT_CHARSETS = {
    "ascii", "utf-8", "utf-16", "utf-16-le", "utf-16-be", "utf-32", "iso8859-1",
    "iso8859-2", "iso8859-3", "iso8859-4", "iso8859-5", "iso8859-6", "iso8859-7",
    "iso8859-8", "iso8859-9", "iso8859-10", "iso8859-13", "iso8859-14",
    "iso8859-15", "iso8859-16", "cp1250", "cp1251", "cp1252", "cp1253", "cp1254",
    "cp1255", "cp1256", "cp1257", "cp1258", "cp874", "koi8-r", "koi8-u",
    "mac-roman", "shift_jis", "cp932", "euc_jp", "iso2022_jp", "euc_kr", "cp949",
    "gb2312", "gbk", "gb18030", "big5", "big5hkscs",
}


class ToolError(Exception):
    """A request the tool refuses or cannot complete, reported to the caller."""

    def __init__(self, message: str, code: str, status: int = 422):
        super().__init__(message)
        self.message = message
        self.code = code
        self.status = status


# --- Address policy ---------------------------------------------------------

IPV6_UNICAST = ipaddress.ip_network("2000::/3")
# Inside 2000::/3 but carrying an IPv4 address a gateway could route to
# (6to4, Teredo), or reserved for documentation.
IPV6_REFUSED = [ipaddress.ip_network(n) for n in ("2002::/16", "2001::/32", "2001:db8::/32")]


def is_public_address(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        # is_global alone accepts forms such as ::127.0.0.1 and the NAT64
        # prefix, which a gateway can turn into a private IPv4 address. Only
        # the global unicast range is allowed.
        elif ip not in IPV6_UNICAST or any(ip in net for net in IPV6_REFUSED):
            return False
    return ip.is_global and not ip.is_multicast


def system_resolver(host: str, port: int) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        raise ToolError(f"could not resolve {host}: {error.strerror}", "dns_error", 502)
    return [info[4][0] for info in infos]


@dataclass(frozen=True)
class Target:
    scheme: str
    host: str
    port: int
    path: str
    address: str

    @property
    def url(self) -> str:
        default = ALLOWED_PORTS[self.scheme]
        netloc = self.host if self.port == default else f"{self.host}:{self.port}"
        return f"{self.scheme}://{netloc}{self.path}"


def check_url(url: str, resolver: Callable[[str, int], list[str]]) -> Target:
    """Parses `url` and pins it to one public address, or refuses it."""
    if not isinstance(url, str) or len(url) > 4096:
        raise ToolError("url must be a string of at most 4096 characters", "invalid_url")
    parts = urllib.parse.urlsplit(url.strip())
    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_PORTS:
        raise ToolError("only http and https URLs can be fetched", "invalid_url")
    if parts.username or parts.password:
        raise ToolError("URLs with credentials are refused", "invalid_url")
    if CONTROL_CHARACTERS.search(url) or any(c.isspace() for c in url.strip()):
        raise ToolError("URL contains spaces or control characters", "invalid_url")
    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        raise ToolError("URL has no host", "invalid_url")
    if not host.isascii():
        # Internationalised names are sent as punycode, as browsers do.
        try:
            host = host.encode("idna").decode("ascii")
        except UnicodeError:
            raise ToolError("URL has an invalid internationalised host name", "invalid_url")
    try:
        port = parts.port or ALLOWED_PORTS[scheme]
    except ValueError:
        raise ToolError("URL has an invalid port", "invalid_url")
    if port != ALLOWED_PORTS[scheme]:
        raise ToolError(f"only port {ALLOWED_PORTS[scheme]} is allowed for {scheme}", "blocked_port")
    addresses = resolver(host, port)
    if not addresses:
        raise ToolError(f"could not resolve {host}", "dns_error", 502)
    # Every answer must be public: picking the one public answer out of a
    # mixed set would still let a rebinding name aim at the host next time.
    blocked = [a for a in addresses if not is_public_address(a)]
    if blocked:
        raise ToolError(f"{host} resolves to a non-public address", "blocked_address", 403)
    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    # IPv4 first: the VM may have no IPv6 route, and every answer is public.
    preferred = sorted(addresses, key=lambda a: ":" in a)[0]
    return Target(scheme, host, port, path, preferred)


# --- Transport --------------------------------------------------------------

@dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: bytes
    truncated: bool = False


Transport = Callable[[str, Target, dict[str, str], bytes | None], Response]


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, target: Target, timeout: float):
        super().__init__(target.host, target.port, timeout=timeout)
        self._address = target.address

    def connect(self):
        self.sock = socket.create_connection((self._address, self.port), self.timeout)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, target: Target, timeout: float):
        super().__init__(target.host, target.port, timeout=timeout,
                         context=ssl.create_default_context())
        self._address = target.address

    def connect(self):
        sock = socket.create_connection((self._address, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def pinned_transport(method: str, target: Target, headers: dict[str, str],
                     body: bytes | None, deadline: float | None = None) -> Response:
    cls = _PinnedHTTPSConnection if target.scheme == "https" else _PinnedHTTPConnection
    connection = cls(target, FETCH_TIMEOUT)
    limit = FETCH_DEADLINE if deadline is None else deadline
    expired = threading.Event()

    def expire():
        # Shutting the socket down wakes a read blocked in another thread.
        expired.set()
        if connection.sock is not None:
            try:
                connection.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    timer = threading.Timer(limit, expire)
    timer.daemon = True
    timer.start()
    too_slow = ToolError(f"{target.host} took longer than {limit:g} s", "fetch_timeout", 504)
    try:
        connection.request(method, target.path, body=body, headers=headers)
        response = connection.getresponse()
        chunks, size = [], 0
        while size <= MAX_DOWNLOAD_BYTES and not expired.is_set():
            chunk = response.read1(min(65536, MAX_DOWNLOAD_BYTES + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if expired.is_set():
            raise too_slow
        data = b"".join(chunks)
        return Response(
            status=response.status,
            headers={k.lower(): v for k, v in response.getheaders()},
            body=data[:MAX_DOWNLOAD_BYTES],
            truncated=len(data) > MAX_DOWNLOAD_BYTES)
    except (OSError, http.client.HTTPException, ValueError) as error:
        if expired.is_set():
            raise too_slow
        raise ToolError(f"request to {target.host} failed: {error}", "fetch_failed", 502)
    finally:
        timer.cancel()
        connection.close()


def decode_body(response: Response) -> bytes:
    encoding = response.headers.get("content-encoding", "identity").lower()
    if encoding in ("", "identity"):
        return response.body
    if encoding not in ("gzip", "deflate"):
        raise ToolError(f"unsupported content encoding {encoding}", "unsupported_content")
    wbits = 16 + zlib.MAX_WBITS if encoding == "gzip" else zlib.MAX_WBITS
    try:
        inflater = zlib.decompressobj(wbits)
        # Bounded so a small compressed bomb cannot fill the VM's memory.
        return inflater.decompress(response.body, MAX_DOWNLOAD_BYTES)
    except (zlib.error, gzip.BadGzipFile):
        raise ToolError("response body could not be decompressed", "unsupported_content", 502)


def charset_of(content_type: str) -> str:
    match = re.search(r"charset=\"?([\w.:-]+)", content_type, re.I)
    if match:
        try:
            name = codecs.lookup(match.group(1)).name
        except LookupError:
            return "utf-8"
        if name in TEXT_CHARSETS:
            return name
    return "utf-8"


META_CHARSET = re.compile(rb"""<meta[^>]{0,200}?charset\s*=\s*["']?([\w.:-]+)""", re.I)


def page_charset(content_type: str, body: bytes) -> str:
    """The HTTP header's charset, else the page's own <meta charset>, else UTF-8."""
    if "charset=" in content_type.lower():
        return charset_of(content_type)
    match = META_CHARSET.search(body[:4096])
    if match:
        return charset_of("charset=" + match.group(1).decode("ascii", "replace"))
    return "utf-8"


# C0 and C1 controls other than tab and newline, and the Unicode bidi
# overrides: a page title holding ESC sequences could otherwise rewrite the
# terminal the report is printed in. Also invisible characters: the soft
# hyphen, zero-width characters, the byte order mark and the Unicode tag
# block, which can spell out instructions the model reads but a person
# reviewing the text cannot see.
CONTROL_CHARACTERS = re.compile(
    "[\x00-\x08\x0b-\x1f\x7f-\x9f\xad\u200b-\u200f\u202a-\u202e\u2060-\u2069"
    "\ufeff\U000e0000-\U000e007f]")


def clean_text(text: str) -> str:
    for separator in ("\r\n", "\r", "\u2028", "\u2029"):
        text = text.replace(separator, "\n")
    return CONTROL_CHARACTERS.sub("", text)


# --- Extraction -------------------------------------------------------------

class _FallbackText(HTMLParser):
    """Plain-text fallback when trafilatura is missing or finds no article."""

    SKIP = {"script", "style", "noscript", "template", "svg", "head"}
    BLOCK = {"p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6", "tr",
             "section", "article", "blockquote", "pre"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skipping = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skipping += 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skipping:
            self.skipping -= 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skipping:
            self.parts.append(data)

    def text(self) -> str:
        joined = "".join(self.parts)
        lines = (re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in joined.split("\n"))
        return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


TITLE_OPEN = re.compile(r"<title(?:\s[^<>]{0,500})?>", re.I)


def extract_title(markup: str) -> str:
    # A bounded, linear search: a lazy `<title>(.*?)</title>` over the whole
    # page takes hours on a page of unclosed <title> tags, and holds the
    # interpreter lock while it runs.
    head = markup[:TITLE_SEARCH_CHARS]
    match = TITLE_OPEN.search(head)
    if not match:
        return ""
    end = head.lower().find("</title>", match.end())
    if end < 0:
        return ""
    title = html.unescape(head[match.end():end])
    return clean_text(re.sub(r"\s+", " ", title)).strip()[:300]


def extract_text(markup: str, url: str) -> str:
    if trafilatura is not None:
        text = trafilatura.extract(
            markup, url=url, include_comments=False, include_tables=True,
            favor_recall=True, deduplicate=True)
        if text and text.strip():
            return clean_text(text).strip()
    return fallback_text(markup)


def fallback_text(markup: str) -> str:
    parser = _FallbackText()
    parser.feed(markup)
    parser.close()
    return clean_text(parser.text())


def _extract_in_child(sender, extractor, markup: str, url: str) -> None:
    try:
        sender.send(extractor(markup, url))
    except Exception:
        sender.send(None)  # The parent falls back to the simple parser.
    finally:
        sender.close()


def extract_text_bounded(markup: str, url: str, timeout: float | None = None,
                         extractor: Callable[[str, str], str] = extract_text) -> str:
    """Runs `extractor` in a child process and stops it after `timeout`
    seconds. A page the extractor cannot finish in time, or fails on, is read
    with the simple fallback parser instead, which is linear."""
    markup = markup[:MAX_EXTRACT_CHARS]
    context = multiprocessing.get_context("forkserver")
    receiver, sender = context.Pipe(duplex=False)
    child = context.Process(target=_extract_in_child, args=(sender, extractor, markup, url),
                            daemon=True)
    child.start()
    sender.close()
    text = None
    try:
        if receiver.poll(EXTRACT_TIMEOUT if timeout is None else timeout):
            text = receiver.recv()
    except (EOFError, OSError):
        pass
    finally:
        receiver.close()
        if child.is_alive():
            child.kill()
        child.join(5)
    if isinstance(text, str):
        return text
    sys.stderr.write(f"extraction of {url} timed out or failed; used the fallback parser\n")
    return fallback_text(markup)


# --- Tools ------------------------------------------------------------------

@dataclass
class Page:
    url: str
    title: str
    text: str


@dataclass
class WebTools:
    resolver: Callable[[str, int], list[str]] = system_resolver
    transport: Transport = pinned_transport
    searxng_url: str = SEARXNG_URL
    cache: OrderedDict = field(default_factory=OrderedDict)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def request(self, method: str, url: str, body: bytes | None = None,
                content_type: str | None = None) -> tuple[str, Response]:
        """Follows up to MAX_REDIRECTS redirects, checking every hop."""
        current = url
        for _ in range(MAX_REDIRECTS + 1):
            target = check_url(current, self.resolver)
            headers = {
                "Host": target.host,
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1",
                "Accept-Encoding": "gzip",
                "Accept-Language": "en;q=0.9,*;q=0.5",
            }
            if content_type:
                headers["Content-Type"] = content_type
            response = self.transport(method, target, headers, body)
            if response.status in (301, 302, 303, 307, 308):
                location = response.headers.get("location")
                if not location:
                    raise ToolError("redirect without a location", "fetch_failed", 502)
                current = urllib.parse.urljoin(target.url, location)
                if response.status == 303 or (response.status in (301, 302) and method == "POST"):
                    method, body, content_type = "GET", None, None
                continue
            return target.url, response
        raise ToolError("too many redirects", "too_many_redirects", 502)

    def load_page(self, url: str) -> Page:
        with self.lock:
            if url in self.cache:
                self.cache.move_to_end(url)
                return self.cache[url]
        final_url, response = self.request("GET", url)
        if response.status >= 400:
            raise ToolError(f"{final_url} answered HTTP {response.status}", "http_error", 502)
        content_type = response.headers.get("content-type", "").lower()
        if not content_type.startswith(TEXT_TYPES):
            kind = content_type.split(";")[0] or "unknown"
            raise ToolError(f"{final_url} is {kind}, not a web page", "unsupported_content")
        body = decode_body(response)
        raw = body.decode(page_charset(content_type, body), errors="replace")
        if content_type.startswith("text/plain"):
            page = Page(final_url, "", clean_text(raw).strip())
        else:
            page = Page(final_url, extract_title(raw), extract_text_bounded(raw, final_url))
        with self.lock:
            for key in {url, final_url}:
                self.cache[key] = page
                self.cache.move_to_end(key)
            while len(self.cache) > PAGE_CACHE_SIZE:
                self.cache.popitem(last=False)
        return page

    def fetch(self, url: str, offset: int = 0, max_chars: int = DEFAULT_SLICE_CHARS) -> dict:
        if not isinstance(offset, int) or offset < 0:
            raise ToolError("offset must be a non-negative integer", "invalid_argument")
        if not isinstance(max_chars, int) or not 1 <= max_chars <= MAX_SLICE_CHARS:
            raise ToolError(f"max_chars must be between 1 and {MAX_SLICE_CHARS}", "invalid_argument")
        page = self.load_page(url)
        total = len(page.text)
        start = min(offset, total)
        end = min(start + max_chars, total)
        return {
            "url": page.url,
            "title": page.title,
            "text": page.text[start:end],
            "offset": start,
            "next_offset": end if end < total else None,
            "total_chars": total,
        }

    def search(self, query: str, max_results: int = 6) -> dict:
        if not isinstance(query, str) or not query.strip() or len(query) > 400:
            raise ToolError("query must be 1 to 400 characters", "invalid_argument")
        if not isinstance(max_results, int) or not 1 <= max_results <= MAX_SEARCH_RESULTS:
            raise ToolError(f"max_results must be between 1 and {MAX_SEARCH_RESULTS}",
                            "invalid_argument")
        results = self._searxng(query) if self.searxng_url else self._duckduckgo(query)
        seen: set[str] = set()
        unique = []
        for result in results:
            if result["url"] not in seen:
                seen.add(result["url"])
                unique.append(result)
        return {"query": query, "results": unique[:max_results]}

    def _duckduckgo(self, query: str) -> list[dict]:
        body = urllib.parse.urlencode({"q": query}).encode()
        _, response = self.request(
            "POST", "https://html.duckduckgo.com/html/", body,
            "application/x-www-form-urlencoded")
        if response.status >= 400:
            raise ToolError(f"search answered HTTP {response.status}", "search_failed", 502)
        markup = decode_body(response).decode("utf-8", errors="replace")
        return parse_duckduckgo(markup)

    def _searxng(self, query: str) -> list[dict]:
        # SearXNG is the operator's own service, usually another container on a
        # private address, so it is the one destination exempt from the
        # public-address rule. Only its fixed search path is ever requested.
        import urllib.request
        url = f"{self.searxng_url}/search?" + urllib.parse.urlencode(
            {"q": query, "format": "json"})
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
                payload = json.loads(response.read(MAX_DOWNLOAD_BYTES))
        except (OSError, ValueError) as error:
            raise ToolError(f"SearXNG search failed: {error}", "search_failed", 502)
        return [
            {"title": clean_text(str(item.get("title", ""))).strip()[:300],
             "url": str(item.get("url", "")),
             "snippet": clean_text(str(item.get("content", ""))).strip()[:500]}
            for item in payload.get("results", [])
            if is_plain_web_url(str(item.get("url", "")))
        ]


class _DuckDuckGoResults(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.results: list[dict] = []
        self._field: str | None = None

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        classes = (attributes.get("class") or "").split()
        if tag == "a" and "result__a" in classes:
            url = unwrap_duckduckgo(attributes.get("href") or "")
            if url:
                self.results.append({"title": "", "url": url, "snippet": ""})
                self._field = "title"
        elif "result__snippet" in classes and self.results:
            self._field = "snippet"

    def handle_endtag(self, tag):
        if tag in ("a", "td", "div"):
            self._field = None

    def handle_data(self, data):
        if self._field and self.results:
            self.results[-1][self._field] += data


def unwrap_duckduckgo(href: str) -> str | None:
    if href.startswith("//"):
        href = "https:" + href
    parts = urllib.parse.urlsplit(href)
    if parts.netloc.endswith("duckduckgo.com"):
        if parts.path.startswith("/y.js"):
            return None  # Advertisement.
        target = urllib.parse.parse_qs(parts.query).get("uddg", [None])[0]
        href = target or ""
    return href if is_plain_web_url(href) else None


def is_plain_web_url(url: str) -> bool:
    return (url.startswith(("http://", "https://")) and len(url) <= 4096
            and not CONTROL_CHARACTERS.search(url) and not any(c.isspace() for c in url))


def parse_duckduckgo(markup: str) -> list[dict]:
    parser = _DuckDuckGoResults()
    parser.feed(markup)
    parser.close()
    return [
        {"title": clean_text(re.sub(r"\s+", " ", r["title"])).strip()[:300],
         "url": r["url"],
         "snippet": clean_text(re.sub(r"\s+", " ", r["snippet"])).strip()[:500]}
        for r in parser.results
    ]


# --- HTTP API ---------------------------------------------------------------

def host_allowed(header: str | None) -> bool:
    """Only loopback Host names, so a web page in a Mac browser cannot reach
    this API through DNS rebinding."""
    if not header:
        return False
    host = header.strip().lower()
    if host.startswith("["):
        host = host[: host.find("]") + 1]
    elif ":" in host:
        host = host.rsplit(":", 1)[0]
    return host in LOOPBACK_HOSTS


class Handler(BaseHTTPRequestHandler):
    server_version = "TUFFWebResearch/1.0"
    tools: WebTools = WebTools()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def _send(self, status: int, payload: dict):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _error(self, error: ToolError):
        self._send(error.status, {"error": {"message": error.message, "code": error.code}})

    def do_GET(self):
        if not host_allowed(self.headers.get("Host")):
            return self._error(ToolError("forbidden host", "forbidden_host", 403))
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        self._error(ToolError("not found", "not_found", 404))

    def do_POST(self):
        try:
            if not host_allowed(self.headers.get("Host")):
                raise ToolError("forbidden host", "forbidden_host", 403)
            # A browser cannot send application/json cross-origin without a
            # preflight, which this server never answers.
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise ToolError("Content-Type must be application/json", "invalid_request", 415)
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_REQUEST_BYTES:
                raise ToolError("request body is missing or too large", "invalid_request", 413)
            try:
                request = json.loads(self.rfile.read(length))
            except ValueError:
                raise ToolError("request body is not JSON", "invalid_request", 400)
            if not isinstance(request, dict):
                raise ToolError("request body must be a JSON object", "invalid_request", 400)
            if self.path == "/v1/search":
                result = self.tools.search(
                    request.get("query"), request.get("max_results", 6))
            elif self.path == "/v1/fetch":
                result = self.tools.fetch(
                    request.get("url"), request.get("offset", 0),
                    request.get("max_chars", DEFAULT_SLICE_CHARS))
            else:
                raise ToolError("not found", "not_found", 404)
            self._send(200, result)
        except ToolError as error:
            self._error(error)
        except Exception as error:  # Never leak a traceback to the caller.
            sys.stderr.write(f"internal error: {error!r}\n")
            self._error(ToolError("internal error", "internal_error", 500))


def drop_privileges(uid: int = SANDBOX_UID) -> None:
    """Started as root so entrypoint.sh can load the firewall; from here on
    the server runs as an unprivileged user with no capabilities and cannot
    regain any, so it cannot change the firewall either."""
    if os.getuid() != 0:
        return
    libc = ctypes.CDLL(None, use_errno=True)
    pr_capbset_drop, pr_set_no_new_privs = 24, 38
    for capability in range(64):
        if libc.prctl(pr_capbset_drop, capability, 0, 0, 0) != 0:
            if ctypes.get_errno() == errno.EINVAL:
                break  # Past the last capability this kernel knows.
            raise OSError(ctypes.get_errno(), "could not drop a capability")
    os.setgroups([])
    os.setgid(uid)
    os.setuid(uid)
    if libc.prctl(pr_set_no_new_privs, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "could not set no_new_privs")
    with open("/proc/self/status") as status:
        fields = dict(line.split(":", 1) for line in status if ":" in line)
    for name in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"):
        if int(fields.get(name, "0").strip(), 16) != 0:
            raise OSError(errno.EPERM, f"{name} is not empty after dropping privileges")


def main():
    drop_privileges()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"TUFF web research sandbox listening on :{PORT}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
