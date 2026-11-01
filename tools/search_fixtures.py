#!/usr/bin/env python3
"""PadCB part 3 — SearchBench fixture builder.

Writes the two JSON corpora that tools/SearchBench/main.swift loads:
`symbols.json` and `footprints.json`, each a JSON array of SearchRow
objects ({"id": ..., "fields": [...]}) in exactly the shape and order
the app searches at runtime.

Usage:
    python3 tools/search_fixtures.py \
        --symbols-dir App/PadCB/Symbols \
        --footprint-index App/PadCB/Footprints/FootprintIndex.json \
        --out-dir /tmp/searchbench

Symbols: the app's symbol index semantics are replicated, not
re-derived — for each merged per-library .kicad_sym (sorted by file
name, the app's discovery order):
  * one header per top-level (symbol ...) in FILE ORDER, first
    occurrence winning on duplicate names;
  * Description / ki_keywords resolved through the extends chain —
    the symbol's own property wins, else the nearest ancestor's
    (the same walk as LibraryStore.indexEntries);
  * ki_keywords preferred over Keywords, and KiCad's "~" / empty
    property value normalised to "" (LibraryStore.indexValue);
  * row id = "<Library>:<Name>" (the app entry's id for a bundled
    library), fields = [name, description, keywords].
The S-expression reading reuses tools/truth_model.py's reader (the
repo's existing independent Python parser for this corpus).

Footprints: rows come straight from the CI-generated
FootprintIndex.json — id = "<Group>:<Name>" (a bundled entry's id),
fields = [name, group, description, tags joined with " "], in index
order, matching FootprintBrowserView's SearchIndex rows.
"""

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import truth_model as tm  # noqa: E402


def index_value(raw):
    """Mirror LibraryStore.indexValue: "~" / empty / missing -> ""."""
    if raw is None:
        return ""
    value = raw.strip()
    return "" if not value or value == "~" else value


def symbol_headers(path):
    """Top-level symbol headers of one .kicad_sym file, in file order:
    (name, extends_name_or_None, {property_name: value}) with the
    first occurrence of a property name winning — the same data
    KiCadLibrary.symbolHeaders extracts in the app."""
    with open(path, encoding="utf-8", errors="replace") as f:
        doc = tm.parse(f.read())
    if tm.head(doc) != "kicad_symbol_lib":
        return []
    headers = []
    for node in tm.children(doc, "symbol"):
        name = tm.sval(node, 1)
        if name is None:
            continue
        extends_node = tm.child(node, "extends")
        extends = tm.sval(extends_node, 1) if extends_node is not None else None
        properties = {}
        for prop in tm.children(node, "property"):
            # (property "Name" "Value" ...) — or, in newer files,
            # (property private "Name" "Value" ...): skip the marker.
            idx = 2 if tm.sval(prop, 1) == "private" else 1
            prop_name = tm.sval(prop, idx)
            prop_value = tm.sval(prop, idx + 1)
            if prop_name is not None and prop_value is not None \
                    and prop_name not in properties:
                properties[prop_name] = prop_value
        headers.append((name, extends, properties))
    return headers


def symbol_rows(symbols_dir):
    rows = []
    files = sorted(glob.glob(os.path.join(symbols_dir, "*.kicad_sym")))
    for path in files:
        library = os.path.basename(path)
        if library.endswith(".kicad_sym"):
            library = library[: -len(".kicad_sym")]
        headers = symbol_headers(path)
        # First occurrence wins on duplicate names; file order kept.
        by_name = {}
        order = []
        for name, extends, properties in headers:
            if name not in by_name:
                by_name[name] = (extends, properties)
                order.append(name)

        def resolved_properties(symbol_name):
            resolved = {}
            visited = set()
            current = symbol_name
            while current is not None and current not in visited \
                    and current in by_name:
                visited.add(current)
                extends, properties = by_name[current]
                for key, value in properties.items():
                    if key not in resolved:
                        resolved[key] = value
                current = extends
            return resolved

        for name in order:
            properties = resolved_properties(name)
            if "ki_keywords" in properties:
                keywords = properties["ki_keywords"]
            else:
                keywords = properties.get("Keywords")
            rows.append({
                "id": f"{library}:{name}",
                "fields": [
                    name,
                    index_value(properties.get("Description")),
                    index_value(keywords),
                ],
            })
    return rows


def footprint_rows(footprint_index_path):
    with open(footprint_index_path, encoding="utf-8") as f:
        index = json.load(f)
    rows = []
    for entry in index:
        tags = entry.get("tags") or []
        if not isinstance(tags, list):
            tags = [str(tags)]
        rows.append({
            "id": f"{entry['group']}:{entry['name']}",
            "fields": [
                entry["name"],
                entry["group"],
                entry.get("description") or "",
                " ".join(str(tag) for tag in tags),
            ],
        })
    return rows


def main():
    ap = argparse.ArgumentParser(description="Build SearchBench fixtures")
    ap.add_argument("--symbols-dir", required=True,
                    help="dir of merged per-library .kicad_sym files")
    ap.add_argument("--footprint-index", required=True,
                    help="path to FootprintIndex.json")
    ap.add_argument("--out-dir", required=True,
                    help="output dir for symbols.json + footprints.json")
    args = ap.parse_args()

    symbols = symbol_rows(args.symbols_dir)
    footprints = footprint_rows(args.footprint_index)

    os.makedirs(args.out_dir, exist_ok=True)
    for file_name, rows in (("symbols.json", symbols),
                            ("footprints.json", footprints)):
        out_path = os.path.join(args.out_dir, file_name)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False)
        print(f"{out_path}: {len(rows)} rows")


if __name__ == "__main__":
    main()
