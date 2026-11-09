#!/usr/bin/env python3
"""Finds docs that still name what the branch removed: REVIEW.md's retired terms, as far as a tool can.

Fails on an identifier the branch removed from the code (a `--flag`, a snake_case setting or field, a
CamelCase type or view, a quoted kebab-case command such as a debug URL's) that no file outside the
docs uses any more, while a doc still names it. Warns, without failing, on each doc line that uses a
term the branch adds to a `_Avoid_` list in GLOSSARY.md: those lists carry exceptions in prose ("fine
in prose", "except as the label") that only a reader can apply.

Not searched, as docs/review.md's Retired terms line says: the review logs, `_Avoid_` lines, dated
decision rows, CHANGELOG.md, docs/mockups/ and prototypes/.

Usage: scripts/verify/retired-terms.py [<base>]   (default: $PREPUSH_BASE, else origin/main)
       scripts/verify/retired-terms.py --self-test
Run by scripts/verify/prepush.sh.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOKEN = re.compile(
    r"(?<![\w-])--[a-z][a-z0-9]*(?:-[a-z0-9]+)*"  # a command-line flag
    r"|\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b"  # a snake_case setting, field or function
    r"|\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+\b"  # a CamelCase type or view
)
QUOTED_KEBAB = re.compile(r"[\"']([a-z][a-z0-9]*(?:-[a-z0-9]+)+)[\"'?]")
DATED_ROW = re.compile(r"\|\s*\d{4}-\d{2}-\d{2}\s*\|")
SKIPPED_DOCS = ("docs/review-retros.md", "docs/coderabbit-findings.md", "CHANGELOG.md")
SKIPPED_DIRS = ("docs/mockups/", "prototypes/")


def tokens(line: str) -> set[str]:
    """The identifiers in one line of code that a doc might name."""
    found = {match.group(0) for match in TOKEN.finditer(line)}
    found |= {match.group(1) for match in QUOTED_KEBAB.finditer(line)}
    return {token for token in found if len(token) >= 4}


def is_doc(path: str) -> bool:
    return path.endswith(".md") or path.startswith("docs/")


def searched_doc(path: str) -> bool:
    return path.endswith(".md") and path not in SKIPPED_DOCS and not path.startswith(SKIPPED_DIRS)


def removed_tokens(diff: str) -> set[str]:
    """Identifiers on the removed lines of code files in a `git diff` without context."""
    removed: set[str] = set()
    path = ""
    for line in diff.splitlines():
        if line.startswith("--- "):
            path = line[6:] if line.startswith("--- a/") else ""
        elif line.startswith("-") and path and not is_doc(path) and not path.startswith(SKIPPED_DIRS):
            removed |= tokens(line[1:])
    return removed


def word(token: str) -> re.Pattern[str]:
    return re.compile(rf"(?<![\w-]){re.escape(token)}(?![\w-])")


def retired(removed: set[str], code: str) -> list[str]:
    """The removed identifiers that no code file uses any more."""
    return sorted(token for token in removed if not word(token).search(code))


def avoid_terms(glossary: str) -> set[str]:
    """The terms in GLOSSARY.md's `_Avoid_` lines, without their notes in parentheses."""
    terms: set[str] = set()
    for line in glossary.splitlines():
        if not line.startswith("_Avoid_:"):
            continue
        text = re.sub(r"\([^)]*\)", "", line[len("_Avoid_:") :])
        for part in re.split(r"[,;]", text):
            term = part.strip().strip('"`').strip()
            if term and " for " not in term:
                terms.add(term.lower())
    return terms


def skipped_line(line: str) -> bool:
    return line.startswith("_Avoid_:") or bool(DATED_ROW.match(line.strip()))


def hits(terms: list[str], docs: dict[str, str], ignore_case: bool = False) -> list[str]:
    """`path:line: term` for each line of a searched doc that names a term."""
    found = []
    for term in terms:
        pattern = re.compile(word(term).pattern, re.IGNORECASE if ignore_case else 0)
        for path, text in sorted(docs.items()):
            for number, line in enumerate(text.splitlines(), 1):
                if not skipped_line(line) and pattern.search(line):
                    found.append(f"{path}:{number}: {term}")
    return found


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def read_tracked() -> tuple[str, dict[str, str]]:
    """The text of every tracked code file, joined, and every searched doc by path."""
    code_parts, docs = [], {}
    for path in git("ls-files").splitlines():
        try:
            text = (ROOT / path).read_text()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        if searched_doc(path):
            docs[path] = text
        elif not is_doc(path) and not path.startswith(SKIPPED_DIRS):
            code_parts.append(text)
    return "\n".join(code_parts), docs


