#!/usr/bin/env python3
"""Merge KiCad 10 symbol-library directories into one .kicad_sym per library.

KiCad 10 ships libraries as <Library>.kicad_symdir/ directories containing one
.kicad_sym file per symbol. PadCB (like KiCad <= 9 tooling) consumes one file
per library, so CI runs this merge after downloading the pinned release:

    python3 tools/merge_symdirs.py <extracted-release-root> <dest-dir>

Each per-symbol file must contain exactly one top-level (symbol ...) node;
anything else fails the build loudly. The merged file wraps the extracted,
unmodified symbol nodes in a fresh (kicad_symbol_lib ...) root.
"""
import glob
import os
import sys


def extract_top_level_symbols(text, path):
    """Return the source spans of the root's direct (symbol ...) children."""
    spans = []
    depth = 0
    in_str = False
    esc = False
    node_start = None
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            i += 1
            continue
        if ch == "(":
            if depth == 1:
                # a direct child of the root: check its head atom
                j = i + 1
                while j < n and text[j] in " \t\r\n":
                    j += 1
                k = j
                while k < n and text[k] not in " \t\r\n()":
                    k += 1
                if text[j:k] == "symbol":
                    node_start = i
            depth += 1
            i += 1
            continue
        if ch == ")":
            depth -= 1
            if depth == 1 and node_start is not None:
                spans.append(text[node_start:i + 1])
                node_start = None
            if depth < 0:
                raise ValueError(f"{path}: unbalanced parens")
            i += 1
            continue
        i += 1
    if depth != 0 or in_str:
        raise ValueError(f"{path}: truncated file (depth {depth})")
    return spans


def main():
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for old in glob.glob(os.path.join(dst, "*.kicad_sym")):
        os.remove(old)

    symdirs = sorted(glob.glob(os.path.join(src, "*.kicad_symdir")))
    if not symdirs:
        sys.exit(f"no .kicad_symdir directories under {src}")

    total_symbols = 0
    total_bytes = 0
    for symdir in symdirs:
        lib = os.path.basename(symdir)[: -len(".kicad_symdir")]
        nodes = []
        for path in sorted(glob.glob(os.path.join(symdir, "*.kicad_sym"))):
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if not text.lstrip().startswith("(kicad_symbol_lib"):
                sys.exit(f"{path}: missing (kicad_symbol_lib root")
            spans = extract_top_level_symbols(text, path)
            if len(spans) != 1:
                sys.exit(f"{path}: expected exactly 1 top-level symbol, found {len(spans)}")
            nodes.append(spans[0])
        merged = ("(kicad_symbol_lib\n\t(version 20251024)\n"
                  "\t(generator \"padcb-merge\")\n"
                  + "\n".join(nodes) + "\n)\n")
        out_path = os.path.join(dst, lib + ".kicad_sym")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(merged)
        total_symbols += len(nodes)
        total_bytes += len(merged.encode("utf-8"))
        print(f"{lib}: {len(nodes)} symbols")

    license_src = os.path.join(src, "LICENSE.md")
    if not os.path.isfile(license_src):
        sys.exit(f"missing license file: {license_src}")
    with open(license_src, encoding="utf-8") as f:
        license_text = f.read()
    with open(os.path.join(dst, "KICAD-LIBRARIES-LICENSE.md"), "w", encoding="utf-8") as f:
        f.write(license_text)

    print(f"LIBRARIES={len(symdirs)}")
    print(f"SYMBOLS={total_symbols}")
    print(f"MERGED_BYTES={total_bytes}")


if __name__ == "__main__":
    main()
