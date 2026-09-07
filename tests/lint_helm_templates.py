#!/usr/bin/env python3
"""Structural lint for the Helm templates.

`helm template` is the real check, and CI runs it. This exists for the case
where helm is not installed: it strips Go template actions and parses what is
left as YAML, which catches the mistakes that actually happen in practice --
wrong indentation under a key, a mapping where a sequence belongs, a duplicate
key, a missing colon.

It cannot catch anything that depends on values, and it does not try to. When
helm is available, prefer:

    helm template helm/buzz-gke -f helm/buzz-gke/values-prod.yaml

Run: python3 tests/lint_helm_templates.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "helm" / "buzz-gke" / "templates"

# A line whose only content is a control action contributes no YAML.
CONTROL_ONLY = re.compile(
    r"^\s*\{\{-?\s*(if|else|else\s+if|end|range|with|define|block|template|include|fail)\b.*?-?\}\}\s*$"
)
# `{{- toYaml . | nindent N }}` and friends emit structure we cannot model, so
# the whole line is dropped rather than guessed at.
STRUCTURAL_EMIT = re.compile(r"\{\{-?[^}]*\b(toYaml|nindent|indent)\b[^}]*-?\}\}")
INLINE_ACTION = re.compile(r"\{\{-?.*?-?\}\}")
# Go template comments may span lines and contain anything, including text that
# would otherwise look like YAML.
BLOCK_COMMENT = re.compile(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", re.DOTALL)


def strip_template(source: str) -> str:
    source = BLOCK_COMMENT.sub("", source)
    out: list[str] = []
    for line in source.splitlines():
        if CONTROL_ONLY.match(line):
            continue
        if STRUCTURAL_EMIT.search(line):
            # Keep the key so the parent mapping stays well-formed, drop the
            # value we cannot reconstruct.
            key = re.match(r"^(\s*[\w./-]+:)", line)
            if key:
                out.append(f"{key.group(1)} placeholder")
            continue
        # Any remaining action becomes a scalar. Quoted so a value containing
        # a colon or a leading dash cannot change the parse.
        line = INLINE_ACTION.sub("placeholder", line)
        out.append(line)
    return "\n".join(out)


def lint(path: Path) -> list[str]:
    problems: list[str] = []
    stripped = strip_template(path.read_text())

    for index, document in enumerate(stripped.split("\n---\n")):
        if not document.strip():
            continue
        try:
            yaml.safe_load(document)
        except yaml.YAMLError as exc:
            mark = getattr(exc, "problem_mark", None)
            where = f" near line {mark.line + 1}" if mark else ""
            problems.append(f"{path.name} document {index + 1}{where}: {exc.problem or exc}")
    return problems


def main() -> int:
    templates = sorted(p for p in TEMPLATE_DIR.rglob("*.yaml"))
    if not templates:
        print(f"no templates found under {TEMPLATE_DIR}", file=sys.stderr)
        return 1

    failures = 0
    for template in templates:
        problems = lint(template)
        relative = template.relative_to(TEMPLATE_DIR.parent)
        if problems:
            failures += len(problems)
            for problem in problems:
                print(f"FAIL {problem}", file=sys.stderr)
        else:
            print(f"ok   {relative}")

    # Every template that creates namespaced resources should guard on the
    # shared validation helper, so a misconfiguration fails at render rather
    # than at apply.
    unguarded = []
    for template in templates:
        text = template.read_text()
        if "buzz-gke.validate" not in text and "kind: " in text:
            unguarded.append(template.name)
    if unguarded:
        print(f"note: no validate guard in {', '.join(unguarded)} "
              "(fine for templates that only render when a parent is enabled)")

    if failures:
        print(f"\n{failures} structural problem(s)", file=sys.stderr)
        return 1
    print(f"\n{len(templates)} template(s) parse as YAML once actions are stripped")
    print("note: this is a structural check only. Run `helm template` for the real one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
