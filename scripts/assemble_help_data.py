#!/usr/bin/env python3
# assemble_help_data.py — build the help window's data JS files from the
# vendored runtime. Called by the "Vendor HS Runtime" build phase.
#
# Outputs (into the app's Resources/):
#   ScriptHelp.data.js   window.__DOCS__      hs module docs
#                        window.__DOCS_ZH__   zh translations (help_zh.json)
#   ScriptSpoons.data.js window.__SPOON_DOCS__ per-spoon docs entries
#                        (items incl. their zh via __DOCS_ZH__ keys)

import json
import sys
from pathlib import Path

vendor = Path(sys.argv[1])
resources = Path(sys.argv[2])

CATS = ("Function", "Method", "Constructor", "Constant",
        "Command", "Field", "Variable", "Deprecated")

zh = {}
zh_path = vendor / "help_zh.json"
if zh_path.exists():
    zh = json.loads(zh_path.read_text())


def emit(path: Path, assignments: dict[str, str]):
    body = "".join(f"window.{k}={v};\n" for k, v in assignments.items())
    path.write_text(body)


# hs modules
docs = json.loads((vendor / "docs.json").read_text())
emit(resources / "ScriptHelp.data.js", {
    "__DOCS__": json.dumps(docs, ensure_ascii=False),
    "__DOCS_ZH__": json.dumps(zh, ensure_ascii=False),
})

# spoons: docs entry per spoon + curated summary lines used by settings/help
summaries = {}
catalog_src = Path(sys.argv[3]) if len(sys.argv) > 3 else None
if catalog_src and catalog_src.exists():
    entries = json.loads(catalog_src.read_text())
    summaries = {e["name"]: e for e in entries}

spoon_docs = {}
spoon_list = []
for bundle in sorted((vendor / "spoons").glob("*.spoon")):
    name = bundle.stem
    dj = bundle / "docs.json"
    entry = None
    if dj.exists():
        entries = json.loads(dj.read_text())
        if entries:
            entry = entries[0]
    summary = summaries.get(name, {})
    spoon_list.append({
        "name": name,
        "zh": summary.get("zh", name),
        "en": summary.get("en", (entry or {}).get("desc", name)),
        "hasDocs": entry is not None,
    })
    if entry is not None:
        spoon_docs[name] = entry

emit(resources / "ScriptSpoons.data.js", {
    "__SPOON_LIST__": json.dumps(spoon_list, ensure_ascii=False),
    "__SPOON_DOCS__": json.dumps(spoon_docs, ensure_ascii=False),
    "__DOCS_ZH__": json.dumps(zh, ensure_ascii=False),
})

# Per-spoon usage for the settings manager + help window (plain JSON, read
# by Swift and shipped to the JS side): curated user-view usage (what the
# spoon does once enabled — hotkey/menu/auto behavior) plus the developer
# doc zh/en as secondary reference.
curated = {}
usage_src = vendor.parent.parent / "scripts" / "spoon_usage_zh.json"
if usage_src.exists():
    curated = json.loads(usage_src.read_text())

usage = {}
for name, entry in spoon_docs.items():
    u = curated.get(name, {})
    usage[name] = {
        "how": u.get("how", ""),
        "trigger": u.get("trigger", ""),
        "text": u.get("text", ""),
        "zh": zh.get(f"spoon|{name}", ""),
        "en": (entry.get("doc") or entry.get("desc") or "").strip(),
    }
    for i, sp in enumerate(spoon_list):
        if sp["name"] == name:
            sp["how"] = usage[name]["how"]
            sp["trigger"] = usage[name]["trigger"]
            sp["usage"] = usage[name]["text"]
(resources / "spoon_usage.json").write_text(
    json.dumps(usage, ensure_ascii=False, indent=1))
print(f"help data: {len(docs)} modules, {len(spoon_list)} spoons, "
      f"{len(zh)} zh strings")
