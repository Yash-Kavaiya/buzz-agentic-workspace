#!/usr/bin/env python3
"""Check that the environment roots wire the modules together correctly.

`terraform validate` catches this, but only after `init` has downloaded the
provider schemas — which needs registry access. This check needs nothing, so it
runs on any machine and in the fast CI lane, and it catches the class of error
that is easiest to introduce when editing a module: renaming a variable or an
output and missing one call site.

What it checks, per environment root:

  - every `module` block's source resolves to a real module directory
  - every argument passed corresponds to a declared variable
  - every variable without a default is actually passed
  - every `module.<call>.<attr>` reference names a declared output

Run: python3 tests/lint_terraform_wiring.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import hcl2

ROOT = Path(__file__).resolve().parent.parent / "terraform"

# python-hcl2 returns block labels and string values with their quotes intact,
# and injects synthetic dunder keys into block bodies (__is_block__ for the
# block marker, __comments__ where a comment sits inside the block).
def is_synthetic(key: str) -> bool:
    return key.startswith("__") and key.endswith("__")

# Meta-arguments belong to Terraform, not to the module's variables.
META_ARGUMENTS = {
    "source", "version", "providers", "count", "for_each", "depends_on", "lifecycle",
}

SOURCE_PATTERN = re.compile(r"^\.\./\.\./modules/(.+)$")
REFERENCE_PATTERN = re.compile(r"module\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")


def unquote(value: object) -> str:
    text = str(value).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def load(path: Path) -> dict:
    with path.open() as handle:
        return hcl2.load(handle)


def module_interface(directory: Path) -> tuple[set[str], set[str], set[str]]:
    """(declared variables, variables without a default, declared outputs)."""
    declared: set[str] = set()
    required: set[str] = set()
    outputs: set[str] = set()

    for path in sorted(directory.glob("*.tf")):
        document = load(path)
        for block in document.get("variable", []):
            for name, body in block.items():
                name = unquote(name)
                declared.add(name)
                if "default" not in body:
                    required.add(name)
        for block in document.get("output", []):
            outputs.update(unquote(name) for name in block)

    return declared, required, outputs


def main() -> int:
    modules = {
        directory.name: module_interface(directory)
        for directory in sorted((ROOT / "modules").iterdir())
        if directory.is_dir()
    }
    if not modules:
        print(f"no modules found under {ROOT / 'modules'}", file=sys.stderr)
        return 1

    problems: list[str] = []
    checked_calls = 0

    for env_dir in sorted((ROOT / "environments").iterdir()):
        main_tf = env_dir / "main.tf"
        if not env_dir.is_dir() or not main_tf.exists():
            continue

        document = load(main_tf)
        call_to_module: dict[str, str] = {}

        for block in document.get("module", []):
            for raw_name, body in block.items():
                call = unquote(raw_name)
                source = unquote(body.get("source", ""))

                match = SOURCE_PATTERN.match(source)
                if not match:
                    problems.append(f"{env_dir.name}: module.{call} has source {source!r}, "
                                    "expected ../../modules/<name>")
                    continue

                module_name = match.group(1)
                if module_name not in modules:
                    problems.append(f"{env_dir.name}: module.{call} points at "
                                    f"{module_name!r}, which does not exist")
                    continue

                call_to_module[call] = module_name
                checked_calls += 1

                declared, required, _ = modules[module_name]
                passed = {
                    unquote(key) for key in body
                    if key not in META_ARGUMENTS and not is_synthetic(key)
                }

                for unknown in sorted(passed - declared):
                    problems.append(f"{env_dir.name}: module.{call} ({module_name}) passes "
                                    f"{unknown!r}, which the module does not declare")
                for missing in sorted(required - passed):
                    problems.append(f"{env_dir.name}: module.{call} ({module_name}) does not "
                                    f"pass {missing!r}, which has no default")

        # Output references, across every file in the root — outputs.tf reaches
        # into the modules just as heavily as main.tf does.
        text = "\n".join(path.read_text() for path in sorted(env_dir.glob("*.tf")))
        seen: set[tuple[str, str]] = set()
        for call, attribute in REFERENCE_PATTERN.findall(text):
            if (call, attribute) in seen:
                continue
            seen.add((call, attribute))

            if call not in call_to_module:
                problems.append(f"{env_dir.name}: module.{call}.{attribute} references a "
                                "module call that is not declared here")
                continue

            _, _, outputs = modules[call_to_module[call]]
            if attribute not in outputs:
                problems.append(f"{env_dir.name}: module.{call}.{attribute} — "
                                f"{call_to_module[call]} declares no output {attribute!r}")

    for problem in problems:
        print(f"FAIL {problem}", file=sys.stderr)

    if problems:
        print(f"\n{len(problems)} wiring problem(s)", file=sys.stderr)
        return 1

    print(f"ok   {checked_calls} module call(s) across "
          f"{len(modules)} modules wire up correctly")
    print("note: this does not replace `terraform validate`, which also checks "
          "provider schemas.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
