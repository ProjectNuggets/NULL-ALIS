#!/usr/bin/env python3
"""
Generate Obsidian code-graph cards from the nullalis Zig source tree.

For each .zig file under src/, write a companion .md card under
~/nullalis-vault/code/ with the same relative path. Each card contains:

  - Frontmatter: source path + symbol counts + LOC
  - Imports as [[wikilinks]] to other code cards (resolved via @import("..."))
  - Public API surface (pub fn, pub const, pub var)
  - Recent commits touching this file (last 5)

Idempotent: overwrites cards each run. Run after meaningful refactors.

Usage:
  python3 scripts/vault-code-graph.py [--src SRC_DIR] [--vault VAULT_DIR]

Defaults:
  --src   = ~/Desktop/nullalis/src
  --vault = ~/nullalis-vault/code
"""

import argparse
import os
import pathlib
import re
import subprocess
import sys
from typing import Dict, List, Optional


IMPORT_RE = re.compile(r'@import\s*\(\s*"([^"]+)"\s*\)')
# Matches `pub fn name(...)`, `pub const name = ...`, `pub var name = ...`.
PUB_FN_RE = re.compile(r'^\s*pub\s+(?:inline\s+)?fn\s+(\w+)\s*\(', re.MULTILINE)
PUB_CONST_RE = re.compile(r'^\s*pub\s+const\s+(\w+)\s*[=:]', re.MULTILINE)
PUB_VAR_RE = re.compile(r'^\s*pub\s+var\s+(\w+)\s*[=:]', re.MULTILINE)


def discover_zig_files(src_root: pathlib.Path) -> List[pathlib.Path]:
    return sorted(p for p in src_root.rglob("*.zig") if p.is_file())


def relpath_to_card(zig_rel: pathlib.Path) -> pathlib.Path:
    """src/agent/communities.zig → agent/communities.md"""
    return zig_rel.with_suffix(".md")


def parse_imports(content: str, source_file: pathlib.Path, src_root: pathlib.Path) -> List[str]:
    """Resolve @import strings → vault-relative card stems for wikilinks."""
    out = []
    for m in IMPORT_RE.finditer(content):
        target = m.group(1)
        # Skip stdlib / build_options / external pkgs.
        if target in {"std", "builtin", "build_options"}:
            continue
        if not target.endswith(".zig"):
            continue
        # Resolve relative to the importing file's directory.
        try:
            resolved = (source_file.parent / target).resolve()
            rel = resolved.relative_to(src_root.resolve())
            stem = str(rel.with_suffix(""))
            out.append(stem)
        except (ValueError, OSError):
            # Out-of-tree import; keep as plain text reference.
            out.append(f"~~{target}~~")
    # Dedupe preserving order
    seen = set()
    uniq = []
    for s in out:
        if s not in seen:
            seen.add(s)
            uniq.append(s)
    return uniq


def parse_symbols(content: str) -> Dict[str, List[str]]:
    return {
        "fn": PUB_FN_RE.findall(content),
        "const": PUB_CONST_RE.findall(content),
        "var": PUB_VAR_RE.findall(content),
    }


