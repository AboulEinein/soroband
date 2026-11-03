#!/usr/bin/env python3
"""Checks the review records against the values their own rules allow.

docs/review-retros.md: each review row's findings are counts of a defined severity, or none; an entry's
table has no line that is not a row up to its **Retro.** paragraph.
docs/coderabbit-findings.md: each row has its columns, a defined verdict and a defined miss cause; the
table has no line that is not a row to the end of the file.
Both: no git conflict markers.
Exits non-zero, listing each bad row or line, when one does not fit. Run by CI and scripts/verify/prepush.sh.
`--self-test` checks the lint itself on rows it must accept and rows it must refuse.
"""

import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The pr-review skill's scale for blind rounds and direct reviews, and CodeRabbit's own.
SEVERITIES = {"Critical", "High", "Medium", "Low", "Minor", "unrated"}
CODERABBIT_SEVERITIES = {"Critical", "Major", "Minor", "Trivial"}
VERDICTS = {"valid", "accepted", "not valid"}
MISSED = {"not checked", "judged fine", "outside the diff", "not in the requirements", "after the loop", "–"}
SEPARATOR = re.compile(r":?-{3,}:?")
REVIEW_LABEL = re.compile(r"\d+(?: \(.+\))?|direct|CodeRabbit")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
CONFLICT_MARKER = re.compile(r"(?:<{7}|\|{7}|>{7})(?: .*)?|={7}")
NEVER = re.compile(r"(?!)")
RETROS_HEADER = "| Review | Model | Findings | Origins |"
FINDINGS_HEADER = "| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |"


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


def conflict_markers(text: str, name: str, problems: list[str]):
    """Reports each line that is a git conflict marker."""
    for number, line in enumerate(text.splitlines(), 1):
        if CONFLICT_MARKER.fullmatch(line):
            problems.append(f"{name}:{number}: git conflict marker {line!r}")


def unbroken_tables(
    text: str, name: str, header: str, header_row: str, table_end: re.Pattern[str], problems: list[str]
):
    """Reports each line that is not a row inside a table headed by `header`, and each row outside
    every such table. A table is the log's own form: exactly `header_row`, then a separator of
    one `---` cell per column, then rows, each starting at the line's first character. It
    ends at the first line `table_end` matches, at the next `## ` heading, or at the end of the
    file; the blank lines before that end belong to no table."""
    lines = text.splitlines()
    columns = len(cells(header_row))
    separator = "|" + " --- |" * columns
    in_table: set[int] = set()
    index = 0
    while index < len(lines):
        if not lines[index].startswith("|") or cells(lines[index])[0] != header:
            index += 1
            continue
        if lines[index].rstrip() != header_row:
            problems.append(f"{name}:{index + 1}: table header is not {header_row!r}")
            index += 1
            continue
        if index + 1 >= len(lines) or lines[index + 1].rstrip() != separator:
            problems.append(f"{name}:{index + 1}: table header not followed by its separator {separator!r}")
            index += 1
            continue
        end = index + 1
        while end < len(lines) and not table_end.match(lines[end]) and not lines[end].startswith("## "):
            end += 1
        last = end
        while last > index and not lines[last - 1].strip():
            last -= 1
        in_table.update(range(index, last))
        for number in range(index + 1, last):
            if not lines[number].startswith("|"):
                what = "blank line" if not lines[number].strip() else "line that is not a row"
                problems.append(f"{name}:{number + 1}: {what} inside the table that starts at line {index + 1}")
        index = end
    for number, line in enumerate(lines):
        if line.lstrip().startswith("|") and number not in in_table and not CONFLICT_MARKER.fullmatch(line):
            problems.append(f"{name}:{number + 1}: table row outside every table")


def check_retros(text: str, name: str = "review-retros.md") -> list[str]:
    problems: list[str] = []
    conflict_markers(text, name, problems)
    unbroken_tables(text, name, "Review", RETROS_HEADER, re.compile(r"\*\*Retro\.\*\*"), problems)
    for number, row in table_rows(text, name, "Review", REVIEW_LABEL, "a round number, direct or CodeRabbit", problems):
        if len(row) != 4:
            problems.append(f"{name}:{number}: {len(row)} columns, the table has 4")
            continue
        findings = row[2]
        if findings == "none":
            continue
        scale = CODERABBIT_SEVERITIES if row[0] == "CodeRabbit" else SEVERITIES
        # Commas inside a note in parentheses do not separate counts.
        for part in re.split(r",\s*(?![^()]*\))", findings):
            match = re.fullmatch(r"([1-9]\d*) (\w+)(?: \(.+\))?", part.strip())
            if not match or match.group(2) not in scale:
                problems.append(
                    f"{name}:{number}: findings {part.strip()!r} is not a count of "
                    f"{', '.join(sorted(scale))}, or none"
                )
    return problems