def self_test() -> list[str]:
    failures = []

    def expect(name, actual, wanted):
        if actual != wanted:
            failures.append(f"self-test: {name}: got {actual!r}, wanted {wanted!r}")

    expect("tokens", tokens('let x = cfg.menu_bar_top; run("--dry-run"); open("open-popover"); MenuBarView()'),
           {"menu_bar_top", "--dry-run", "open-popover", "MenuBarView"})
    expect("short and plain words", tokens("let a_b = 1; if x { return }"), set())
    diff = (
        "--- a/core/src/settings.rs\n+++ b/core/src/settings.rs\n@@ -1 +1 @@\n"
        "-    menu_bar_top: u8,\n+    menu_bar_readings: Vec<u8>,\n"
        "--- a/docs/plan.md\n+++ b/docs/plan.md\n@@ -1 +1 @@\n-old `doc_only_term`\n+new\n"
        "--- /dev/null\n+++ b/app/New.swift\n@@ -0,0 +1 @@\n+struct NewView {}\n"
    )
    expect("removed tokens come from code only", removed_tokens(diff), {"menu_bar_top"})
    expect("a token still in code is not retired",
           retired({"menu_bar_top", "reset_hour"}, "let reset_hour = 4;"), ["menu_bar_top"])
    expect("a longer identifier does not keep a token alive",
           retired({"menu_bar"}, "menu_bar_top"), ["menu_bar"])
    docs = {
        "docs/plan.md": "Set `menu_bar_top` to 2.\n| 2026-11-01 | `menu_bar_top` was renamed |\n",
        "GLOSSARY.md": "_Avoid_: menu_bar_top\n",
        "docs/design.md": "menu_bar_topmost stays\n",
    }
    expect("doc hits skip dated rows, Avoid lines and longer words",
           hits(["menu_bar_top"], docs), ["docs/plan.md:1: menu_bar_top"])
    expect("avoid terms", avoid_terms('_Avoid_: tick, count\n_Avoid_: notification (the fallback); alert for any moment\n_Avoid_: "per-app counting is off"\n'),
           {"tick", "count", "notification", "per-app counting is off"})
    expect("skipped docs", [searched_doc(p) for p in ("docs/review-retros.md", "docs/mockups/a.md", "CHANGELOG.md", "docs/plan.md")],
           [False, False, False, True])
    return failures


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        failures = self_test()
        print("\n".join(failures) if failures else "retired-terms: self-test passed")
        return 1 if failures else 0
    failures = self_test()
    if failures:
        print("\n".join(failures))
        return 1
    base_ref = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PREPUSH_BASE", "origin/main")
    try:
        base = git("merge-base", base_ref, "HEAD").strip()
    except subprocess.CalledProcessError:
        print(f"retired-terms: no merge base with {base_ref!r}; pass the PR's base branch or set PREPUSH_BASE")
        return 1
    code, docs = read_tracked()
    # Fixed prefixes and no external or colored diff, whatever the user's git config.
    diff = git(
        "diff", "--unified=0", "--no-ext-diff", "--no-textconv", "--no-color",
        "--src-prefix=a/", "--dst-prefix=b/", base, "--",
    )
    gone = retired(removed_tokens(diff), code)
    errors = hits(gone, docs)
    try:
        base_glossary = git("show", f"{base}:GLOSSARY.md")
    except subprocess.CalledProcessError:
        base_glossary = ""
    new_avoid = sorted(avoid_terms((ROOT / "GLOSSARY.md").read_text()) - avoid_terms(base_glossary))
    for warning in hits(new_avoid, docs, ignore_case=True):
        print(f"warning: {warning} (newly in a GLOSSARY.md _Avoid_ list; check its exceptions)")
    for error in errors:
        print(f"{error} (removed from the code in this branch; name what replaced it)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
