#!/usr/bin/env python3
"""Code footprint analyzer for the Odin sources.

There is no Odin complexity linter in the toolchain, so this is the measuring
instrument the project is missing: it answers "which functions are the big,
branchy, deeply-nested ones" with numbers instead of impressions, so
refactoring targets are chosen by measurement (AGENTS.md 9) rather than by
whichever function happened to be annoying that day.

Heuristic, not a compiler: proc bodies are found by brace matching over
comment-stripped source, and cyclomatic complexity is approximated by counting
control-flow tokens. It is calibrated to rank Odin procs against each other,
which is all it is used for.

Usage:
  scripts/footprint.py                     # top tables to stdout
  scripts/footprint.py --top 30            # widen the tables
  scripts/footprint.py --file render.odin  # restrict to one file
  scripts/footprint.py --csv               # machine-readable (one row per proc)
"""

import argparse
import re
import sys
from pathlib import Path

# Control-flow tokens that add a branch. Each is a place the function can take
# a different path, so each adds ~1 to cyclomatic complexity. `&&`/`||` count
# because in Odin they are short-circuit branches, not just operators.
BRANCH_RE = re.compile(
    r"\b(?:if|else\s+if|for|switch|case|when|or_return|or_else|or_break|or_continue)\b"
    r"|&&|\|\|"
)
# A subset of branches that open a nested scope, used for the depth metric.
NESTING_RE = re.compile(
    r"\b(?:if|else|for|switch|case|when|do)\b"
)
PROC_RE = re.compile(r"^[ \t]*(?:@\([^)]*\)\s*)?(\w+)\s*::\s*proc\b", re.MULTILINE)
# `proc` declared without a body: foreign imports, and procedure values used as
# constants. They have no footprint to measure, so the matcher skips them.
FOREIGN_RE = re.compile(r"proc\s+\"[^\"]*\"\s*\(")
IDENT_RE = re.compile(r"\w+")

# Branch token -> how much a single occurrence is worth. The keywords and the
# short-circuit operators are all one branch; kept as a table so the metric is
# named in one place instead of a magic number buried in a sum.
BRANCH_WEIGHTS = {"if": 1, "for": 1, "case": 1, "when": 1}


def strip_comments(src):
    """Remove // and /* */ comments so brace/keyword counts are not fooled by
    prose. String bodies are left alone; a brace inside a string literal would
    be a false brace, but Odin string literals containing unbalanced braces are
    rare enough in this tree that a full lexer would be over-engineering."""
    out = []
    i, n = 0, len(src)
    in_block = False
    while i < n:
        c = src[i]
        if in_block:
            if c == "*" and i + 1 < n and src[i + 1] == "/":
                in_block = False
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def find_body(text, start):
    """Return (open_idx, close_idx) of a proc body starting at `start`, or None.

    The body opener is the first `{` at paren-depth 0 after the declaration
    (a return tuple is parenthesized, so a brace at depth 0 is the body). The
    closer is the matching `}` by depth counting. Returns None for a bodyless
    (foreign) declaration."""
    depth_paren = 0
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth_paren += 1
        elif c == ")":
            depth_paren -= 1
        elif c == "{" and depth_paren == 0:
            # Found the body opener; now match braces to find the closer.
            depth = 0
            j = i
            while j < n:
                if text[j] == "{":
                    depth += 1
                elif text[j] == "}":
                    depth -= 1
                    if depth == 0:
                        return (i, j)
                j += 1
            return None  # unbalanced: not a real function
        elif c == ";" and depth_paren == 0:
            return None  # statement-level decl, no body
        i += 1
    return None


def max_nesting(text):
    """Depth of the most deeply nested control structure, by brace depth.

    The first version accumulated nesting keywords without a matching
    decrement and drifted upward (reporting 50+ levels that do not exist), so
    this tracks real brace depth: the deepest line that still contains a
    control-flow keyword."""
    depth = 0
    peak = 0
    for line in text.splitlines():
        opens = line.count("{")
        closes = line.count("}")
        if opens:
            depth += opens
        if NESTING_RE.search(line) and depth > peak:
            peak = depth
        if closes:
            depth -= closes
            if depth < 0:
                depth = 0
    return peak