def check_findings(text: str, name: str = "coderabbit-findings.md") -> list[str]:
    problems: list[str] = []
    conflict_markers(text, name, problems)
    unbroken_tables(text, name, "Date", FINDINGS_HEADER, NEVER, problems)
    for number, row in table_rows(text, name, "Date", DATE, "a date (YYYY-MM-DD)", problems):
        try:
            datetime.date.fromisoformat(row[0])
        except ValueError:
            problems.append(f"{name}:{number}: {row[0]!r} is not a date")
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
        "| CodeRabbit | CodeRabbit | 1 High | x |",
        "| 4 | Opus | 1 Major | x |",
        "| 2 | Opus | 0 Low | x |",
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
        "| 2026-13-45 | #1 | x | correctness | valid | not checked | – |",
        "|2026-10-29 | #1 | x | correctness | valid | not checked |",
    ]
    entry = "## [#1](https://example.test/1) title (2026-01-01)\n\nPlanned rounds: 1.\n\n"
    table = header + "| --- | --- | --- | --- |\n| 1 | Opus | none | x |\n"
    retro = "\n**Retro.** x\n"
    retros_docs_ok = [
        entry + table + retro,
        entry + table,
        entry + table + "\n\n" + retro,
        entry + table + retro + "\nprose after the retro\n\n## [#2](u) t (2026-01-02)\n\n" + table + retro,
        entry + table + "\n## [#2](u) t (2026-01-02)\n\nPlanned rounds: 1.\n",
        entry + "no table yet\n",
        entry + table + retro + "a line mentioning ======= or <<<<<<< inside prose\n",
    ]
    retros_docs_bad = [
        entry + table + "\n| 2 | Opus | none | x |\n" + retro,
        entry + table + "\n| 2 | Opus | none | x |\n",
        entry + table + "prose\n" + retro,
        entry + table + "<<<<<<< HEAD\n| 2 | Opus | none | x |\n=======\n| 3 | Opus | none | x |\n>>>>>>> main\n" + retro,
        entry + table + retro + "=======\n",
        entry + table + retro + "<<<<<<<\n",
        entry + table + retro + ">>>>>>> origin/main\n",
        entry + table + retro + "||||||| merged common ancestors\n",
        entry + table + retro + "| 2 | Opus | none | x |\n",
        entry + header + "| 1 | Opus | none | x |\n" + retro,
        entry + header + "|---|---|---|---|\n| 1 | Opus | none | x |\n" + retro,
        entry + "| Review | Model |\n| --- | --- | --- | --- |\n| 1 | Opus | none | x |\n" + retro,
        entry + header + "    | --- | --- | --- | --- |\n| 1 | Opus | none | x |\n" + retro,
        entry + table + "    | 2 | Opus | none | x |\n" + retro,
    ]
    findings_table = "| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |\n| --- | --- | --- | --- | --- | --- | --- |\n"
    row = "| 2026-10-29 | #1 | x | correctness | valid | not checked | – |\n"
    findings_docs_ok = [
        "# Title\n\nProse.\n\n" + findings_table + row,
        "# Title\n\n" + findings_table + row + row + "\n",
        "# Title\n\nProse mentioning ======= and <<<<<<< inline.\n",
    ]
    findings_docs_bad = [
        "# Title\n\n" + findings_table + row + "\n" + row,
        "# Title\n\n" + findings_table + "\n" + row,
        "# Title\n\n" + findings_table + row + "prose\n" + row,
        "# Title\n\n" + findings_table + row + "<<<<<<< HEAD\n" + row + "=======\n" + row + ">>>>>>> main\n",
        "# Title\n\n" + findings_table + row + "=======\n",
        "# Title\n\n=======\n\n" + findings_table + row,
        "# Title\n\n||||||| ---\n\n" + findings_table + row,
        "# Title\n\n" + row + "\n" + findings_table + row,
        "# Title\n\n| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |\n" + row,
        "# Title\n\n| Date | PR |\n| --- | --- | --- | --- | --- | --- | --- |\n" + row,
        "# Title\n\n| Date | PR | Finding | Category | Missed because | Verdict | Follow-up |\n"
        + "| --- | --- | --- | --- | --- | --- | --- |\n"
        + row,
        "# Title\n\n" + findings_table + row + "||||||| ---\n" + row,
    ]
    failures = []
    for text in retros_docs_ok:
        if problems := check_retros(text):
            failures.append(f"self-test: refused a valid retros document {text!r}: {problems}")
    for text in retros_docs_bad:
        if not check_retros(text):
            failures.append(f"self-test: accepted a bad retros document {text!r}")
    for text in findings_docs_ok:
        if problems := check_findings(text):
            failures.append(f"self-test: refused a valid findings document {text!r}: {problems}")
    for text in findings_docs_bad:
        if not check_findings(text):
            failures.append(f"self-test: accepted a bad findings document {text!r}")
    for row in retros_ok:
        if problems := check_retros(header + "| --- | --- | --- | --- |\n" + row):
            failures.append(f"self-test: refused a valid retros row {row!r}: {problems}")
    for row in retros_bad:
        if not check_retros(header + "| --- | --- | --- | --- |\n" + row):
            failures.append(f"self-test: accepted a bad retros row {row!r}")
    for row in findings_ok:
        if problems := check_findings(findings_table + row):
            failures.append(f"self-test: refused a valid findings row {row!r}: {problems}")
    for row in findings_bad:
        if not check_findings(findings_table + row):
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
