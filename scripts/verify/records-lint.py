#!/usr/bin/env python3
"""Checks the review records against the values their own rules allow.

docs/review-retros.md: each review row's findings are counts of a defined severity, or none.
docs/coderabbit-findings.md: each row has its columns, a defined verdict and a defined miss cause.
Exits non-zero, listing each bad row, when one does not fit. Run by CI and scripts/verify/prepush.sh.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEVERITIES = {"Critical", "High", "Medium", "Low", "Minor", "unrated", "Major", "Trivial"}
VERDICTS = {"valid", "accepted", "not valid"}
MISSED = {"not checked", "judged fine", "outside the diff", "not in the requirements", "after the loop", "–"}


def cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


problems = []


def table_rows(path: Path, header: str, first_cell: re.Pattern[str], expected: str):
    """The rows of `path`'s tables headed by `header`; a row whose first cell does not fit is
    reported, not skipped."""
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.lstrip().startswith("|"):
            continue
        row = cells(line)
        if row[0] in (header, "---"):
            continue
        if first_cell.fullmatch(row[0]):
            yield number, row
        else:
            problems.append(f"{path.name}:{number}: first cell {row[0]!r} is not {expected}")


retros = ROOT / "docs/review-retros.md"
for number, row in table_rows(
    retros, "Review", re.compile(r"\d+(?: \(.+\))?|direct|CodeRabbit"), "a round number, direct or CodeRabbit"
):
    findings = row[2] if len(row) > 2 else ""
    if findings == "none":
        continue
    for part in findings.split(","):
        match = re.fullmatch(r"(\d+) (\w+)(?: \(.+\))?", part.strip())
        if not match or match.group(2) not in SEVERITIES:
            problems.append(
                f"{retros.name}:{number}: findings {part.strip()!r} is not a count of "
                f"{', '.join(sorted(SEVERITIES))}, or none"
            )

findings_log = ROOT / "docs/coderabbit-findings.md"
for number, row in table_rows(findings_log, "Date", re.compile(r"\d{4}-\d{2}-\d{2}"), "a date (YYYY-MM-DD)"):
    if len(row) != 7:
        problems.append(f"{findings_log.name}:{number}: {len(row)} columns, the table has 7")
        continue
    verdict, missed = row[4], row[5]
    if verdict not in VERDICTS:
        problems.append(f"{findings_log.name}:{number}: verdict {verdict!r} is not one of {sorted(VERDICTS)}")
    if missed not in MISSED:
        problems.append(f"{findings_log.name}:{number}: missed because {missed!r} is not one of {sorted(MISSED)}")
    if (verdict == "not valid") != (missed == "–"):
        problems.append(
            f"{findings_log.name}:{number}: missed because is – exactly when the verdict is not valid, "
            f"here {verdict!r} with {missed!r}"
        )

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
