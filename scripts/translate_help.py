#!/usr/bin/env python3
# translate_help.py — generate Chinese translations for the scripting help.
#
# Translates every item in the vendored docs.json (module docs, function/
# method/constant descriptions, parameter descriptions) plus every bundled
# Spoon's docs.json, using the Google translate gtx endpoint (no key).
# Results are cached in build/translate-cache.json (resumable) and written
# to build/hs-vendor/help_zh.json, consumed by the help window and the
# Spoons detail views. One-time generation; the output is committed, so CI
# never translates anything.
#
# Usage: python3 scripts/translate_help.py [--rebuild-cache]

import json
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "build" / "hs-vendor"
CACHE = ROOT / "build" / "translate-cache.json"

CATS = ("Function", "Method", "Constructor", "Constant",
        "Command", "Field", "Variable", "Deprecated")


def collect_docs(entries, prefix, out):
    """Collect translatable strings from a docs.json-style entry list."""
    for m in entries:
        name = m.get("name", "")
        doc = (m.get("doc") or m.get("desc") or "").strip()
        if doc:
            out[f"{prefix}|{name}"] = doc
        for cat in CATS:
            raw = m.get(cat)
            if not raw:
                continue
            items = json.loads(raw) if isinstance(raw, str) else raw
            for it in items:
                key = f"{prefix}|{name}|{cat}|{it.get('def', it.get('name', ''))}"
                desc = (it.get("desc") or "").strip()
                if desc:
                    out[key] = desc
                params = it.get("parameters")
                if isinstance(params, str):
                    try:
                        params = json.loads(params)
                    except json.JSONDecodeError:
                        params = None
                if isinstance(params, list):
                    # Parameters are preformatted doc lines ("* name - desc").
                    for pi, pline in enumerate(params):
                        pline = pline.strip() if isinstance(pline, str) else ""
                        if pline:
                            out[f"{key}|p{pi}"] = pline


def translate(text):
    q = urllib.parse.quote(text)
    url = ("https://clients5.google.com/translate_a/t"
           f"?client=dict-chrome-ex&sl=en&tl=zh-CN&q={q}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.load(resp)
            # dict-chrome-ex returns ["translation"] (or [["t", "alt"], ...])
            if data and isinstance(data[0], str):
                return data[0]
            return "".join(chunk[0] for chunk in data[0] if chunk and chunk[0])
        except Exception as exc:  # noqa: BLE001 — retry any transport error
            wait = min(2.0 * (attempt + 1) ** 2, 30.0)
            print(f"  retry ({exc}); waiting {wait}s", flush=True)
            time.sleep(wait)
    return None


def main():
    strings: dict[str, str] = {}

    docs = json.loads((VENDOR / "docs.json").read_text())
    collect_docs(docs, "mod", strings)
    print(f"hs docs: {len(docs)} modules")

    spoon_docs = {}
    for bundle in sorted((VENDOR / "spoons").glob("*.spoon")):
        dj = bundle / "docs.json"
        if not dj.exists():
            continue
        entries = json.loads(dj.read_text())
        spoon_docs[bundle.stem] = entries
        collect_docs(entries, "spoon", strings)
    print(f"spoons with docs: {len(spoon_docs)}")

    cache = {}
    if CACHE.exists() and "--rebuild-cache" not in sys.argv:
        cache = json.loads(CACHE.read_text())

    todo = [k for k, v in strings.items() if k not in cache]
    print(f"total strings: {len(strings)}, to translate: {len(todo)}", flush=True)

    import threading
    lock = threading.Lock()
    done_count = [0]

    def work(key):
        zh = translate(strings[key])
        if zh is None:
            print(f"  FAILED: {key[:90]}", flush=True)
            return
        with lock:
            cache[key] = zh
            done_count[0] += 1
            if done_count[0] % 25 == 0 or done_count[0] == len(todo):
                CACHE.write_text(json.dumps(cache, ensure_ascii=False))
                print(f"[{done_count[0]}/{len(todo)}] cached", flush=True)
        time.sleep(0.15)

    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(work, todo))

    CACHE.write_text(json.dumps(cache, ensure_ascii=False))
    (VENDOR / "help_zh.json").write_text(
        json.dumps(cache, ensure_ascii=False, sort_keys=True))
    covered = sum(1 for k in strings if k in cache)
    print(f"done: {covered}/{len(strings)} translated -> help_zh.json", flush=True)


if __name__ == "__main__":
    main()
