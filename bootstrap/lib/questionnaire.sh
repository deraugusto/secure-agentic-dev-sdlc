#!/usr/bin/env bash
# bootstrap/lib/questionnaire.sh — the questions, and the table they produce.
#
# Answers land in ANS_* variables, which render_inventory.py reads from the
# environment. Questions are asked only for layers that are actually enabled:
# nobody should have to invent a git server address to use the governance
# spine, and asking anyway is how a layered baseline stops being layered.

# ── layer defaults from the profile ────────────────────────────────────────
apply_layer_defaults() {
  for _pair in $PROFILE_LAYERS_DEFAULT; do
    _layer="${_pair%%=*}"
    _value="${_pair#*=}"
    _upper="$(printf '%s' "$_layer" | tr 'a-z' 'A-Z')"
    eval "ANS_$_upper=\${ANS_$_upper:-\$_value}"
  done
}

layer_on() {
  eval "_v=\${ANS_$(printf '%s' "$1" | tr 'a-z' 'A-Z'):-false}"
  [ "$_v" = "true" ]
}

ask_layers() {
  step "Layers"
  dim "Each layer is independent. L0 is not optional — it needs no"
  dim "infrastructure and switching it off would leave nothing to govern."
  ask_yn ANS_L1 "L1 · input hardening (sanitize + git hooks)?"        "${ANS_L1:-yes}"
  ask_yn ANS_L2 "L2 · output gate (S0-S5, GO token, pre-push)?"       "${ANS_L2:-yes}"
  ask_yn ANS_L3 "L3 · independent review (reviewer service)?"         "${ANS_L3:-yes}"
  ask_yn ANS_L4 "L4 · server enforcement (pre-receive guard)?"        "${ANS_L4:-yes}"
  ask_yn ANS_L5 "L5 · deploy + audit (verified deploy, ledger)?"      "${ANS_L5:-yes}"
  # normalise yes/no to the true/false the renderer expects
  for _l in L1 L2 L3 L4 L5; do
    eval "_v=\${ANS_$_l}"
    case "$_v" in
      yes|true|1) eval "ANS_$_l=true" ;;
      *)          eval "ANS_$_l=false" ;;
    esac
  done
  ANS_L0=true
}

# ── the questions ──────────────────────────────────────────────────────────
ask_dev() {
  step "Role · dev — where code is written"
  ask ANS_DEV_ADDR "Address of the dev host" "localhost"
  dim ""
  dim "The model that writes your code. This is declared, not detected, and it"
  dim "is what the reviewer/author separation is checked against. Name the"
  dim "family you actually run — 'the same weights reviewing themselves' is a"
  dim "self-check with correlated blind spots, not a second opinion."
  ask ANS_AUTHOR_MODEL "Author model" "unknown-author-model"
}

ask_git() {
  layer_on l4 || { dim "L4 off — skipping the git server questions."; return 0; }
  step "Role · git — where pushes are evaluated"
  dim "This must not be the dev host. A dev host that owns the git server can"
  dim "remove the pre-receive hook, which is the one enforcement point a"
  dim "client cannot bypass."
  ask ANS_GIT_TYPE "Server type (gitea | gitlab | github | plain-ssh)" "gitea"
  case "$ANS_GIT_TYPE" in
    gitea|gitlab|github|plain-ssh) ;;
    *) die "unknown git type '$ANS_GIT_TYPE'" ;;
  esac
  if [ "$ANS_GIT_TYPE" = "github" ]; then
    warn "github.com does not run pre-receive hooks — they exist only on
        GitHub Enterprise Server. L4 will degrade to branch protection plus a
        CI approximation, which is client-bypassable in ways the hook is not.
        See layers/l4-server-enforcement/branch-protection.md."
  fi
  ask ANS_GIT_ADDR      "Git server address"                  ""
  ask ANS_GIT_USER      "SSH user on the git server"          "git"
  ask ANS_GIT_REPO_PATH "Path to the bare repository"         ""
  ask ANS_GIT_SSH_PORT  "SSH port"                            "22"
}

ask_reviewer() {
  layer_on l3 || { dim "L3 off — skipping the reviewer questions."; return 0; }
  step "Role · reviewer — the second opinion"
  dim "provider=offline returns a canned verdict: the gate mechanics are real,"
  dim "the review is not. It exists so the acceptance run works before you have"
  dim "a model, not as a resting state."
  ask ANS_REVIEWER_PROVIDER "Provider (ollama | openai-compat | offline)" "offline"
  case "$ANS_REVIEWER_PROVIDER" in
    ollama|openai-compat|offline) ;;
    *) die "unknown reviewer provider '$ANS_REVIEWER_PROVIDER'" ;;
  esac
  if [ "$ANS_REVIEWER_PROVIDER" = "offline" ]; then
    ANS_REVIEWER_MODEL="${ANS_REVIEWER_MODEL:-offline-canned}"
    ANS_REVIEWER_ADDR="${ANS_REVIEWER_ADDR:-127.0.0.1}"
  else
    ask ANS_REVIEWER_ADDR  "Reviewer endpoint address" ""
    ask ANS_REVIEWER_MODEL "Reviewer model (must not share a family with the author model)" ""
  fi
  ask ANS_REVIEWER_PORT        "Reviewer port"                 "8080"
  ask ANS_REVIEWER_API_KEY_ENV "Env var holding the API key"   "SDLC_REVIEWER_API_KEY"
}