def analyze_file(path):
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_comments(raw)
    lines = raw.splitlines()
    results = []
    for m in PROC_RE.finditer(text):
        name = m.group(1)
        # Skip a bodyless declaration (foreign / procedure value).
        span_start = m.start()
        sig_end = text.find(")", m.end())
        if sig_end != -1 and FOREIGN_RE.search(text[m.start():sig_end + 1]):
            # May still have a body; only treat as foreign if no body follows.
            pass
        body = find_body(text, span_start)
        if body is None:
            continue
        o, c = body
        body_text = text[o + 1:c]
        start_line = text.count("\n", 0, m.start()) + 1
        end_line = text.count("\n", 0, c) + 1
        # Code lines: non-blank, non-comment-only.
        code_lines = sum(
            1 for ln in body_text.splitlines() if ln.strip()
        )
        branches = 0
        for tok in BRANCH_RE.findall(body_text):
            if tok in ("&&", "||"):
                branches += 1
            else:
                branches += BRANCH_WEIGHTS.get(tok, 1)
        cyclo = 1 + branches
        nesting = max_nesting(body_text)
        # Argument count: the first parenthesized group after `proc`.
        args = 0
        popen = text.find("(", m.end() - 4 if m.end() >= 4 else m.end())
        if popen != -1 and popen < o:
            pdepth = 0
            for idx in range(popen, min(o, len(text))):
                if text[idx] == "(":
                    pdepth += 1
                elif text[idx] == ")":
                    pdepth -= 1
                    if pdepth == 0:
                        args = 0 if text[popen + 1:idx].strip() == "" else text[popen + 1:idx].count(",") + 1
                        break
        results.append(
            dict(
                name=name,
                file=path.name,
                start=start_line,
                lines=code_lines,
                span=end_line - start_line + 1,
                cyclo=cyclo,
                branches=branches,
                nesting=nesting,
                args=args,
            )
        )
    return results


def footprint(p):
    """A single sortable 'how much is this function' number: physical size,
    branching, and nesting all cost, weighted so a long flat function and a
    short but deeply-branched one both register. Weights are round numbers kept
    here so the metric is auditable in one place."""
    return p["lines"] + 2 * p["branches"] + 3 * p["nesting"]


def table(rows, key, title, width=52):
    rows = sorted(rows, key=key, reverse=True)[:width]
    print(f"\n=== {title} ===")
    print(f"{'function':<44} {'file':<22} {'lines':>6} {'cyclo':>6} {'nest':>5} {'args':>5}")
    print("-" * 92)
    for r in rows:
        print(
            f"{r['name']:<44} {r['file']:<22} {r['lines']:>6} "
            f"{r['cyclo']:>6} {r['nesting']:>5} {r['args']:>5}"
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=20, help="rows per table")
    ap.add_argument("--file", help="restrict to a single .odin file")
    ap.add_argument("--csv", action="store_true", help="one CSV row per proc")
    ap.add_argument("--min-lines", type=int, default=0)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    files = sorted(root.glob("*.odin"))
    if args.file:
        files = [f for f in files if f.name == args.file or f.name.startswith(args.file)]

    procs = []
    for f in files:
        procs.extend(analyze_file(f))

    if args.csv:
        print("file,name,start,lines,span,branches,cyclo,nesting,args,footprint")
        for p in sorted(procs, key=footprint, reverse=True):
            print(
                f"{p['file']},{p['name']},{p['start']},{p['lines']},{p['span']},"
                f"{p['branches']},{p['cyclo']},{p['nesting']},{p['args']},{footprint(p)}"
            )
        return 0

    total_lines = sum(p["lines"] for p in procs)
    big = [p for p in procs if p["lines"] >= args.min_lines]
    print(f"Odin procs: {len(procs)} across {len(files)} files; {total_lines} code lines in bodies")
    if big:
        top = sorted(big, key=footprint, reverse=True)
        n = max(1, len(top) // 20)
        share = sum(p["lines"] for p in top[:n]) / max(1, total_lines)
        print(f"Top {n} procs by footprint = {share:.1%} of all body lines")
    table(big, lambda p: p["lines"], "biggest by code lines", args.top)
    table(big, lambda p: p["cyclo"], "most complex by cyclomatic", args.top)
    table(big, lambda p: p["nesting"], "deepest nesting", 20)
    table(big, footprint, "biggest overall footprint", args.top)

    print("\n=== per-file body lines ===")
    per = {}
    for p in procs:
        per[p["file"]] = per.get(p["file"], 0) + p["lines"]
    for fn, ln in sorted(per.items(), key=lambda kv: kv[1], reverse=True):
        print(f"{fn:<28} {ln:>7}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
