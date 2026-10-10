#!/usr/bin/env python3
"""Writes the external-NN-*.html pages from external-attacks.json.

Run it after editing the manifest:  python3 build_external_fixtures.py
Each page carries real, harmless facts about the fictional Lake Zorvath plus
several attack texts (see THIRD_PARTY_NOTICES.md), hidden in ways that survive
the sandbox's text extraction: plain paragraphs, near-invisible styled text,
elements with the `hidden` attribute, off-screen and zero-opacity text,
list items, quotes, table cells, collapsed <details>, headings and <pre>
blocks. HTML comments, alt text, <meta>, <figcaption>, <aside>, <footer> and
display:none text are dropped by the extractor, so they are not used.
"""
import html
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def render(attack: dict) -> str:
    text = html.escape(attack["text"], quote=False)
    method = attack["hidden_by"]
    if method == "visible":
        return f"<p>{text}</p>"
    if method == "tiny":
        return f'<p style="color:#ffffff;font-size:1px">{text}</p>'
    if method == "hidden-attr":
        return f"<p hidden>{text}</p>"
    if method == "offscreen":
        return f'<p style="position:absolute;left:-9999px">{text}</p>'
    if method == "opacity":
        return f'<p style="opacity:0">{text}</p>'
    if method == "sr-only":
        return f'<p class="sr-only">{text}</p>'
    if method == "list":
        return f"<ul><li>{text}</li></ul>"
    if method == "blockquote":
        return f"<blockquote>{text}</blockquote>"
    if method == "table":
        return f"<table><tr><th>Note</th></tr><tr><td>{text}</td></tr></table>"
    if method == "details":
        return f"<details><summary>More</summary>{text}</details>"
    if method == "heading":
        return f"<h3>{text}</h3>"
    if method == "pre":
        return f"<pre>{text}</pre>"
    raise ValueError(method)


def build(page: dict) -> str:
    out = ["<!doctype html>", '<html lang="en"><head><meta charset="utf-8">',
           f"<title>{html.escape(page['title'])}</title>",
           "<style>.sr-only{position:absolute;width:1px;height:1px;overflow:hidden}</style></head>",
           "<body><article>", f"<h1>{html.escape(page['title'])}</h1>"]
    paragraphs = page["paragraphs"]
    for index, paragraph in enumerate(paragraphs):
        out.append(f"<p>{html.escape(paragraph, quote=False)}</p>")
        out.extend(render(a) for a in page["attacks"] if a["slot"] == index)
    out.extend(render(a) for a in page["attacks"] if a["slot"] >= len(paragraphs))
    out.append("</article></body></html>")
    return "\n".join(out) + "\n"


def main() -> None:
    with open(os.path.join(HERE, "external-attacks.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    for page in manifest["pages"]:
        assert re.fullmatch(r"external-\d\d-[a-z-]+\.html", page["fixture"]), page["fixture"]
        with open(os.path.join(HERE, page["fixture"]), "w", encoding="utf-8") as handle:
            handle.write(build(page))
        print(page["fixture"], len(page["attacks"]), "attacks")


if __name__ == "__main__":
    main()
