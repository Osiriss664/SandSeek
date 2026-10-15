#!/usr/bin/env python3
"""Web tool server for `sandseek`.

This process is the only part of web research that touches the internet. It
runs inside an Apple `container` Linux VM and is published to the Mac's
loopback address, so the host-side research loop calls in. The model never
sees raw HTML: pages come back as extracted text in bounded slices, with
control characters removed.

Endpoints (JSON in, JSON out):
  GET  /health
  POST /v1/search  {"query": str, "max_results": int?}
  POST /v1/fetch   {"url": str, "offset": int?, "max_chars": int?,
                    "passages": bool?, "query": str?}

Fetches refuse anything but http(s) on ports 80 and 443, and refuse every
address that is not globally routable. The resolved address is the one
connected to, so a DNS answer cannot change between the check and the
connection. Redirects are followed by hand and checked the same way; a redirect
from https to http is refused, and so is an answer with more than one Location
header. That keeps the Mac (the VM's gateway), the local network and cloud
metadata addresses out of reach. The Mac's own interface addresses, public ones
included, are refused too: the launcher writes them to a file in the secret
folder (see "Blocked addresses" below).

PDFs: when /v1/fetch gets an application/pdf page (or, for a response typed
application/octet-stream or not typed at all, one whose body starts with
"%PDF-"), the text is read with pypdf in a child process, like the HTML
fallback parser, with limits on size, pages, time and memory. Encrypted PDFs
are refused and nothing is OCR'd. The text then takes the same path as HTML
text.

Signed requests: every request must carry X-Sandbox-Nonce, X-Sandbox-Time and
X-Sandbox-Auth (see "Signing" below), made with a secret the server reads from
a file when it starts. A request without a correct signature is refused with
401, and so is one that repeats an earlier request. Every answer to a request
with a well-formed nonce is signed too, so a caller can tell this server from
another program that took over the port. Without a secret the server does not
start.

Those checks live in this process, so they would not bind code that took it
over. firewall.nft, loaded by entrypoint.sh before this server starts, applies
the same rule to the whole VM, with one exception for DNS to the VM's name
server, and the server then drops root and every Linux
capability so it cannot change the firewall. The Mac's own addresses are in
that firewall as well (entrypoint.sh adds them to the sets blocked4 and
blocked6).
"""

from __future__ import annotations

import codecs
import ctypes
import errno
import gzip
import hashlib
import hmac
import html
import http.client
import io
import ipaddress
import json
import logging
import math
import multiprocessing
import os
import re
import resource
import signal
import socket
import socketserver
import ssl
import stat
import sys
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
import zlib
from collections import Counter, OrderedDict
from dataclasses import dataclass, field
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

try:
    import trafilatura
except ImportError:  # The extractor is optional so tests can run without it.
    trafilatura = None

try:
    import pypdf
    from pypdf import PdfReader
except ImportError:  # Without pypdf a PDF is refused as before; /health says "pdf": false.
    pypdf = PdfReader = None

PORT = int(os.environ.get("PORT", "9100"))
SEARXNG_URL = os.environ.get("SEARXNG_URL", "").rstrip("/")
# Kept unchanged until the q3 comparison, so search results stay comparable.
USER_AGENT = os.environ.get(
    "USER_AGENT",
    "Mozilla/5.0 (compatible; TUFF-web-research/1.0; +https://github.com/rexmhall09/TUFF)")
# Each wait for a connection or data. Some official sites (Bank Indonesia)
# take over 20 s to answer, so 15 s cut them off.
FETCH_TIMEOUT = float(os.environ.get("FETCH_TIMEOUT", "30"))
# The whole request, so a server that drips one byte at a time cannot hold a
# fetch open; FETCH_TIMEOUT alone only limits each wait.
FETCH_DEADLINE = float(os.environ.get("FETCH_DEADLINE", "45"))
# One /v1/fetch (or search) in all: the name lookups, connections and reads of
# every redirect hop together. FETCH_DEADLINE alone is per hop, and with five
# redirects a hostile site could hold a request six times as long.
FETCH_TOTAL_DEADLINE = float(os.environ.get("FETCH_TOTAL_DEADLINE", "90"))
# Extraction runs in a separate process with its own limit, because a
# hostile page can keep the extractor busy for a long time and Python threads
# cannot be stopped. Only the first MAX_EXTRACT_CHARS of a page are read.
EXTRACT_TIMEOUT = float(os.environ.get("EXTRACT_TIMEOUT", "15"))
MAX_EXTRACT_CHARS = 2_000_000
# The fallback parser (html.parser) runs in a child as well, over fewer
# characters and with a shorter limit than the extractor.
FALLBACK_TIMEOUT = float(os.environ.get("FALLBACK_TIMEOUT", "10"))
MAX_FALLBACK_CHARS = 500_000
MAX_DOWNLOAD_BYTES = int(os.environ.get("MAX_DOWNLOAD_BYTES", str(5 * 1024 * 1024)))
# PDFs are read by pypdf in a child process (see read_pdf_bounded). A PDF may
# be as large as any download; one that is longer is refused, never cut. At
# most MAX_PDF_PAGES pages are read, the child is killed after PDF_TIMEOUT
# seconds, and it may not grow beyond PDF_MEMORY_LIMIT bytes of address space
# (the VM has 1 GiB in all, so the limit must be well below that; a forkserver
# child with the parsers loaded starts at about 80 MiB). One PDF is read at a
# time; a request waits up to PDF_BUSY_WAIT seconds for its turn.
# The text is capped at MAX_EXTRACT_CHARS like any page. No OCR.
MAX_PDF_BYTES = MAX_DOWNLOAD_BYTES
MAX_PDF_PAGES = 50
PDF_TIMEOUT = float(os.environ.get("PDF_TIMEOUT", "15"))
PDF_MEMORY_LIMIT = 512 * 1024 * 1024
PDF_BUSY_WAIT = 20.0
# Per-stream limits for pypdf (its defaults allow 75 to 300 MB of work for one
# stream). A stream over them is not decoded and its page counts as failed.
PDF_STREAM_LIMIT = 20_000_000
# application/pdf is read as a PDF whatever the body (a body that is not one is
# "pdf_unreadable"). A response with a generic or missing type is read as a PDF
# only when its body starts with the PDF magic; no other type is sniffed.
PDF_TYPES = ("application/pdf", "application/x-pdf")
PDF_SNIFFED_TYPES = ("", "application/octet-stream", "binary/octet-stream")
PDF_MAGIC = b"%PDF-"
MAX_REDIRECTS = 5
MAX_REQUEST_BYTES = 64 * 1024
# Seconds a client may stay silent on an open connection (see Handler.timeout).
REQUEST_TIMEOUT = 30
# The whole request (line, headers and body) must arrive within this many
# seconds; the processing of an authenticated request is not limited by it.
READ_DEADLINE = 10.0
# Connections served at the same time. One more is closed without an answer, so
# idle or slow connections cannot use up the VM's process limit.
MAX_CONNECTIONS = 32
# The request line and all headers together, the number of headers, and the
# length of the request target. A caller of this API sends a handful of short
# headers; anything bigger is refused.
MAX_HEAD_BYTES = 16 * 1024
MAX_HEADERS = 50
MAX_TARGET_CHARS = 2048
DEFAULT_SLICE_CHARS = 6000
MAX_SLICE_CHARS = 20000
MAX_SEARCH_RESULTS = 10
PAGE_CACHE_SIZE = 32
# Passage mode (`passages: true`): the page is split into paragraphs, ranked
# against the query with BM25, and a read returns the best ones that fit.
MAX_PASSAGE_CHARS = 600
MIN_PASSAGE_CHARS = 60
MAX_QUERY_CHARS = 4000
PASSAGE_SEPARATOR = "\n[...]\n"
BM25_K1 = 1.5
BM25_B = 0.75
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


SEARCH_RETRY_CODES = {"fetch_failed", "fetch_timeout"}
SEARCH_RETRY_DELAY = 1.0


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

