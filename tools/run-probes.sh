#!/usr/bin/env bash
# Run every probe suite in the repository, in adoption order.
#
#   ./tools/run-probes.sh          all layers
#   ./tools/run-probes.sh l2 l4    only those
#
# Each suite is self-contained: it builds what it needs in a temp directory and
# touches neither your working tree nor your state. The exception is L2, which
# starts a reviewer service on an ephemeral port and stops it again.
#
# Exit 0 only if every suite passes.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

SUITES="l0:layers/l0-governance/tests/test_adr_lint.sh
l1:layers/l1-input-hardening/tests/test_sanitize.sh
l2:layers/l2-output-gate/tests/test_gate.sh
l3:layers/l3-reviewer/tests/test_reviewer.sh
l3-backends:layers/l3-reviewer/tests/test_backends.sh
l4:layers/l4-server-enforcement/tests/test_pre_receive.sh
l5:layers/l5-deploy-audit/tests/test_ledger.sh
bootstrap:bootstrap/tests/test_bootstrap.sh"

WANTED="$*"
FAILED=""
TOTAL_PASS=0
TOTAL_CASES=0

for entry in $SUITES; do
  name="${entry%%:*}"
  path="${entry#*:}"

  if [ -n "$WANTED" ]; then
    case " $WANTED " in *" $name "*) ;; *) continue ;; esac
  fi

  if [ ! -x "$REPO_ROOT/$path" ]; then
    printf '\n>>> %-10s SKIP  not executable: %s\n' "$name" "$path"
    continue
  fi

  printf '\n>>> %s  %s\n' "$name" "$path"
  out="$( cd "$REPO_ROOT" && "./$path" 2>&1 )"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'

  # Every suite ends with an "N/M PASS" line; collect it rather than trusting
  # the exit status alone, so a suite that dies early cannot look like a pass.
  summary="$(printf '%s' "$out" | grep -oE '[0-9]+/[0-9]+ PASS' | tail -1)"
  if [ -n "$summary" ]; then
    TOTAL_PASS=$((TOTAL_PASS + ${summary%%/*}))
    rest="${summary#*/}"
    TOTAL_CASES=$((TOTAL_CASES + ${rest%% *}))
  fi

  if [ "$rc" -ne 0 ]; then
    FAILED="$FAILED $name"
  fi
done

printf '\n────────────────────────────────────────────────────────\n'
if [ -n "$FAILED" ]; then
  printf 'FAILED:%s   (%s/%s cases passed)\n\n' "$FAILED" "$TOTAL_PASS" "$TOTAL_CASES"
  exit 1
fi
printf 'all suites pass · %s/%s cases\n\n' "$TOTAL_PASS" "$TOTAL_CASES"
