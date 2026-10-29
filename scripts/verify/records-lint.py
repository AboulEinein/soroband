#!/usr/bin/env python3
"""Checks the review records against the values their own rules allow.

docs/review-retros.md: each review row's findings are counts of a defined severity, or none.
docs/coderabbit-findings.md: each row has its columns, a defined verdict and a defined miss cause.
Exits non-zero, listing each bad row, when one does not fit. Run by CI and scripts/verify/prepush.sh.
`--self-test` checks the lint itself on rows it must accept and rows it must refuse.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEVERITIES = {"Critical", "High", "Medium", "Low", "Minor", "unrated", "Major", "Trivial"}
VERDICTS = {"valid", "accepted", "not valid"}
MISSED = {"not checked", "judged fine", "outside the diff", "not in the requirements", "after the loop", "–"}
SEPARATOR = re.compile(r":?-{3,}:?")
REVIEW_LABEL = re.compile(r"\d+(?: \(.+\))?|direct|CodeRabbit")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def cells(line: str) -> list[str]:
    """A row's cells, split on pipes; an escaped pipe (`\\|`) stays in its cell, as GitHub renders it."""
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def table_rows(text: str, name: str, header: str, first_cell: re.Pattern[str], expected: str, problems: list[str]):
    """The rows of the tables in `text` headed by `header`; a row whose first cell does not fit is
    reported, not skipped."""
    for number, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith("|"):
            continue
        row = cells(line)
        if row[0] == header or SEPARATOR.fullmatch(row[0]):
            continue
        if first_cell.fullmatch(row[0]):
            yield number, row
        else:
            problems.append(f"{name}:{number}: first cell {row[0]!r} is not {expected}")


def check_retros(text: str, name: str = "review-retros.md") -> list[str]:
    problems: list[str] = []
    for number, row in table_rows(text, name, "Review", REVIEW_LABEL, "a round number, direct or CodeRabbit", problems):
        if len(row) != 4:
            problems.append(f"{name}:{number}: {len(row)} columns, the table has 4")
            continue
        findings = row[2]
        if findings == "none":
            continue
        # Commas inside a note in parentheses do not separate counts.
        for part in re.split(r",\s*(?![^()]*\))", findings):
            match = re.fullmatch(r"(\d+) (\w+)(?: \(.+\))?", part.strip())
            if not match or match.group(2) not in SEVERITIES:
                problems.append(
                    f"{name}:{number}: findings {part.strip()!r} is not a count of "
                    f"{', '.join(sorted(SEVERITIES))}, or none"
                )
    return problems


def check_findings(text: str, name: str = "coderabbit-findings.md") -> list[str]:
    problems: list[str] = []
    for number, row in table_rows(text, name, "Date", DATE, "a date (YYYY-MM-DD)", problems):
        if len(row) != 7:
            problems.append(f"{name}:{number}: {len(row)} columns, the table has 7")
            continue
        verdict, missed = row[4], row[5]
        if verdict not in VERDICTS:
            problems.append(f"{name}:{number}: verdict {verdict!r} is not one of {sorted(VERDICTS)}")
        if missed not in MISSED:
            problems.append(f"{name}:{number}: missed because {missed!r} is not one of {sorted(MISSED)}")
        if (verdict == "not valid") != (missed == "–"):
            problems.append(
                f"{name}:{number}: missed because is – exactly when the verdict is not valid, "
                f"here {verdict!r} with {missed!r}"
            )
    return problems


def self_test() -> list[str]:
    """Rows the lint must accept, and rows it must refuse, each on its own."""
    header = "| Review | Model | Findings | Origins |\n"
    retros_ok = [
        "| --- | --- | --- | --- |",
        "|----|:---|---:|:---:|",
        "| 1 | Opus | 1 Medium, 3 Low, 1 unrated | x |",
        "| 1 (stopped) | Sonnet | none | x |",
        "| CodeRabbit | CodeRabbit | 1 Major, 2 Minor (review body) | x |",
        "| direct | Haiku | 2 Low (the lint, prepush) | x |",
        "|2 | Opus | 1 Low | x |",
        "| 3 | Opus | 1 Low | separators such as `\\|----\\|` |",
    ]
    retros_bad = [
        "| 1 | Opus | 1 Discussion | x |",
        "|1 | Opus | 1 Discussion | x |",
        "| bogus | Opus | none | x |",
        "| 2 | Opus | Low | x |",
        "| 2 | Opus | 1 Low, | x |",
        "| 3 | Opus | 1 Low | separators such as `|----|` |",
        "| 3 | Opus | 1 Low |",
    ]
    findings_ok = [
        "| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |",
        "| --- | --- | --- | --- | --- | --- | --- |",
        "| 2026-10-29 | #1 | x | correctness | valid | not checked | – |",
        "| 2026-10-29 | #1 | x | correctness | not valid | – | – |",
    ]
    findings_bad = [
        "| 2026-10-29 | #1 | x | correctness | valid | – | – |",
        "| 2026-10-29 | #1 | x | correctness | not valid | not checked | – |",
        "| 2026-10-29 | #1 | x | correctness | bogus | – | – |",
        "| 2026-10-8 | #1 | x | correctness | valid | not checked | – |",
        "|2026-10-29 | #1 | x | correctness | valid | not checked |",
    ]
    failures = []
    for row in retros_ok:
        if problems := check_retros(header + row):
            failures.append(f"self-test: refused a valid retros row {row!r}: {problems}")
    for row in retros_bad:
        if not check_retros(header + row):
            failures.append(f"self-test: accepted a bad retros row {row!r}")
    for row in findings_ok:
        if problems := check_findings(row):
            failures.append(f"self-test: refused a valid findings row {row!r}: {problems}")
    for row in findings_bad:
        if not check_findings(row):
            failures.append(f"self-test: accepted a bad findings row {row!r}")
    return failures


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        problems = self_test()
    else:
        problems = self_test() + check_retros(
            (ROOT / "docs/review-retros.md").read_text()
        ) + check_findings((ROOT / "docs/coderabbit-findings.md").read_text())
    for problem in problems:
        print(problem)
    sys.exit(1 if problems else 0)