# Addresses the sandbox must never connect to, even when they are public: the
# Mac's own interface addresses. Scripts/research_sandbox.sh writes them, one
# per line, to BLOCKED_FILE_NAME in the folder that holds the secret, and
# main() reads that file once, as root, through load_blocked_file(). The
# addresses are not secret.
BLOCKED_ADDRESSES: frozenset = frozenset()
BLOCKED_FILE_NAME = "blocked-addresses"
MAX_BLOCKED_ADDRESSES = 256
MAX_BLOCKED_FILE_BYTES = 64 * 1024


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
    if ip in BLOCKED_ADDRESSES:
        return False
    return ip.is_global and not ip.is_multicast


def url_scheme(url: str) -> str:
    """The lowercase scheme of `url`, or "" when it cannot be read."""
    try:
        return urllib.parse.urlsplit(url.strip()).scheme.lower()
    except ValueError:
        return ""


def system_resolver(host: str, port: int) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        raise ToolError(f"could not resolve {host}: {error.strerror}", "dns_error", 502)
    except UnicodeError:
        # Empty or over-long labels make the idna codec fail inside getaddrinfo.
        raise ToolError("URL has an invalid host name", "invalid_url")
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
        netloc = self.host_header if self.port == default else f"{self.host_header}:{self.port}"
        return f"{self.scheme}://{netloc}{self.path}"

    @property
    def host_header(self) -> str:
        """The host as it is written in a URL or Host header; an IPv6 literal
        needs its brackets."""
        return f"[{self.host}]" if ":" in self.host else self.host


# Every ASCII character `quote` must leave alone, so that only non-ASCII
# characters change.
ASCII_URL_SAFE = "".join(chr(c) for c in range(0x21, 0x7f))

_NUMBER_LABEL = re.compile(r"[0-9]+|0x[0-9a-f]*")
_NUMBER_LIKE_LABEL = re.compile(r"[0-9]+|0x[0-9a-z]*")
_DOTTED_QUAD_PART = re.compile(r"0|[1-9][0-9]{0,2}")


def is_noncanonical_number(host: str) -> bool:
    """True for a host that C libraries read as an IPv4 address, or that is
    built like one, but is not a plain dotted quad.

    inet_aton and getaddrinfo accept 2130706433, 0x7f000001, 127.1 and
    0177.0.0.1, and they disagree: glibc reads a leading 0 as octal (127.0.0.1)
    where macOS reads it as decimal (177.0.0.1). The policy must not depend on
    that reading, so every such spelling is refused before any lookup. Only
    four decimal parts without leading zeros, each at most 255, are an
    address; a host whose last label is a number, or whose labels are all
    numbers, is never a name (no top-level domain is numeric). IPv6 literals
    and names with a letter in their last label are not affected.
    """
    if ":" in host:
        return False
    labels = host.split(".")
    if not (_NUMBER_LABEL.fullmatch(labels[-1])
            or all(_NUMBER_LIKE_LABEL.fullmatch(label) for label in labels)):
        return False
    if len(labels) == 4 and all(_DOTTED_QUAD_PART.fullmatch(label) for label in labels):
        try:
            ipaddress.IPv4Address(host)
        except ValueError:
            return True
        return False
    return True


def check_url(url: str, resolver: Callable[[str, int], list[str]]) -> Target:
    """Parses `url` and pins it to one public address, or refuses it."""
    if not isinstance(url, str) or len(url) > 4096:
        raise ToolError("url must be a string of at most 4096 characters", "invalid_url")
    try:
        parts = urllib.parse.urlsplit(url.strip())
    except ValueError:
        # Malformed addresses such as "http://[::1/" or a fullwidth "@".
        raise ToolError("URL is not a valid address", "invalid_url")
    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_PORTS:
        raise ToolError("only http and https URLs can be fetched", "invalid_url")
    if parts.username or parts.password:
        raise ToolError("URLs with credentials are refused", "invalid_url")
    if (CONTROL_CHARACTERS.search(url) or has_format_character(url)
            or any(c.isspace() for c in url.strip())):
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
        # The ideographic, fullwidth and halfwidth full stops (U+3002, U+FF0E,
        # U+FF61) became ASCII dots in the step above, so the trailing one is
        # dropped here, before the number check and the lookup see the host.
        host = host.rstrip(".")
        if not host:
            raise ToolError("URL has no host", "invalid_url")
    try:
        port = parts.port or ALLOWED_PORTS[scheme]
    except ValueError:
        raise ToolError("URL has an invalid port", "invalid_url")
    if port != ALLOWED_PORTS[scheme]:
        raise ToolError(f"only port {ALLOWED_PORTS[scheme]} is allowed for {scheme}", "blocked_port")
    # Before any lookup: libc's reading of these spellings differs between
    # systems (see is_noncanonical_number), so none of them is trusted.
    if is_noncanonical_number(host):
        raise ToolError("URL has a number as host that is not a plain dotted IPv4 address",
                        "invalid_url")
    addresses = resolver(host, port)
    if not addresses:
        raise ToolError(f"could not resolve {host}", "dns_error", 502)
    # Every answer must be public: picking the one public answer out of a
    # mixed set would still let a rebinding name aim at the host next time.
    blocked = [a for a in addresses if not is_public_address(a)]
    if blocked:
        raise ToolError(f"{host} resolves to a non-public address", "blocked_address", 403)
    # http.client refuses non-ASCII request lines; send them as UTF-8 escapes,
    # as a browser does. Existing %XX escapes and ASCII are left as they are.
    path = urllib.parse.quote(parts.path or "/", safe=ASCII_URL_SAFE)
    if parts.query:
        path += "?" + urllib.parse.quote(parts.query, safe=ASCII_URL_SAFE)
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


# Called with (method, target, headers, body) and the keyword argument
# `deadline`.
Transport = Callable[..., Response]


class _SendOnlyGivenHeaders:
    """http.client adds `Accept-Encoding: identity` to a request that has no
    Accept-Encoding header. The transport sends the headers it is given and
    nothing else."""

    # The event pinned_transport's deadline timer sets; connect() looks at it.
    expired: threading.Event | None = None

    def putrequest(self, method, url, skip_host=False, skip_accept_encoding=False):
        return super().putrequest(method, url, skip_host, True)


class _PinnedHTTPConnection(_SendOnlyGivenHeaders, http.client.HTTPConnection):
    def __init__(self, target: Target, timeout: float):
        super().__init__(target.host, target.port, timeout=timeout)
        self._address = target.address

    def connect(self):
        self.sock = socket.create_connection((self._address, self.port), self.timeout)


class _PinnedHTTPSConnection(_SendOnlyGivenHeaders, http.client.HTTPSConnection):
    def __init__(self, target: Target, timeout: float):
        super().__init__(target.host, target.port, timeout=timeout,
                         context=ssl.create_default_context())
        self._address = target.address

    def connect(self):
        sock = socket.create_connection((self._address, self.port), self.timeout)
        # The socket is stored before the handshake, so the deadline timer can
        # shut it down while the handshake waits (wrap_socket would detach
        # `sock` and keep it out of the timer's reach until it returned).
        secure = self._context.wrap_socket(sock, server_hostname=self.host,
                                           do_handshake_on_connect=False)
        self.sock = secure
        if self.expired is not None and self.expired.is_set():
            raise OSError("the deadline passed before the handshake")
        try:
            secure.do_handshake()
        except AttributeError:
            # The timer's shutdown() ran between the check and the handshake.
            raise OSError("the deadline passed during the handshake") from None


