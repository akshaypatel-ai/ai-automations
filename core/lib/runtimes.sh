#!/usr/bin/env bash
# Runtime selection for installers. Source after wizard.sh.
#
#   choose_runtime <core/runtimes dir> [default-name]
#
# Asks the user where the agent should RUN (the recipe files are identical;
# only the trigger wiring, secret store, and CI file differ), and sets:
#   RUNTIME_NAME  runtime identifier (github-actions | docker-server |
#                 gitlab-ci | bitbucket)
#
# The other helpers keep the per-recipe installers runtime-thin:
#   runtime_render_ci  copies the runtime's example CI file into the agent dir
#                      (gitlab-ci / bitbucket only) with AGENT_DIR pre-set
#   runtime_overlay    prints the runtime's differences AFTER the recipe's
#                      standard (GitHub Actions) next-steps

choose_runtime() {
  local dir="$1" default="${2:-github-actions}"
  local all="github-actions docker-server gitlab-ci bitbucket"
  local names=() name blurb i=1 pick suffix
  say "Runtime"
  for name in $all; do
    [[ -d "$dir/$name" ]] || continue
    case "$name" in
      github-actions) blurb="zero infra — every recipe ships its workflow pre-rendered" ;;
      docker-server)  blurb="your own box — flat cost, no CI minutes, Ollama-ready" ;;
      gitlab-ci)      blurb="GitLab-hosted repos — per-item via the relay, or relay-less reconcile" ;;
      bitbucket)      blurb="Bitbucket-hosted repos — v1 limits: no PR/issue write-back yet" ;;
    esac
    names+=("$name")
    suffix=""
    [[ "$name" == "$default" ]] && suffix="  (default)"
    note "  $i) $name$suffix — $blurb"
    i=$((i + 1))
  done
  ask pick "Runtime (number or name)" "$default"
  RUNTIME_NAME=""
  for i in "${!names[@]}"; do
    if [[ "$pick" == "${names[$i]}" || "$pick" == "$((i + 1))" ]]; then
      RUNTIME_NAME="${names[$i]}"
      break
    fi
  done
  [[ -n "$RUNTIME_NAME" ]] || { echo "error: unknown runtime '$pick'" >&2; return 1; }
}

# runtime_render_ci <runtime> <core/runtimes dir> <agent dir (abs)> <agent dir (rel)>
# For the CI-file runtimes, copies the runtime's example pipeline into the
# agent dir with AGENT_DIR substituted to the real install path. No-op for
# github-actions (workflow ships pre-rendered) and docker-server (no CI file).
runtime_render_ci() {
  local runtime="$1" dir="$2" agent_abs="$3" agent_rel="$4" src out
  case "$runtime" in
    gitlab-ci) out="gitlab-ci.example.yml" ;;
    bitbucket) out="bitbucket-pipelines.example.yml" ;;
    *) return 0 ;;
  esac
  src="$dir/$runtime/$out"
  mkdir -p "$agent_abs"
  sed "s#scripts/clickup-agent#$agent_rel#" "$src" > "$agent_abs/$out"
  echo "  + $agent_rel/$out  (core/runtimes/$runtime — AGENT_DIR pre-set)"
}

# runtime_overlay <runtime> <agent dir (rel)> <worker name> <brain auth vars> <tool secret names>
# Printed AFTER the recipe's standard next-steps heredoc. No-op for
# github-actions; otherwise a clearly-headed block with only the DIFFERENCES
# from the numbered GitHub Actions steps above it.
runtime_overlay() {
  local runtime="$1" agent_rel="$2" worker="$3" auth_vars="$4" tool_secrets="$5"
  local agent_base="${agent_rel##*/}"
  case "$runtime" in
    docker-server)
      cat <<EOF

── Runtime overlay: docker-server (differences from the numbered steps above)

SKIP the GitHub-secrets step and the Actions repo-settings step — secrets
live in the server's .env, not on GitHub:

  a. Copy core/runtimes/docker-server (from the ai-automations repo) to your
     box, then: cp env.example .env
  b. Fill .env with GITHUB_REPO + GITHUB_PAT (contents: read+write), plus:
       $auth_vars $tool_secrets
     and the relay verification secret(s) from the webhook step above — the
     same values the steps put into 'wrangler secret put'.
  c. docker compose up -d --build   (TLS in front — Caddy or a CF Tunnel)

The relay-deploy step becomes OPTIONAL: the receiver runs the same relay
worker ($worker) in-process. Point the tool's webhook at
    https://<your-host>/$agent_base/hook[...]
instead of the Worker URL. Everything else — the webhook creation clicks,
committing the files, the DRY_RUN local test — is unchanged.

Details: core/runtimes/docker-server/README.md
EOF
      ;;
    gitlab-ci)
      cat <<EOF

── Runtime overlay: gitlab-ci (differences from the numbered steps above)

Your target repo must be GitLab-hosted (same file layout, GitLab remote).
SKIP the GitHub-secrets step and the Actions repo-settings step. Instead:

  a. A rendered $agent_rel/gitlab-ci.example.yml was written above —
     merge its jobs into your repo's .gitlab-ci.yml (AGENT_DIR is pre-set).
  b. Settings → CI/CD → Variables (masked):
       $tool_secrets $auth_vars
  c. The relay STAYS on Cloudflare — deploy it as in the steps above, then
     retarget its dispatch in $agent_rel/relay/wrangler.toml [vars]:
       DISPATCH_KIND = "gitlab"
       GITLAB_TRIGGER_URL = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/trigger/pipeline"
     and: wrangler secret put GITLAB_TRIGGER_TOKEN
       (Settings → CI/CD → Pipeline trigger tokens)
     Or go relay-less: point the tool's webhook straight at the
     trigger-token URL for reconcile-mode granularity (no relay at all).
  d. implement/escalation write-back goes through the gh→glab shim —
     experimental; install per core/hosts/README.md and uncomment the PATH
     line in the rendered yml.

Details: core/runtimes/gitlab-ci/README.md
EOF
      ;;
    bitbucket)
      cat <<EOF

── Runtime overlay: bitbucket (differences from the numbered steps above)

Your target repo must be Bitbucket-hosted (same file layout, Bitbucket
remote). SKIP the GitHub-secrets step and the Actions repo-settings step.
Instead:

  a. A rendered $agent_rel/bitbucket-pipelines.example.yml was written
     above — copy it into your repo's bitbucket-pipelines.yml (AGENT_DIR is
     pre-set) and enable Pipelines (Repository settings → Pipelines).
  b. Repository settings → Pipelines → Repository variables (secured):
       $tool_secrets $auth_vars
  c. The relay STAYS on Cloudflare — deploy it as in the steps above, then
     retarget its dispatch in $agent_rel/relay/wrangler.toml [vars]:
       DISPATCH_KIND = "bitbucket"
       BITBUCKET_WORKSPACE = "<workspace>"
       BITBUCKET_REPO = "<repo-slug>"
     and: wrangler secret put BITBUCKET_TOKEN
       (repository access token, pipeline:write scope)
  d. Honest v1 limits: analyze/respond/triage-note flows only — no PR or
     issue write-back on Bitbucket yet (implement/escalation await
     first-class host adapters).

Details: core/runtimes/bitbucket/README.md
EOF
      ;;
    *) return 0 ;;
  esac
}
