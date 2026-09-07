#!/usr/bin/env bash
#
# Prove the conftest policies both parse and work.
#
# Parsing matters on its own: a Rego syntax error does not disable one rule, it
# stops the whole file loading — every check in it silently reports success.
# That happened once already, on a field GKE's CRDs name `default`, which is a
# Rego keyword and cannot be reached with dot notation.
#
# Working matters more. Two fixtures:
#   rendered-violations.yaml  one case per deny rule; every rule must fire
#   rendered-compliant.yaml   the same resources rendered correctly; none may
#
# A rule that never matches is worse than no rule, because it reports success
# forever. A rule that matches everything is just as useless.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

POLICY_DIR=policy/conftest
FIXTURES=tests/fixtures

if ! command -v conftest >/dev/null 2>&1; then
  echo "skipped: conftest is not installed. CI runs it."
  exit 0
fi

failures=0

# Every deny rule must have a case in the violations fixture that trips it.
expected_denies=$(grep -c '^deny contains msg if {' "$POLICY_DIR/helm.rego")
echo "helm.rego declares $expected_denies deny rule(s)"

output=$(conftest test --policy "$POLICY_DIR" "$FIXTURES/rendered-violations.yaml" 2>&1)
actual=$(grep -c '^.*FAIL' <<<"$output")

if [[ "$actual" -eq "$expected_denies" ]]; then
  echo "ok   all $actual deny rule(s) fire on the violations fixture"
else
  echo "FAIL $actual of $expected_denies deny rule(s) fired." >&2
  echo "     A rule with no case in tests/fixtures/rendered-violations.yaml is" >&2
  echo "     a rule nothing proves works. Add one." >&2
  echo "$output" >&2
  failures=$((failures + 1))
fi

if grep -qE '^.*WARN' <<<"$output"; then
  echo "ok   warn rules fire too"
else
  echo "FAIL no warn rule fired on the violations fixture" >&2
  failures=$((failures + 1))
fi

# And nothing may fire on correct input.
if conftest test --policy "$POLICY_DIR" "$FIXTURES/rendered-compliant.yaml" >/dev/null 2>&1; then
  echo "ok   the compliant fixture passes cleanly"
else
  echo "FAIL the compliant fixture was rejected — a rule matches correct input" >&2
  conftest test --policy "$POLICY_DIR" "$FIXTURES/rendered-compliant.yaml" >&2 2>&1
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo
  echo "$failures policy check(s) failed" >&2
  exit 1
fi
echo "policies parse, fire on violations, and stay quiet on correct input"
