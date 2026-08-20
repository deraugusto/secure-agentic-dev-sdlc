#!/usr/bin/env bash
# bootstrap/init.sh — assign roles, install the layers you chose, seal the rest.
#
#   ./bootstrap/init.sh --dry-run              full plan, nothing touched
#   ./bootstrap/init.sh                        interactive questionnaire
#   ./bootstrap/init.sh --profile single-host
#   ./bootstrap/init.sh --answers my.answers --non-interactive
#
# Idempotent: a second run reports what is already in place and changes only
# what drifted. Every mutation goes through `act` in lib/common.sh, which is
# also what --dry-run intercepts -- so the plan is the run, printed instead of
# executed, rather than a separate description of it that can fall out of date.

set -euo pipefail

# A dry run that leaves .pyc files behind has already touched the tree it
# promised not to touch. The cost of never caching bytecode here is a few
# milliseconds; the cost of a --dry-run that is almost true is the trust in it.
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/questionnaire.sh
. "$HERE/lib/questionnaire.sh"

PROFILE="existing-infra"
ANSWERS_FILE=""
FORCE=0

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nProfiles:\n'
  for _p in "$HERE"/profiles/*.profile; do
    # shellcheck disable=SC1090
    ( . "$_p"; printf '  %-16s %s\n' "$PROFILE_NAME" "$PROFILE_SUMMARY" )
  done
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)         PROFILE="${2:?--profile needs a name}"; shift 2 ;;
    --dry-run)         SDLC_DRY_RUN=1; shift ;;
    --answers)         ANSWERS_FILE="${2:?--answers needs a path}"; shift 2 ;;
    --non-interactive) SDLC_ASSUME_YES=1; shift ;;
    --force)           FORCE=1; shift ;;
    -h|--help)         usage ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

INVENTORY="$REPO_ROOT/inventory.yaml"

# ── Phase 0 · preflight ────────────────────────────────────────────────────
step "Preflight"

command -v python3 >/dev/null 2>&1 \
  || die "python3 not found. The baseline is stdlib-only, but it is not
         shell-only: the inventory parser, the gate and the reviewer are
         Python. Install python3 and re-run."
info "python3        $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"

HAVE_GIT=0
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  HAVE_GIT=1
  GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
  case "$GIT_DIR" in /*) ;; *) GIT_DIR="$REPO_ROOT/$GIT_DIR" ;; esac
  info "git repo       $GIT_DIR"
else
  GIT_DIR=""
  warn "not a git repository. L1 and L2 install their guards as git hooks, so
        those steps will be reported as skipped. Run 'git init' first if you
        want them. Everything else works without git."
fi

PROFILE_PATH="$HERE/profiles/$PROFILE.profile"
[ -f "$PROFILE_PATH" ] || die "unknown profile '$PROFILE'. Available: $(cd "$HERE/profiles" && ls *.profile | sed 's/\.profile//' | tr '\n' ' ')"
# shellcheck disable=SC1090
. "$PROFILE_PATH"
info "profile        $PROFILE_NAME — $PROFILE_SUMMARY"

if [ -n "$ANSWERS_FILE" ]; then
  [ -f "$ANSWERS_FILE" ] || die "answers file not found: $ANSWERS_FILE"
  # shellcheck disable=SC1090
  . "$ANSWERS_FILE"
  info "answers        $ANSWERS_FILE"
fi

if [ -f "$INVENTORY" ] && [ "$FORCE" -eq 0 ] && [ "$SDLC_DRY_RUN" != "1" ]; then
  info "inventory      exists — answers you leave blank keep their current value"
fi

# ── Phase 1 · questionnaire ────────────────────────────────────────────────
questionnaire_run

# ── Phase 2 · show the assignment, and make someone confirm it ─────────────
#
# This gate exists because the failure it prevents is expensive and quiet: a
# mistyped node identifier in a provisioning profile creates containers on
# infrastructure that is not yours, and nothing about the run looks wrong until
# someone else finds them.
step "Confirmation"
role_table

printf '\n  %sWhat this profile does NOT give you%s\n\n' "$C_BOLD" "$C_OFF"
profile_not_delivered

if [ "$ANS_PROVISIONER" = "proxmox" ]; then
  printf '\n'
  warn "provisioner=proxmox will CREATE containers and firewall rules on the
        hypervisor named above. Check the role table before answering."
fi

if [ "$SDLC_DRY_RUN" = "1" ]; then
  printf '\n  %s(dry run — this is where the real run would ask you to confirm)%s\n' \
    "$C_DIM" "$C_OFF"
else
  confirm "Assign the roles exactly as shown above?"
fi

# ── Phase 3 · inventory.yaml ───────────────────────────────────────────────
step "inventory.yaml"

export ANS_PROFILE="$PROFILE_NAME"
export ANS_DEV_ADDR ANS_AUTHOR_MODEL
export ANS_GIT_ADDR ANS_GIT_TYPE ANS_GIT_USER ANS_GIT_REPO_PATH ANS_GIT_SSH_PORT
export ANS_REVIEWER_ADDR ANS_REVIEWER_PORT ANS_REVIEWER_PROVIDER
export ANS_REVIEWER_MODEL ANS_REVIEWER_API_KEY_ENV
export ANS_TARGET_NAME ANS_TARGET_ADDR ANS_TARGET_USER ANS_TARGET_PATH ANS_TARGET_SMOKE_URL
export ANS_PROVISIONER ANS_SINK_ADDR ANS_SINK_PATH
export ANS_L0 ANS_L1 ANS_L2 ANS_L3 ANS_L4 ANS_L5

RENDER="$HERE/lib/render_inventory.py"

# The renderer validates before it writes, so a dry run gets the same refusal a
# real run would get -- found now, not after someone confirmed a role table.
if ! python3 "$RENDER" --print >/dev/null; then
  die "the answers do not produce a valid inventory (see the errors above).
         No file was written. Re-run and correct the assignment."
fi

if [ "$SDLC_DRY_RUN" = "1" ]; then
  act "write $INVENTORY (mode 0600)" true
  dim "rendered inventory, for review:"
  python3 "$RENDER" --print | sed 's/^/         /'
elif [ -f "$INVENTORY" ] && [ "$FORCE" -eq 0 ] \
     && python3 "$RENDER" --print | cmp -s - "$INVENTORY"; then
  act_noop "$INVENTORY matches the answers"
else
  act "write $INVENTORY (mode 0600)" python3 "$RENDER" --out "$INVENTORY"
fi

# ── Phase 4 · validate, fail closed ────────────────────────────────────────
step "Validation"
if [ "$SDLC_DRY_RUN" = "1" ]; then
  TMP_INV="$(mktemp)"
  trap 'rm -f "$TMP_INV"' EXIT
  python3 "$RENDER" --print > "$TMP_INV"
  python3 "$REPO_ROOT/lib/inventory.py" --inventory "$TMP_INV" --validate \
    || die "the planned inventory is rejected by its own validator."
else
  python3 "$REPO_ROOT/lib/inventory.py" --inventory "$INVENTORY" --validate \
    || die "inventory.yaml written but rejected. Fix it and re-run:
         python3 lib/inventory.py --validate"
fi

# ── Phase 5 · git hygiene ──────────────────────────────────────────────────
step "Repository hygiene"
GITIGNORE="$REPO_ROOT/.gitignore"
if [ -f "$GITIGNORE" ] && grep -qx 'inventory.yaml' "$GITIGNORE" 2>/dev/null; then
  act_noop "inventory.yaml is git-ignored"
else
  act "add inventory.yaml and .sdlc/ to .gitignore" \
    bash -c 'printf "\n# Written by bootstrap/init.sh. Your addresses are yours.\ninventory.yaml\n.sdlc/\n__pycache__/\n*.pyc\n" >> "$1"' _ "$GITIGNORE"
fi

# ── Phase 6 · install the layers ───────────────────────────────────────────
install_hook() {
  _name="$1"; _src="$2"
  if [ "$HAVE_GIT" -eq 0 ]; then
    dim "$_name — skipped, no git repository"
    return 0
  fi
  [ -f "$_src" ] || die "hook source missing: $_src"
  _dst="$GIT_DIR/hooks/$_name"
  if [ -f "$_dst" ] && cmp -s "$_src" "$_dst"; then
    act_noop ".git/hooks/$_name"
    return 0
  fi
  if [ -f "$_dst" ] && ! grep -q 'sdlc\|SDLC\|sanitize\|L2 ·\|L1 ·' "$_dst" 2>/dev/null; then
    warn "$_dst exists and was not written by this baseline.
        Refusing to overwrite someone else's hook. Move it aside and re-run."
    return 0
  fi
  act "install .git/hooks/$_name" install -m 0755 "$_src" "$_dst"
}

step "L0 · governance spine"
act "make the governance scripts executable" \
  chmod +x "$REPO_ROOT/layers/l0-governance/adr-lint.sh" "$REPO_ROOT/layers/l0-governance/commit-lint.sh"
# git hands the message file to commit-msg as $1, which is exactly the
# interface commit-lint.sh already has, so it installs as itself.
install_hook commit-msg "$REPO_ROOT/layers/l0-governance/commit-lint.sh"
dim "check it with: ./layers/l0-governance/adr-lint.sh"

step "L1 · input hardening"
if layer_on l1; then
  act "make the scanner and the wrapper executable" \
    chmod +x "$REPO_ROOT/layers/l1-input-hardening/sanitize.py" "$REPO_ROOT/layers/l1-input-hardening/agent-safe"
  install_hook post-merge    "$REPO_ROOT/layers/l1-input-hardening/hooks/post-merge"
  install_hook post-checkout "$REPO_ROOT/layers/l1-input-hardening/hooks/post-checkout"
  install_hook post-rewrite  "$REPO_ROOT/layers/l1-input-hardening/hooks/post-rewrite"
  dim "the wrapper seam is deliberately manual — see layers/l1-input-hardening/agent-safe"
else
  dim "disabled"
fi

step "L2 · output gate"
if layer_on l2; then
  act "make the gate executable" chmod +x "$REPO_ROOT/layers/l2-output-gate/pipeline.py"
  install_hook pre-push "$REPO_ROOT/layers/l2-output-gate/pre-push-hook.sh"
  act "seal the stage manifests" \
    python3 "$REPO_ROOT/layers/l2-output-gate/pipeline.py" --seal-manifests
else
  dim "disabled"
fi

step "L3 · independent review"
if layer_on l3; then
  act "make the reviewer executable" \
    chmod +x "$REPO_ROOT/layers/l3-reviewer/reviewer_service.py" "$REPO_ROOT/layers/l3-reviewer/hash-verify.sh"
  act "seal the reviewer apparatus" "$REPO_ROOT/layers/l3-reviewer/hash-verify.sh" --seal
  if [ "$ANS_REVIEWER_PROVIDER" = "offline" ]; then
    warn "reviewer provider is 'offline' — it returns a canned verdict. The gate
        mechanics are real, the review is not. Point it at a model before you
        rely on the GO token as evidence that anything was reviewed."
  elif [ "$PROFILE_PROVISIONS_MODEL" = "yes" ]; then
    dim "model provisioning: bootstrap/provision/proxmox/ (confirmed separately)"
  fi
else
  dim "disabled"
fi

step "L4 · server enforcement"
if layer_on l4; then
  act "make the installer and the hook executable" \
    chmod +x "$REPO_ROOT/layers/l4-server-enforcement/install-pre-receive.sh" "$REPO_ROOT/layers/l4-server-enforcement/pre-receive"
  if [ "$ANS_GIT_TYPE" = "github" ]; then
    warn "github.com cannot run this hook. L4 is NOT installed. Follow
        layers/l4-server-enforcement/branch-protection.md for the closest
        achievable configuration, and read the gap statement in it."
  else
    dim "the hook has to be installed on the server, over ssh:"
    dim "  ./layers/l4-server-enforcement/install-pre-receive.sh --remote --dry-run"
    dim "  ./layers/l4-server-enforcement/install-pre-receive.sh --remote"
    dim "not run automatically: this bootstrap does not assume it may write to"
    dim "your git server."
  fi
else
  dim "disabled"
fi

step "L5 · deploy + audit"
if layer_on l5; then
  act "make the deploy script and the ledger executable" \
    chmod +x "$REPO_ROOT/layers/l5-deploy-audit/deploy.sh" "$REPO_ROOT/layers/l5-deploy-audit/ledger.py"
  act "create the state directories" \
    mkdir -p "$REPO_ROOT/.sdlc/ledger" "$REPO_ROOT/.sdlc/audit" "$REPO_ROOT/.sdlc/snapshots" "$REPO_ROOT/.sdlc/run"
  dim "acceptance run: ./layers/l5-deploy-audit/deploy.sh --target ${ANS_TARGET_NAME:-hello-world} --local"
else
  dim "disabled"
fi

# ── Phase 7 · provisioning ─────────────────────────────────────────────────
if [ "$ANS_PROVISIONER" = "proxmox" ]; then
  step "Provisioning · proxmox"
  PROVISION="$HERE/provision/proxmox/provision.sh"
  if [ "$SDLC_DRY_RUN" = "1" ]; then
    act "run $PROVISION --plan" true
    "$PROVISION" --plan 2>/dev/null | sed 's/^/         /' || dim "(plan unavailable)"
  else
    act "provision containers and firewall rules" "$PROVISION" --apply
  fi
elif [ "$ANS_PROVISIONER" = "docker" ]; then
  step "Provisioning · docker"
  dim "not implemented in this baseline. The roles are containers you already"
  dim "know how to run; inventory.yaml is what the layers read. Provisioning is"
  dim "the one part that is genuinely yours."
fi

# ── Summary ────────────────────────────────────────────────────────────────
step "Summary"
if [ "$SDLC_DRY_RUN" = "1" ]; then
  printf '  %s steps planned, %snothing was changed%s.\n' "$SDLC_PLAN_COUNT" "$C_BOLD" "$C_OFF"
  printf '  Re-run without --dry-run to apply.\n'
  exit 0
fi

printf '  %s of %s steps changed something; the rest were already in place.\n' \
  "$SDLC_CHANGE_COUNT" "$SDLC_PLAN_COUNT"
cat <<TXT

  Next, in this order:

    1  ./layers/l0-governance/adr-lint.sh
       The governance spine, with no infrastructure involved. Must pass first.

    2  ./layers/l4-server-enforcement/tests/test_pre_receive.sh
       Proves the server-side guard refuses what it claims to refuse. It builds
       throwaway repositories in a temp directory and touches nothing of yours.

    3  ./layers/l5-deploy-audit/deploy.sh --target ${ANS_TARGET_NAME:-hello-world} --local
       Drives the example service through verify → snapshot → deploy → smoke,
       and records every phase in the hash-chained ledger.

    4  SDLC_BREAK_SMOKE=1 ./layers/l5-deploy-audit/deploy.sh --target ${ANS_TARGET_NAME:-hello-world} --local
       The negative probe. The smoke test fails on purpose and the deploy must
       roll back. A baseline that only shows the happy path teaches the wrong
       half.

  docs/bootstrap.md explains what each step just did, and docs/layers.md what
  each layer is worth on its own.
TXT