ask_targets() {
  layer_on l5 || { dim "L5 off — skipping the deploy target questions."; return 0; }
  step "Role · targets — where the service ends up"
  dim "This must not be the dev host either. If the writing hand reaches the"
  dim "running service directly, the deployment boundary is decorative."
  ask ANS_TARGET_NAME      "Target name"                    "hello-world"
  ask ANS_TARGET_ADDR      "Target address"                 ""
  ask ANS_TARGET_USER      "Deploy user on the target"      "deploy"
  ask ANS_TARGET_PATH      "Deploy path on the target"      "/srv/hello-world"
  ask ANS_TARGET_SMOKE_URL "Smoke URL (must answer 200 with status: ok)" ""
}

ask_provisioner() {
  step "Role · provisioner and sink"
  ask ANS_PROVISIONER "Provisioner (proxmox | docker | none)" "$PROFILE_PROVISIONER_DEFAULT"
  case "$ANS_PROVISIONER" in
    proxmox|docker|none) ;;
    *) die "unknown provisioner '$ANS_PROVISIONER'" ;;
  esac
  ask ANS_SINK_ADDR "Audit sink address" "${ANS_DEV_ADDR:-localhost}"
  ask ANS_SINK_PATH "Audit sink path"    "./.sdlc/audit"
}

questionnaire_run() {
  apply_layer_defaults
  ask_layers
  ask_dev
  ask_git
  ask_reviewer
  ask_targets
  ask_provisioner
}

# ── the table · shown before anything is created ───────────────────────────
_row() { printf '  %-14s %s\n' "$1" "$2"; }

role_table() {
  printf '\n  %sRole assignment%s\n\n' "$C_BOLD" "$C_OFF"
  _row "profile"     "$PROFILE_NAME"
  _row "dev"         "${ANS_DEV_ADDR}   (author model: ${ANS_AUTHOR_MODEL})"
  if layer_on l4; then
    _row "git"       "${ANS_GIT_USER}@${ANS_GIT_ADDR}:${ANS_GIT_SSH_PORT}  ${ANS_GIT_REPO_PATH}  [${ANS_GIT_TYPE}]"
  else
    _row "git"       "— (L4 disabled)"
  fi
  if layer_on l3; then
    _row "reviewer"  "${ANS_REVIEWER_ADDR}:${ANS_REVIEWER_PORT}  ${ANS_REVIEWER_MODEL}  [${ANS_REVIEWER_PROVIDER}]"
  else
    _row "reviewer"  "— (L3 disabled)"
  fi
  if layer_on l5; then
    _row "targets"   "${ANS_TARGET_NAME} → ${ANS_TARGET_USER}@${ANS_TARGET_ADDR}:${ANS_TARGET_PATH}"
  else
    _row "targets"   "— (L5 disabled)"
  fi
  _row "provisioner" "${ANS_PROVISIONER}"
  _row "sink"        "${ANS_SINK_ADDR}  ${ANS_SINK_PATH}"

  printf '\n  %sLayers%s        ' "$C_BOLD" "$C_OFF"
  for _l in l0 l1 l2 l3 l4 l5; do
    if layer_on "$_l"; then printf '%s ' "$_l"; else printf '%s-%s ' "$C_DIM" "$C_OFF"; fi
  done
  printf '\n'

  printf '\n  %sSeparations%s\n' "$C_BOLD" "$C_OFF"
  _sep_line "git != dev"      "$ANS_GIT_ADDR"    "$ANS_DEV_ADDR" "$(layer_on l4 && echo on || echo off)"
  _sep_line "targets != dev"  "$ANS_TARGET_ADDR" "$ANS_DEV_ADDR" "$(layer_on l5 && echo on || echo off)"
  if layer_on l3; then
    if [ -z "$ANS_AUTHOR_MODEL" ]; then
      printf '  %-18s %sunchecked%s (author model not declared)\n' "reviewer != author" "$C_WARN" "$C_OFF"
    else
      printf '  %-18s %s vs %s\n' "reviewer != author" "$ANS_REVIEWER_MODEL" "$ANS_AUTHOR_MODEL"
    fi
  else
    printf '  %-18s %sn/a%s (L3 disabled)\n' "reviewer != author" "$C_DIM" "$C_OFF"
  fi
}

_sep_line() {
  _label="$1"; _a="$2"; _b="$3"; _active="$4"
  if [ "$_active" != "on" ]; then
    printf '  %-18s %sn/a%s (layer disabled)\n' "$_label" "$C_DIM" "$C_OFF"
  elif [ -z "$_a" ]; then
    printf '  %-18s %sunset%s\n' "$_label" "$C_WARN" "$C_OFF"
  elif [ "$_a" = "$_b" ]; then
    printf '  %-18s %sCOLLAPSED%s — both are %s\n' "$_label" "$C_ERR" "$C_OFF" "$_a"
  else
    printf '  %-18s %s vs %s\n' "$_label" "$_a" "$_b"
  fi
}