def recent_commits(src_root: pathlib.Path, file_rel: pathlib.Path, n: int = 5) -> List[str]:
    """Return list of 'sha subject' for the last n commits touching this file."""
    try:
        out = subprocess.check_output(
            ["git", "log", f"-n{n}", "--pretty=format:%h %s", "--", str(file_rel)],
            cwd=src_root.parent,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return [l for l in out.split("\n") if l.strip()]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []


def render_card(
    zig_path: pathlib.Path,
    src_root: pathlib.Path,
    imports: List[str],
    symbols: Dict[str, List[str]],
    commits: List[str],
    loc: int,
) -> str:
    rel_to_src = zig_path.relative_to(src_root)
    rel_to_repo = pathlib.Path("src") / rel_to_src
    title = str(rel_to_src)

    # Top-level dir → tag for color-group / filter (e.g. agent/communities.zig
    # → tag `code/agent`). Lets Nova distinguish code-reality from prose-
    # reality in graph view via `tag:#code-graph` (paint all code cards) +
    # `tag:#code/agent` (highlight one subsystem). Tags persist in the file
    # frontmatter; resilient to Obsidian state overwrites.
    top_dir = rel_to_src.parts[0] if len(rel_to_src.parts) > 1 else "root"
    # Frontmatter
    lines = [
        "---",
        f"source: {rel_to_repo}",
        f"loc: {loc}",
        f"public_fns: {len(symbols['fn'])}",
        f"public_consts: {len(symbols['const'])}",
        f"public_vars: {len(symbols['var'])}",
        f"imports: {len(imports)}",
        f"tags: [code-graph, code/{top_dir}]",
        "---",
        "",
        f"# {title}",
        "",
        f"`{rel_to_repo}` — {loc} lines, {len(symbols['fn'])} pub fns, {len(symbols['const'])} pub consts, {len(symbols['var'])} pub vars.",
        "",
    ]

    # Imports section
    if imports:
        lines.append("## Imports")
        lines.append("")
        for imp in imports:
            if imp.startswith("~~"):
                lines.append(f"- {imp}")  # out-of-tree, keep as strikethrough
            else:
                lines.append(f"- [[{imp}|{imp}]]")
        lines.append("")
    else:
        lines.append("## Imports")
        lines.append("")
        lines.append("_(none — leaf module or std-only)_")
        lines.append("")

    # Public API section
    if any(symbols.values()):
        lines.append("## Public API")
        lines.append("")
        if symbols["fn"]:
            lines.append("### Functions")
            lines.append("")
            for name in symbols["fn"]:
                lines.append(f"- `pub fn {name}`")
            lines.append("")
        if symbols["const"]:
            lines.append("### Constants / Types")
            lines.append("")
            for name in symbols["const"]:
                lines.append(f"- `pub const {name}`")
            lines.append("")
        if symbols["var"]:
            lines.append("### Vars")
            lines.append("")
            for name in symbols["var"]:
                lines.append(f"- `pub var {name}`")
            lines.append("")

    # Recent commits
    if commits:
        lines.append("## Recent commits")
        lines.append("")
        for c in commits:
            sha, _, subj = c.partition(" ")
            lines.append(f"- `{sha}` {subj}")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append(f"_Generated by `scripts/vault-code-graph.py`. Re-run after refactors._")
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.expanduser("~/Desktop/nullalis/src"))
    ap.add_argument("--vault", default=os.path.expanduser("~/nullalis-vault/code"))
    args = ap.parse_args()

    src_root = pathlib.Path(args.src).resolve()
    vault_root = pathlib.Path(args.vault).resolve()
    if not src_root.is_dir():
        print(f"src not found: {src_root}", file=sys.stderr)
        sys.exit(1)
    vault_root.mkdir(parents=True, exist_ok=True)

    zig_files = discover_zig_files(src_root)
    written = 0
    for zig in zig_files:
        rel = zig.relative_to(src_root)
        card_rel = relpath_to_card(rel)
        card_abs = vault_root / card_rel
        card_abs.parent.mkdir(parents=True, exist_ok=True)
        try:
            content = zig.read_text(errors="replace")
        except OSError:
            continue
        loc = content.count("\n") + 1
        imports = parse_imports(content, zig, src_root)
        symbols = parse_symbols(content)
        commits = recent_commits(src_root, pathlib.Path("src") / rel)
        card = render_card(zig, src_root, imports, symbols, commits, loc)
        card_abs.write_text(card)
        written += 1

    # Index page
    index_lines = [
        "# Code graph index",
        "",
        f"Auto-generated from `{src_root}` ({len(zig_files)} Zig files).",
        "",
        "## How to use",
        "",
        "Open the **graph view** (cmd-G) — each `.md` card here is a node.",
        "Edges are `@import(...)` relationships parsed from the actual Zig source.",
        "Click any node, then **local graph** (cmd-shift-G) to see one file's neighborhood.",
        "",
        "When I'm about to edit a Zig file, you can preview which other files might be",
        "affected by clicking the card and reading the imports list + recent commits.",
        "",
        "## Top-level modules",
        "",
    ]
    # Group by top-level dir
    groups: Dict[str, List[pathlib.Path]] = {}
    for zig in zig_files:
        rel = zig.relative_to(src_root)
        parts = rel.parts
        top = parts[0] if len(parts) > 1 else "(root)"
        groups.setdefault(top, []).append(rel)
    for top in sorted(groups):
        index_lines.append(f"### {top}")
        index_lines.append("")
        for rel in sorted(groups[top]):
            stem = str(rel.with_suffix(""))
            index_lines.append(f"- [[{stem}|{rel}]]")
        index_lines.append("")
    index_lines.append("---")
    index_lines.append("")
    index_lines.append("_Re-run `scripts/vault-code-graph.py` after refactors to keep cards in sync._")
    (vault_root / "README.md").write_text("\n".join(index_lines))

    print(f"Wrote {written} code-graph cards to {vault_root}")
    print(f"Index: {vault_root}/README.md")


if __name__ == "__main__":
    main()