def pinned_transport(method: str, target: Target, headers: dict[str, str],
                     body: bytes | None, deadline: float | None = None) -> Response:
    """`deadline` bounds the whole request in seconds. The body that is read
    is capped at MAX_DOWNLOAD_BYTES; a longer one comes back as `truncated`."""
    cls = _PinnedHTTPSConnection if target.scheme == "https" else _PinnedHTTPConnection
    limit = FETCH_DEADLINE if deadline is None else deadline
    cap = MAX_DOWNLOAD_BYTES
    # A wait longer than the deadline is cut by the timer; one second more
    # lets the timer win the race and report a timeout, not a failed connect.
    connection = cls(target, min(FETCH_TIMEOUT, limit + 1))
    expired = threading.Event()
    connection.expired = expired

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
        # Connect first, so that a connection or handshake that ends after the
        # timer fired is noticed. The timer can only shut down a socket that
        # exists; once it does, it wakes any later wait.
        connection.connect()
        if expired.is_set():
            raise too_slow
        connection.request(method, target.path, body=body, headers=headers)
        response = connection.getresponse()
        received = {k.lower(): v for k, v in response.getheaders()}
        # The dictionary above keeps one value per name, so a second Location
        # header would go unseen. Which of two addresses a client follows
        # differs between clients; this one follows neither.
        if sum(1 for name, _ in response.getheaders() if name.lower() == "location") > 1:
            raise ToolError(f"{target.host} sent more than one redirect address",
                            "fetch_failed", 502)
        chunks, size = [], 0
        while size <= cap and not expired.is_set():
            chunk = response.read1(min(65536, cap + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if expired.is_set():
            raise too_slow
        data = b"".join(chunks)
        return Response(
            status=response.status,
            headers=received,
            body=data[:cap],
            truncated=len(data) > cap)
    except (OSError, http.client.HTTPException, ValueError) as error:
        if expired.is_set():
            raise too_slow
        raise ToolError(f"request to {target.host} failed: {error}", "fetch_failed", 502)
    finally:
        timer.cancel()
        connection.close()


def decode_body(response: Response, limit: int | None = None, cut: bool = False) -> bytes:
    """The body, unpacked when the site sent it gzip or deflate (the sandbox
    asks for gzip, and some sites send either unasked). A body that unpacks
    to more than `limit` bytes is refused (`oversized`), or with `cut` cut
    at `limit` and marked `truncated`, as an identity body is. Never more
    than limit+1 bytes are unpacked."""
    limit = MAX_DOWNLOAD_BYTES if limit is None else limit
    encoding = response.headers.get("content-encoding", "identity").lower()
    if encoding in ("", "identity"):
        return response.body
    if encoding not in ("gzip", "deflate"):
        raise ToolError(f"unsupported content encoding {encoding}", "unsupported_content")
    wbits = 16 + zlib.MAX_WBITS if encoding == "gzip" else zlib.MAX_WBITS
    try:
        inflater = zlib.decompressobj(wbits)
        # Bounded so a small compressed bomb cannot fill the VM's memory: one
        # byte past the limit is enough to know the body is too long.
        data = inflater.decompress(response.body, limit + 1)
    except (zlib.error, gzip.BadGzipFile):
        raise ToolError("response body could not be decompressed", "unsupported_content", 502)
    if len(data) > limit:
        if not cut:
            raise ToolError(f"the body is larger than {limit} bytes", "oversized", 502)
        response.truncated = True
        return data[:limit]
    return data


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
# hyphen, zero-width characters, fillers, the byte order mark, the Unicode
# tag block and the variation selectors other than U+FE0F, which can spell out
# instructions the model reads but a person reviewing the text cannot see.
# The emoji variation selector U+FE0F is ordinary text and stays.
CONTROL_CHARACTERS = re.compile(
    "[\x00-\x08\x0b-\x1f\x7f-\x9f\xad\u034f\u061c\u115f\u1160\u17b4\u17b5"
    "\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u2069\u2800\u3164\ufe00-\ufe0e\ufeff"
    "\uffa0\U000e0000-\U000e007f\U000e0100-\U000e01ef]")


# Every Unicode format character (category Cf) is removed as well: the list
# above misses about fifty of them (U+206A-206F, U+FFF9-FFFB, U+070F, the
# Egyptian hieroglyph and shorthand format controls, ...). Built once at
# import (about 0.2 s); applying it to a 240 000 character page takes under
# a millisecond. Arabic number signs (U+0600-0605, U+06DD, U+08E2) are
# visible but rare and are dropped with the rest.
FORMAT_CHARACTERS = {
    cp: None for cp in range(sys.maxunicode + 1) if unicodedata.category(chr(cp)) == "Cf"}


def has_format_character(text: str) -> bool:
    return any(unicodedata.category(c) == "Cf" for c in text)


def clean_text(text: str) -> str:
    for separator in ("\r\n", "\r", "\u2028", "\u2029"):
        text = text.replace(separator, "\n")
    return CONTROL_CHARACTERS.sub("", text.translate(FORMAT_CHARACTERS))


def collapse_whitespace(text: str) -> str:
    """Runs of blanks inside a line become one space, lines are stripped and
    three or more line breaks become two. Every pattern here is a plain run
    (linear), so a line of millions of blanks costs one pass."""
    lines = (re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in text.split("\n"))
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


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
        return collapse_whitespace("".join(self.parts))


def clean_title(title: str) -> str:
    return clean_text(re.sub(r"\s+", " ", title)).strip()[:300]


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
    return clean_title(html.unescape(head[match.end():end]))


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
    # Raw UTF-8 bytes, never a pickle: the child parses hostile pages, and
    # unpickling what it sends would let an exploited parser run code in the
    # server. An empty message means "failed" and the parent falls back.
    try:
        text = extractor(markup, url)
        sender.send_bytes(b"\x01" + text.encode("utf-8", "replace") if isinstance(text, str) else b"")
    except Exception:
        sender.send_bytes(b"")
    finally:
        sender.close()


def _fallback_in_child(markup: str, url: str) -> str:
    return fallback_text(markup)


def _child_message(target, args: tuple, timeout: float, limit: int) -> bytes | None:
    """The one message `target(sender, *args)` sends from a child process, or
    None when the child sends nothing, dies or is still busy after `timeout`
    seconds (it is killed then). Raw bytes only, never a pickle: the child
    parses hostile files, and unpickling what it sends would let an exploited
    parser run code in the server. recv_bytes never unpickles; `limit` bounds
    what is read."""
    context = multiprocessing.get_context("forkserver")
    receiver, sender = context.Pipe(duplex=False)
    child = context.Process(target=target, args=(sender, *args), daemon=True)
    child.start()
    sender.close()
    message = None
    # poll() returns once data starts to arrive, and recv_bytes() then waits
    # for the rest of the message; a child that stalls half way is killed here
    # (the read then ends with EOFError) instead of holding this thread.
    watchdog = threading.Timer(timeout + 1, child.kill)
    watchdog.daemon = True
    watchdog.start()
    try:
        if receiver.poll(timeout):
            message = receiver.recv_bytes(limit)
    except (EOFError, OSError):
        pass
    finally:
        watchdog.cancel()
        receiver.close()
        if child.is_alive():
            child.kill()
        child.join(5)
    return message


def _run_in_child(extractor, markup: str, url: str, timeout: float) -> str | None:
    """`extractor(markup, url)` run in a child process that is killed after
    `timeout` seconds. None when it fails, returns no text or runs out of time."""
    message = _child_message(_extract_in_child, (extractor, markup, url), timeout,
                             4 * MAX_EXTRACT_CHARS + 1)
    if message is not None and message.startswith(b"\x01"):
        return clean_text(message[1:].decode("utf-8", "replace"))
    return None


def extract_text_bounded(markup: str, url: str, timeout: float | None = None,
                         extractor: Callable[[str, str], str] = extract_text) -> str:
    """Runs `extractor` in a child process and stops it after `timeout`
    seconds. A page the extractor cannot finish in time, or fails on, is read
    with the simple fallback parser instead. That is html.parser, which has had
    quadratic cases (CVE-2025-6069), so it runs the same way: in a child with
    its own limit and over fewer characters. A page it cannot finish either
    gives no text, never an unbounded wait in this process."""
    markup = markup[:MAX_EXTRACT_CHARS]
    text = _run_in_child(extractor, markup, url, EXTRACT_TIMEOUT if timeout is None else timeout)
    if text is not None:
        return text
    sys.stderr.write("extraction timed out or failed; used the fallback parser\n")
    text = _run_in_child(_fallback_in_child, markup[:MAX_FALLBACK_CHARS], url, FALLBACK_TIMEOUT)
    if text is None:
        sys.stderr.write("the fallback parser could not read the page either; no text\n")
        return ""
    return text


# --- PDF --------------------------------------------------------------------

class PdfRefused(Exception):
    """A PDF that is read no further, with the tool error code to report."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def read_pdf(data: bytes) -> dict:
    """Runs in the child. The text of at most MAX_PDF_PAGES pages, each cleaned
    like HTML text, plus the document title and the page counts. Never
    decrypts: an encrypted PDF is refused, whatever its password."""
    if PdfReader is None:
        raise PdfRefused("pdf_unreadable")
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    pypdf.overwrite_configuration(
        maximum_declared_stream_length=PDF_STREAM_LIMIT,
        array_based_stream_maximum_output_length=PDF_STREAM_LIMIT,
        jbig2_maximum_output_length=PDF_STREAM_LIMIT,
        lzw_maximum_output_length=PDF_STREAM_LIMIT,
        run_length_maximum_output_length=PDF_STREAM_LIMIT,
        zlib_maximum_output_length=PDF_STREAM_LIMIT,
        brotli_maximum_output_length=PDF_STREAM_LIMIT,
        image_maximum_buffer_size=PDF_STREAM_LIMIT,
        stream_decoding_work_maximum_length=4 * PDF_STREAM_LIMIT,
        jbig2dec_binary=None,  # never start an external program
    )
    reader = PdfReader(io.BytesIO(data), strict=False)
    if reader.is_encrypted:
        raise PdfRefused("pdf_encrypted")
    total = len(reader.pages)
    title = ""
    try:
        title = str(reader.metadata.title or "")[:1000] if reader.metadata else ""
    except Exception:
        pass
    parts: list[str] = []
    chars = pages_read = pages_failed = 0
    cut = False
    for number in range(min(total, MAX_PDF_PAGES)):
        pages_read += 1
        try:
            text = collapse_whitespace(clean_text(reader.pages[number].extract_text() or ""))
        except Exception:
            pages_failed += 1  # one odd page does not cost the rest
            continue
        if len(text) > MAX_EXTRACT_CHARS - chars:
            text, cut = text[:MAX_EXTRACT_CHARS - chars], True
        if text:
            parts.append(text)
            chars += len(text)
        if cut:
            break
    return {"title": title, "text": "\n\n".join(parts), "pages": total,
            "pages_read": pages_read, "pages_failed": pages_failed, "cut": cut}


def _pdf_in_child(sender, reader, data: bytes) -> None:
    # \x01 + JSON on success, \x02 + an error code on a refusal; anything else
    # (a crash, a kill, no message) is "unreadable". Parsed with json, never pickle.
    try:
        try:
            resource.setrlimit(resource.RLIMIT_AS, (PDF_MEMORY_LIMIT, PDF_MEMORY_LIMIT))
        except (ValueError, OSError):
            pass  # not every system allows it; the VM's own limits still apply
        try:
            result = reader(data)
            sender.send_bytes(b"\x01" + json.dumps(result, ensure_ascii=False).encode("utf-8", "replace"))
        except PdfRefused as refusal:
            sender.send_bytes(b"\x02" + refusal.code.encode("ascii"))
        except Exception:
            sender.send_bytes(b"\x02pdf_unreadable")
    finally:
        sender.close()


_PDF_SLOT = threading.BoundedSemaphore(1)


def read_pdf_bounded(data: bytes, timeout: float | None = None,
                     reader: Callable[[bytes], dict] = read_pdf) -> dict:
    """`reader(data)` in a child process that is killed after `timeout`
    seconds. Returns {"title", "text", "pages", "pages_read", "pages_failed",
    "cut"} with text and title cleaned again here (the child is not trusted),
    or raises ToolError: pdf_encrypted, or pdf_unreadable for a PDF that is
    malformed or could not be read in time, or pdf_busy (503) when another
    PDF has been read for longer than PDF_BUSY_WAIT seconds."""
    limit = PDF_TIMEOUT if timeout is None else timeout
    unreadable = ToolError("the PDF could not be read: it is damaged, or reading it took longer "
                           f"than {limit:g} s", "pdf_unreadable")
    # One PDF at a time: each child may use PDF_MEMORY_LIMIT, and the VM is small.
    if not _PDF_SLOT.acquire(timeout=PDF_BUSY_WAIT):
        raise ToolError("another PDF is being read; try again in a moment", "pdf_busy", 503)
    try:
        message = _child_message(_pdf_in_child, (reader, data), limit, 4 * MAX_EXTRACT_CHARS + 65536)
    finally:
        _PDF_SLOT.release()
    if message is None:
        raise unreadable
    if message.startswith(b"\x02"):
        code = message[1:].decode("ascii", "replace")
        if code == "pdf_encrypted":
            raise ToolError("the PDF is encrypted; encrypted PDFs are not read", code)
        raise unreadable
    try:
        # Any exception: a deeply nested answer raises RecursionError, not ValueError.
        result = json.loads(message[1:]) if message.startswith(b"\x01") else None
        title, text = result["title"], result["text"]
        counts = [result[key] for key in ("pages", "pages_read", "pages_failed")]
        if (not isinstance(title, str) or not isinstance(text, str) or type(result["cut"]) is not bool
                or not all(type(n) is int and n >= 0 for n in counts)):
            raise ValueError("unexpected types")
    except Exception:
        raise unreadable from None
    result["title"] = clean_title(title)
    result["text"] = collapse_whitespace(clean_text(text[:MAX_EXTRACT_CHARS]))
    return result


def last_path_segment(url: str) -> str:
    segment = urllib.parse.unquote(urllib.parse.urlsplit(url).path.rstrip("/").rsplit("/", 1)[-1])
    return clean_title(segment)


def pdf_page(url: str, body: bytes) -> "Page":
    """A Page from a PDF's bytes. Its text is cleaned like HTML text (see
    read_pdf_bounded) and carries a closing note when pages were left out. The
    title is the document's own, else the last part of the address."""
    result = read_pdf_bounded(body)
    notes = []
    if result["pages_read"] < result["pages"]:
        notes.append(f"only the first {result['pages_read']} of {result['pages']} pages were read")
    if result["pages_failed"]:
        notes.append(f"{result['pages_failed']} pages could not be read")
    if result["cut"]:
        notes.append(f"the text was cut after {MAX_EXTRACT_CHARS} characters")
    text = result["text"]
    if not text:
        if result["pages_failed"] and result["pages_failed"] >= result["pages_read"]:
            raise ToolError("the PDF's pages could not be read", "pdf_unreadable")
        raise ToolError("the PDF has no text that can be read (scanned pages are not read; "
                        "there is no OCR)", "pdf_unreadable")
    if notes:
        text += f"\n\n[PDF note: {'; '.join(notes)}.]"
    return Page(url, result["title"] or last_path_segment(url), text)


# --- Passages ---------------------------------------------------------------

# Words that say nothing about a page's topic, in German and English. They are
# left out of the query only; a page may use them freely.
PASSAGE_STOP_WORDS = frozenset("""
der die das den dem des ein und ist im in am an auf aus bei für fuer zu um als es er sie wir ihr
the and are for was not but can has how who
aber alle allem allen aller alles also auch dass dein deine denn dies diese
dieser dieses doch durch eine einem einen einer eines etwa gibt habe haben hier
ihre ihrem ihren ihrer jetzt kann kein keine koennen können machen mehr mich mit
nach nicht noch oder ohne sehr sein seine sich sind soll sollen über unter viel
vom von war waren wann warum was welche welcher welches wenn wer wie wieder wird
wir wurde wurden zum zur zwischen
about after also been being does from have into more only over such than that
their them then there these they this very were what when where which while will
with would your
""".split())


def passage_stem(word: str) -> str:
    """A word cut to its first six characters, so "Zeitungen" finds "Zeitung"
    and "political" finds "politics". Digits stay whole."""
    return word if word.isdigit() else word[:6]


def passage_terms(text: str) -> list[str]:
    return [passage_stem(word) for word in re.findall(r"[^\W_]+", text.lower())]


def query_terms(query: str) -> list[str]:
    """The distinct stems of a query in first-seen order, without stop words
    and one-letter words."""
    terms: list[str] = []
    for word in re.findall(r"[^\W_]+", query.lower()):
        if word in PASSAGE_STOP_WORDS or (len(word) < 3 and not word.isdigit()):
            continue
        stem = passage_stem(word)
        if stem not in terms:
            terms.append(stem)
    return terms


NON_BLANK = re.compile(r"\S")


def split_passages(text: str) -> list[tuple[int, int]]:
    """Paragraphs of a page as (start, end) character positions in `text`.

    A line is a paragraph. A line shorter than MIN_PASSAGE_CHARS (a heading, a
    date) is joined with the lines after it, so it stays with its section.
    A paragraph longer than MAX_PASSAGE_CHARS is cut after a sentence, or at a
    space when no sentence ends in its first part. The pieces are exact slices
    of `text`, in page order, and do not overlap.
    """
    # Line by line, never with a pattern like `[^\n]*\S[^\n]*`: on a line of
    # millions of blanks that pattern rescans the rest of the line at every
    # position (quadratic, hours, and it holds the interpreter lock).
    lines: list[tuple[int, int]] = []  # first and end of the text of a non-blank line
    offset = 0
    for line in text.split("\n"):
        body = line.lstrip()
        if body:
            first = offset + len(line) - len(body)
            lines.append((first, first + len(body.rstrip())))
        offset += len(line) + 1
    paragraphs: list[tuple[int, int]] = []
    index = 0
    while index < len(lines):
        start, end = lines[index]
        index += 1
        while index < len(lines) and end - start < MIN_PASSAGE_CHARS:
            end = lines[index][1]
            index += 1
        paragraphs.append((start, end))
    pieces: list[tuple[int, int]] = []
    for start, end in paragraphs:
        while True:
            # A paragraph ends on text already; skip the blanks a cut leaves in
            # front of the next piece (a C-level scan, not a Python loop).
            first = NON_BLANK.search(text, start, end)
            if first is None:
                break
            start = first.start()
            if end - start <= MAX_PASSAGE_CHARS:
                pieces.append((start, end))
                break
            window = text[start:start + MAX_PASSAGE_CHARS]
            cut = max((window.rfind(mark) + 1 for mark in (". ", "! ", "? ", ".\n", "!\n", "?\n")
                       if window.rfind(mark) >= MAX_PASSAGE_CHARS // 4), default=0)
            if not cut:
                cut = window.rfind(" ")
                if cut < MAX_PASSAGE_CHARS // 4:
                    cut = MAX_PASSAGE_CHARS
            pieces.append((start, start + cut))
            start += cut
    return pieces


def rank_passages(text: str, query: str) -> list[tuple[int, int]]:
    """The passages of `text` best first by BM25 against `query`. Passages
    with the same score keep page order, and passages with no query word
    follow the others in page order, so a query with no match reads the page
    from the start. The same text and query always give the same order."""
    pieces = split_passages(text)
    terms = query_terms(query)
    if not terms:
        return pieces
    counts = [Counter(passage_terms(text[start:end])) for start, end in pieces]
    lengths = [sum(count.values()) for count in counts]
    average = (sum(lengths) / len(lengths)) or 1.0
    scores = [0.0] * len(pieces)
    for term in terms:
        holding = sum(1 for count in counts if term in count)
        if not holding:
            continue
        idf = math.log(1 + (len(pieces) - holding + 0.5) / (holding + 0.5))
        for position, count in enumerate(counts):
            frequency = count.get(term, 0)
            if frequency:
                norm = frequency + BM25_K1 * (1 - BM25_B + BM25_B * lengths[position] / average)
                scores[position] += idf * frequency * (BM25_K1 + 1) / norm
    order = sorted(range(len(pieces)), key=lambda position: (-scores[position], position))
    return [pieces[position] for position in order]


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
    clock: Callable[[], float] = time.monotonic

    def request(self, method: str, url: str, body: bytes | None = None,
                content_type: str | None = None) -> tuple[str, Response]:
        """Follows up to MAX_REDIRECTS redirects, checking every hop. One
        deadline, FETCH_TOTAL_DEADLINE, covers all hops; each hop also keeps
        the shorter FETCH_DEADLINE."""
        expires = self.clock() + FETCH_TOTAL_DEADLINE
        too_slow = ToolError(f"the request took longer than {FETCH_TOTAL_DEADLINE:g} s",
                             "fetch_timeout", 504)
        current = url
        for _ in range(MAX_REDIRECTS + 1):
            target = self._checked_target(current, expires - self.clock(), too_slow, check_url)
            remaining = expires - self.clock()
            if remaining <= 0:
                raise too_slow
            headers = {
                "Host": target.host_header,
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,application/pdf;q=0.8,*/*;q=0.1",
                "Accept-Encoding": "gzip",
                "Accept-Language": "en;q=0.9,*;q=0.5",
            }
            if content_type:
                headers["Content-Type"] = content_type
            response = self.transport(method, target, headers, body,
                                      deadline=min(FETCH_DEADLINE, remaining))
            if response.status in (301, 302, 303, 307, 308):
                location = (response.headers.get("location") or "").strip()
                if not location:
                    raise ToolError("redirect without a location", "fetch_failed", 502)
                current = urllib.parse.urljoin(target.url, location)
                # One rule for every request this tool makes, pages and search
                # alike: a page read over https is never sent on over http.
                if target.scheme == "https" and url_scheme(current) == "http":
                    raise ToolError("a redirect from https to http was refused",
                                    "insecure_redirect", 502)
                if response.status == 303 or (response.status in (301, 302) and method == "POST"):
                    method, body, content_type = "GET", None, None
                continue
            return target.url, response
        raise ToolError("too many redirects", "too_many_redirects", 502)

    def _checked_target(self, url, remaining: float, too_slow: ToolError,
                        check: Callable[..., Target] = check_url) -> Target:
        """`check`, but given up on when the name lookup outlasts the deadline. The lookup
        cannot be stopped; its thread ends when the resolver gives up (some 10
        to 30 s), and counts against the VM's process limit until then."""
        if remaining <= 0:
            raise too_slow
        outcome: dict = {}

        def run():
            try:
                outcome["target"] = check(url, self.resolver)
            except BaseException as error:
                outcome["error"] = error

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        worker.join(remaining)
        if worker.is_alive():
            raise too_slow
        if "error" in outcome:
            raise outcome["error"]
        return outcome["target"]

    def load_page(self, url: str) -> Page:
        with self.lock:
            if url in self.cache:
                self.cache.move_to_end(url)
                return self.cache[url]
        final_url, response = self.request("GET", url)
        if response.status >= 400:
            raise ToolError(f"{final_url} answered HTTP {response.status}", "http_error", 502)
        content_type = response.headers.get("content-type", "").lower()
        kind = content_type.split(";")[0].strip()
        is_pdf = False
        if not content_type.startswith(TEXT_TYPES):
            if PdfReader is not None and (kind in PDF_TYPES or kind in PDF_SNIFFED_TYPES):
                body = decode_body(response)
                is_pdf = kind in PDF_TYPES or body.startswith(PDF_MAGIC)
            if not is_pdf:
                raise ToolError(f"{final_url} is {kind or 'unknown'}, not a web page",
                                "unsupported_content")
        if is_pdf:
            # A PDF cut at the size limit cannot be read, so it is refused. A
            # body that fills the limit exactly after decompression was cut too.
            if (response.truncated or len(body) > MAX_PDF_BYTES
                    or (len(body) >= MAX_DOWNLOAD_BYTES
                        and response.headers.get("content-encoding", "identity").lower()
                        not in ("", "identity"))):
                raise ToolError(f"{final_url} is a PDF larger than {MAX_PDF_BYTES} bytes",
                                "oversized", 502)
            page = pdf_page(final_url, body)
        else:
            body = decode_body(response, cut=True)
            raw = body.decode(page_charset(content_type, body), errors="replace")
            page = self._html_page(final_url, content_type, raw)
        with self.lock:
            for key in {url, final_url}:
                self.cache[key] = page
                self.cache.move_to_end(key)
            while len(self.cache) > PAGE_CACHE_SIZE:
                self.cache.popitem(last=False)
        return page

    @staticmethod
    def _html_page(final_url: str, content_type: str, raw: str) -> Page:
        if content_type.startswith("text/plain"):
            # Runs of blanks are collapsed as in the fallback parser, so a page
            # of millions of spaces is not kept (or searched) as such.
            return Page(final_url, "", collapse_whitespace(clean_text(raw)))
        return Page(final_url, extract_title(raw), extract_text_bounded(raw, final_url))

    def fetch(self, url: str, offset: int = 0, max_chars: int = DEFAULT_SLICE_CHARS,
              passages: bool = False, query: str = "") -> dict:
        if not isinstance(offset, int) or isinstance(offset, bool) or offset < 0:
            raise ToolError("offset must be a non-negative integer", "invalid_argument")
        if not isinstance(max_chars, int) or not 1 <= max_chars <= MAX_SLICE_CHARS:
            raise ToolError(f"max_chars must be between 1 and {MAX_SLICE_CHARS}", "invalid_argument")
        if not isinstance(passages, bool):
            raise ToolError("passages must be true or false", "invalid_argument")
        if not isinstance(query, str) or len(query) > MAX_QUERY_CHARS:
            raise ToolError(f"query must be text of at most {MAX_QUERY_CHARS} characters",
                            "invalid_argument")
        page = self.load_page(url)
        total = len(page.text)
        if passages:
            return self._passage_slice(page, offset, max_chars, query)
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

    def _passage_slice(self, page: Page, offset: int, max_chars: int, query: str) -> dict:
        """The next best passages that fit `max_chars`. Here `offset` counts
        passages already given, best first, so a read that continues an
        earlier one passes that read's `next_offset`. The passages of a read
        come back in page order, each with its position in the page."""
        ranked = rank_passages(page.text, query)
        index_of = {span: number for number, span in enumerate(split_passages(page.text))}
        first = min(offset, len(ranked))
        chosen: list[tuple[int, int, int]] = []
        used = 0
        position = first
        while position < len(ranked):
            start, end = ranked[position]
            number = index_of[(start, end)]
            if not chosen and end - start > max_chars:
                end = start + max_chars  # a limit below one passage cuts it
            cost = (end - start) + (len(PASSAGE_SEPARATOR) if chosen else 0)
            if chosen and used + cost > max_chars:
                break
            chosen.append((start, end, number))
            used += cost
            position += 1
        chosen.sort()
        parts = [{"index": number, "start": start, "end": end, "text": page.text[start:end]}
                 for start, end, number in chosen]
        # Pieces that follow each other on the page are joined by a line break
        # and need no separator; others get one, so the text never suggests
        # that two parts of a page stood together.
        text = ""
        for number, part in enumerate(parts):
            if number:
                neighbours = part["index"] == parts[number - 1]["index"] + 1
                text += "\n" if neighbours else PASSAGE_SEPARATOR
            text += part["text"]
        return {
            "url": page.url,
            "title": page.title,
            "mode": "passages",
            "passages": parts,
            "text": text,
            "offset": first,
            "next_offset": position if position < len(ranked) else None,
            "passage_count": len(ranked),
            "total_chars": len(page.text),
        }

    def search(self, query: str, max_results: int = 6) -> dict:
        if not isinstance(query, str) or not query.strip() or len(query) > 400:
            raise ToolError("query must be 1 to 400 characters", "invalid_argument")
        if not isinstance(max_results, int) or not 1 <= max_results <= MAX_SEARCH_RESULTS:
            raise ToolError(f"max_results must be between 1 and {MAX_SEARCH_RESULTS}",
                            "invalid_argument")
        backend = self._searxng if self.searxng_url else self._duckduckgo
        try:
            results = backend(query)
        except ToolError as error:
            # A dropped connection or a stalled answer is often a one-off on
            # the search engine's side; try once more before giving up.
            if error.code not in SEARCH_RETRY_CODES:
                raise
            time.sleep(SEARCH_RETRY_DELAY)
            results = backend(query)
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
        # html.parser runs here, in this process, so it reads a bounded amount
        # (a results page is some 100 KB).
        markup = decode_body(response).decode("utf-8", errors="replace")[:MAX_FALLBACK_CHARS]
        return parse_duckduckgo(markup)

    def _searxng(self, query: str) -> list[dict]:
        # SearXNG is the operator's own service, usually another container on a
        # private address, so it is the one destination exempt from the
        # public-address rule. Only its fixed search path is ever requested.
        url = f"{self.searxng_url}/search?" + urllib.parse.urlencode(
            {"q": query, "format": "json"})
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with SEARXNG_OPENER.open(request, timeout=FETCH_TIMEOUT) as response:
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


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx comes back as an error, never as a second request


# SearXNG is the one destination the address rule does not cover, so its
# request follows no redirect (which could lead anywhere the firewall allows)
# and uses no proxy from the environment.
SEARXNG_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirects())


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
            and not CONTROL_CHARACTERS.search(url) and not has_format_character(url)
            and not any(c.isspace() for c in url))


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


# --- Signing ----------------------------------------------------------------
#
# The launcher makes a random secret each time the sandbox starts and puts it in
# a file that the VM sees read-only; this process reads it once, before it
# drops root. Every request carries a fresh random nonce, the time, and
#   X-Sandbox-Auth: hex(HMAC-SHA256(secret, join("\n", [
#       "sandseek-sandbox-req-v1", method, path, nonce, time,
#       hex(SHA256(request body))])))
# A request without a correct signature is refused, so a program that can
# reach the port but cannot read the secret gets nothing out of the sandbox.
# The time must be within a minute of this clock, and a nonce is accepted once
# only, so a recorded request cannot be sent again.
#
# Every answer to a request with a well-formed nonce, errors too, carries
#   X-Sandbox-Auth: hex(HMAC-SHA256(secret, join("\n", [
#       "sandseek-sandbox-resp-v1", method, path, nonce, status,
#       hex(SHA256(answer body))])))
# A program that merely sits on the port cannot make that, because the secret
# never crosses the port. The method, path and nonce stop a genuine answer to
# one request from being passed off as the answer to another. A GET has no
# body, so it uses the hash of nothing.
#
# The key is the secret file's bytes, without one trailing newline. Test
# vectors: test-vectors/signing.json.

REQUEST_LABEL = "sandseek-sandbox-req-v1"
RESPONSE_LABEL = "sandseek-sandbox-resp-v1"
NONCE_HEADER = "X-Sandbox-Nonce"
TIME_HEADER = "X-Sandbox-Time"
AUTH_HEADER = "X-Sandbox-Auth"
NONCE_PATTERN = re.compile(r"[0-9a-fA-F]{64}")
TIME_PATTERN = re.compile(r"[0-9]{1,12}")
AUTH_PATTERN = re.compile(r"[0-9a-fA-F]{64}")
TIME_WINDOW = 60
MIN_SECRET_BYTES = 32
MAX_SECRET_BYTES = 4096
DEFAULT_SECRET_FILE = "/run/sandseek-sandbox/secret"
NONCE_CAPACITY = 100_000


def request_signature(secret: bytes, method: str, path: str, nonce: str, timestamp: str,
                      body: bytes) -> str:
    text = "\n".join((REQUEST_LABEL, method, path, nonce, timestamp,
                      hashlib.sha256(body).hexdigest()))
    return hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()


def response_signature(secret: bytes, method: str, path: str, nonce: str, status: int,
                       body: bytes) -> str:
    text = "\n".join((RESPONSE_LABEL, method, path, nonce, str(status),
                      hashlib.sha256(body).hexdigest()))
    return hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()


def load_secret(path: str) -> bytes:
    """The secret in a file, without one trailing newline. It exits when the
    file is missing, not a regular file, or too short or long, with a message
    that never holds the secret. Called once, as root, before privileges are
    dropped; the file is not read again."""
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        sys.exit(f"cannot open the secret file: {error.strerror}; refusing to start")
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            sys.exit("the secret file is not a regular file; refusing to start")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            # Two bytes more than the longest secret: one trailing newline is
            # stripped, and a second one then still makes it too long.
            value = handle.read(MAX_SECRET_BYTES + 2)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    value = value.removesuffix(b"\n")
    if len(value) > MAX_SECRET_BYTES:
        sys.exit(f"the secret is longer than {MAX_SECRET_BYTES} bytes; refusing to start")
    if len(value) < MIN_SECRET_BYTES:
        sys.exit(f"the secret is shorter than {MIN_SECRET_BYTES} bytes; refusing to start")
    return value


# --- Blocked addresses ------------------------------------------------------

def load_blocked_addresses(text: str) -> frozenset:
    """The addresses in `text`, separated by commas or white space, as address
    objects. An IPv4-mapped IPv6 address counts as the IPv4 address it carries.
    Raises ValueError for anything that is not a plain IP address (a zone id
    such as `fe80::1%en0` included) and for an empty or over-long list, so a
    mistake in the launcher stops the sandbox instead of leaving a hole in its
    blocklist."""
    found = set()
    for part in re.split(r"[,\r\n\t ]+", text):
        if not part:
            continue
        if "%" in part:
            raise ValueError(f"an address with a zone id is not accepted: {part[:64]!r}")
        try:
            ip = ipaddress.ip_address(part)
        except ValueError:
            raise ValueError(f"not an IP address: {part[:64]!r}") from None
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        found.add(ip)
        if len(found) > MAX_BLOCKED_ADDRESSES:
            raise ValueError(f"more than {MAX_BLOCKED_ADDRESSES} addresses")
    if not found:
        raise ValueError("no addresses in the list")
    return frozenset(found)


def load_blocked_file(path: str) -> frozenset:
    """The Mac's addresses in a file, read like the secret: once, as root,
    before privileges are dropped. It exits when the file is missing, is not a
    regular file, is too long or holds anything but addresses."""
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        sys.exit(f"cannot open the Mac's address list: {error.strerror}; refusing to start")
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            sys.exit("the Mac's address list is not a regular file; refusing to start")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            data = handle.read(MAX_BLOCKED_FILE_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(data) > MAX_BLOCKED_FILE_BYTES:
        sys.exit(f"the Mac's address list is longer than {MAX_BLOCKED_FILE_BYTES} bytes; "
                 "refusing to start")
    try:
        return load_blocked_addresses(data.decode("ascii"))
    except ValueError as error:  # a decoding error is a ValueError too
        sys.exit(f"the Mac's address list: {error}; refusing to start")


class NonceStore:
    """Nonces accepted within the time window. Only requests with a correct
    signature are stored, so a caller without the secret cannot fill it."""

    def __init__(self, window: int = TIME_WINDOW, capacity: int = NONCE_CAPACITY):
        self.window = window
        self.capacity = capacity
        self.seen: dict[str, int] = {}
        self.lock = threading.Lock()
        self.pruned_at = 0.0

    def add(self, nonce: str, stamp: int, now: float) -> bool:
        """False when the nonce was accepted before and is still remembered."""
        key = nonce.lower()
        with self.lock:
            if now - self.pruned_at >= 1 or len(self.seen) >= self.capacity:
                self.seen = {k: e for k, e in self.seen.items() if e >= now}
                self.pruned_at = now
            if key in self.seen:
                return False
            if len(self.seen) >= self.capacity:
                raise ToolError("too many requests in the last minute", "busy", 503)
            # A request with this stamp passes the time check until stamp + window.
            self.seen[key] = stamp + self.window + 1
            return True


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
    server_version = "SandSeekSandbox/1.0"
    # A client that connects and then says nothing (or stops in the middle of
    # a request) holds a thread; after this many seconds without data the
    # connection is closed. It limits waits on the client's socket only, not
    # the fetch a request runs.
    timeout = REQUEST_TIMEOUT
    # Seconds allowed for the whole request to arrive (see setup()).
    read_deadline = READ_DEADLINE
    tools: WebTools = WebTools()

    # Paths that may appear in the log; any other path is logged as "-", since
    # a caller chooses it.
    _LOGGED_PATHS = ("/health", "/v1/search", "/v1/fetch")

    def setup(self):
        super().setup()
        # One deadline for the whole request line, headers and body together:
        # Handler.timeout limits each wait, so a client sending a byte every
        # few seconds would hold its thread (and a slot) for ever.
        self.rfile = _HeadReader(self.rfile, MAX_HEAD_BYTES)
        self._read_timer = threading.Timer(self.read_deadline, self._read_expired)
        self._read_timer.daemon = True
        self._read_timer.start()

    def _read_expired(self):
        try:
            self.connection.shutdown(socket.SHUT_RD)
        except OSError:
            pass

    def _request_read(self):
        timer = getattr(self, "_read_timer", None)
        if timer is not None:
            timer.cancel()

    def finish(self):
        self._request_read()
        super().finish()

    def handle_one_request(self):
        self._started = time.monotonic()
        self._size = None
        self.rfile.start_head()
        super().handle_one_request()

    def parse_request(self):
        """The standard parsing, then stricter checks: the request line and
        headers must fit MAX_HEAD_BYTES and MAX_HEADERS, and the target must
        be a short, plain ASCII path (not a full URL)."""
        too_big = self.rfile.over
        if not too_big and not super().parse_request():
            return False
        if not self.rfile.over and not self.rfile.head_ended:
            # The input ended (or the read deadline fired) inside the headers:
            # no answer, as for any other stalled head.
            self.close_connection = True
            return False
        keep_open = self.close_connection
        self.close_connection = True  # Any refusal below closes the connection.
        if too_big or self.rfile.over:
            self.send_error(431, "request head too large")
            return False
        if len(self.headers) > MAX_HEADERS:
            self.send_error(431, "too many headers")
            return False
        target = self.path
        if (not target.startswith("/") or len(target) > MAX_TARGET_CHARS
                or any(not "!" <= char <= "~" for char in target)):
            self.send_error(400, "bad request target")
            return False
        self.close_connection = keep_open
        return True

    def log_request(self, code="-", size="-"):
        # Method, path (no query), status, size and duration: never headers,
        # bodies, URLs or queries.
        path = self.path.split("?", 1)[0] if hasattr(self, "path") else ""
        if path not in self._LOGGED_PATHS:
            path = "-"
        started = getattr(self, "_started", None)
        took = "-" if started is None else f"{time.monotonic() - started:.2f}s"
        size = self._size if getattr(self, "_size", None) is not None else size
        method = getattr(self, "command", None)
        if method not in ("GET", "POST", "HEAD", "PUT", "DELETE", "PATCH", "OPTIONS"):
            method = "-"
        self.log_message("%s %s %s %s %s", method, path, code, size, took)

    def log_error(self, fmt, *args):
        # The standard text repeats the request line, which holds the query.
        self.log_message("request refused")

    def log_message(self, fmt, *args):
        sys.stderr.write(("%s\n" % (fmt % args))[:200])

    # Set by main(); tests set their own. Without a secret nothing is served.
    secret: bytes = b""
    nonces: NonceStore = NonceStore()
    now: Callable[[], float] = staticmethod(time.time)

    # The nonce of the request being answered, or None when its answer is not
    # signed, and the request line's method and path.
    _nonce: str | None = None
    _method: str = ""
    _path: str = ""

    def _send(self, status: int, payload: dict):
        data = json.dumps(payload).encode()
        self._size = len(data)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if self._nonce is not None and self.secret:
            self.send_header(AUTH_HEADER, response_signature(
                self.secret, self._method, self._path, self._nonce, status, data))
        self.end_headers()
        if self._method != "HEAD":
            self.wfile.write(data)

    def _error(self, error: ToolError):
        self._send(error.status, {"error": {"message": error.message, "code": error.code}})

    def _read_request_body(self, method: str) -> bytes:
        """Reads the body before it is checked, so the signature covers the
        bytes that were sent. A Transfer-Encoding is refused, a POST needs a
        Content-Length, a Content-Length that cannot be a request's is an error,
        and a client that stops sending (Handler.timeout) is answered with 408.
        Every refusal here closes the connection, since unread bytes may be
        left on it."""
        if self.headers.get("Transfer-Encoding") is not None:
            self.close_connection = True
            raise ToolError("chunked requests are not accepted", "invalid_request", 400)
        if len(self.headers.get_all("Content-Length") or []) > 1:
            self.close_connection = True
            raise ToolError("more than one Content-Length", "invalid_request", 400)
        raw = self.headers.get("Content-Length")
        if raw is None:
            if method == "POST":
                raise ToolError("Content-Length is required", "invalid_request", 411)
            return b""
        digits = raw.strip()
        if not (digits.isascii() and digits.isdigit()):
            self.close_connection = True
            raise ToolError("Content-Length is not a number", "invalid_request", 400)
        if len(digits.lstrip("0")) > 18 or int(digits) > MAX_REQUEST_BYTES:
            self.close_connection = True
            raise ToolError("request body is too large", "invalid_request", 413)
        length = int(digits)
        try:
            data = self.rfile.read(length) if length else b""
        except (TimeoutError, socket.timeout):
            data = b""
        except OSError:
            self.close_connection = True
            raise ToolError("the request body could not be read", "invalid_request", 400)
        if len(data) < length:
            # The client stopped sending, or left.
            self.close_connection = True
            raise ToolError("timed out waiting for the request body", "request_timeout", 408)
        return data

    def _note_nonce(self) -> None:
        """Remembers a well-formed nonce so that every answer to this request
        is signed, error answers too. Signing an error reveals nothing: the
        answer's status and body are the server's own, only the nonce, method
        and path come from the caller."""
        values = self.headers.get_all(NONCE_HEADER) or []
        if len(values) == 1 and NONCE_PATTERN.fullmatch(values[0].strip()):
            self._nonce = values[0].strip()

    def _authenticate(self, method: str, body: bytes) -> None:
        if not self.secret:  # main() always sets one; nothing is served without it
            raise ToolError("the sandbox has no secret", "internal_error", 500)
        fail = ToolError("the request is not signed correctly", "unauthorized", 401)
        stamps = self.headers.get_all(TIME_HEADER) or []
        auths = self.headers.get_all(AUTH_HEADER) or []
        if (self._nonce is None or len(stamps) != 1 or len(auths) != 1
                or not TIME_PATTERN.fullmatch(stamps[0].strip())
                or not AUTH_PATTERN.fullmatch(auths[0].strip())):
            raise fail
        stamp_text = stamps[0].strip()
        now = self.now()
        if abs(now - int(stamp_text)) > TIME_WINDOW:
            raise ToolError("the request's time is too far from the sandbox's clock",
                            "stale_request", 401)
        expected = request_signature(self.secret, method, self._path, self._nonce, stamp_text, body)
        if not hmac.compare_digest(expected, auths[0].strip().lower()):
            raise fail
        if not self.nonces.add(self._nonce, int(stamp_text), now):
            raise ToolError("this request was already received", "replayed_request", 401)

    def _handle(self, method: str):
        self._nonce = None
        self._method = method
        self._path = self.path
        self._note_nonce()
        try:
            if not host_allowed(self.headers.get("Host")):
                # The body is not read, so it must not be taken for a request.
                self.close_connection = True
                raise ToolError("forbidden host", "forbidden_host", 403)
            try:
                body = self._read_request_body(method)
            finally:
                self._request_read()
            self._authenticate(method, body)
            if method == "GET":
                if self.path != "/health":
                    raise ToolError("not found", "not_found", 404)
                # "passages" tells the research loop this sandbox can rank
                # passages. "api" is the version of this API. "pdf" tells it
                # /v1/fetch reads PDFs (pypdf is installed).
                # "blocked_addresses" is how many of the Mac's own addresses
                # this server refuses; the security check compares it with
                # the list the launcher wrote.
                return self._send(200, {"status": "ok", "api": 1, "passages": True,
                                        "pdf": PdfReader is not None,
                                        "blocked_addresses": len(BLOCKED_ADDRESSES)})
            if method != "POST":
                raise ToolError("method not allowed", "method_not_allowed", 405)
            # A browser cannot send application/json cross-origin without a
            # preflight, which this server never answers.
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise ToolError("Content-Type must be application/json", "invalid_request", 415)
            if not 0 < len(body) <= MAX_REQUEST_BYTES:
                raise ToolError("request body is missing or too large", "invalid_request", 413)
            try:
                request = json.loads(body)
            except (ValueError, RecursionError):
                raise ToolError("request body is not JSON", "invalid_request", 400) from None
            if not isinstance(request, dict):
                raise ToolError("request body must be a JSON object", "invalid_request", 400)
            if self.path == "/v1/search":
                result = self.tools.search(
                    request.get("query"), request.get("max_results", 6))
            elif self.path == "/v1/fetch":
                result = self.tools.fetch(
                    request.get("url"), request.get("offset", 0),
                    request.get("max_chars", DEFAULT_SLICE_CHARS),
                    request.get("passages", False), request.get("query", ""))
            else:
                raise ToolError("not found", "not_found", 404)
            self._send(200, result)
        except ToolError as error:
            self._error(error)
        except Exception as error:  # Never leak a traceback to the caller.
            sys.stderr.write(f"internal error: {type(error).__name__}\n")
            self._error(ToolError("internal error", "internal_error", 500))

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_HEAD(self):
        self._handle("HEAD")

    def do_OPTIONS(self):
        self._handle("OPTIONS")


class _HeadReader:
    """Wraps the request's input stream. While the request line and headers
    are read it counts the bytes, and past `budget` it reports the end of the
    headers and sets `over`, so a flood of headers never fills memory. The
    body is read without the count."""

    def __init__(self, raw, budget: int):
        self._raw = raw
        self._limit = budget
        self._left: int | None = budget
        self.over = False
        self.head_ended = False  # The head ended with a blank line.

    def start_head(self) -> None:
        self._left = self._limit
        self.over = False
        self.head_ended = False

    def readline(self, size: int = -1) -> bytes:
        if self.over:
            return b""
        if self._left is None:
            return self._raw.readline(size)
        room = self._left + 1
        line = self._raw.readline(room if size is None or size < 0 else min(size, room))
        self._left -= len(line)
        if self._left < 0:
            self.over = True
            return b""
        if line in (b"\r\n", b"\n"):
            self.head_ended = True
        return line

    def read(self, size: int = -1) -> bytes:
        self._left = None  # The head is complete; the body is bounded elsewhere.
        return self._raw.read(size)

    def __getattr__(self, name):
        return getattr(self._raw, name)


class BoundedServer(ThreadingHTTPServer):
    """ThreadingHTTPServer that serves at most `max_connections` connections at
    once. Past that, a new connection is closed without an answer."""
    daemon_threads = True

    def __init__(self, address, handler, max_connections: int = MAX_CONNECTIONS):
        super().__init__(address, handler)
        self._slots = threading.BoundedSemaphore(max_connections)

    def server_bind(self):
        # HTTPServer.server_bind also asks for the host's fully qualified name
        # (socket.getfqdn), a reverse DNS lookup that can stall for a minute on
        # a machine whose resolver is slow, and nothing here uses the name.
        # Bind as TCPServer does and record the address as it is.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def no_memory_dumps() -> None:
    """No core file and no ptrace or /proc/<pid>/mem read of this process by
    the same user, since its memory holds the secret and the pages it read.
    Linux only; where it is not available this does nothing."""
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (OSError, ValueError):
        pass
    try:
        pr_set_dumpable = 4
        ctypes.CDLL(None, use_errno=True).prctl(pr_set_dumpable, 0, 0, 0, 0)
    except (OSError, AttributeError):
        pass


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


def stop_on_sigterm(server) -> None:
    """The server is PID 1 in the VM and PID 1 ignores SIGTERM unless it has a
    handler, so `container stop` would wait out its grace period before
    killing it. The app restarts the VM before every question, so shut down
    cleanly instead. `shutdown()` waits for `serve_forever()`, which the signal
    interrupts in this very thread, so it runs in another one."""
    def handler(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, handler)


def main(secret_file: str = DEFAULT_SECRET_FILE):
    # Read as root, before privileges are dropped. No secret, no server. Only
    # tests pass another file; nothing in the environment can move it.
    no_memory_dumps()
    Handler.secret = load_secret(secret_file)
    # The Mac's own addresses, from the file beside the secret, read the same
    # way and for the same reason; no list, no server.
    global BLOCKED_ADDRESSES
    BLOCKED_ADDRESSES = load_blocked_file(
        os.path.join(os.path.dirname(secret_file), BLOCKED_FILE_NAME))
    drop_privileges()
    no_memory_dumps()  # Again: changing user can make the process dumpable.
    # 0.0.0.0, not 127.0.0.1: `container run --publish` forwards the Mac's
    # 127.0.0.1:9100 to this VM's network address, not to its loopback, so a
    # loopback-only server would never be reached. The VM's input firewall
    # (firewall.nft) accepts new connections on this port only, and only from
    # the VM's default gateway, which entrypoint.sh puts into the rule; the Mac
    # side is published on 127.0.0.1 only. Anything that can send from the
    # gateway address (processes on the Mac) can still connect, so the Host
    # check stays.
    server = BoundedServer(("0.0.0.0", PORT), Handler)
    stop_on_sigterm(server)
    sys.stderr.write(f"SandSeek sandbox listening on :{PORT}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    sys.exit(0)


if __name__ == "__main__":
    main()
