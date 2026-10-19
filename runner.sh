#!/usr/bin/env bash
# Registers ONE repo-scoped GitHub Actions runner (ephemeral by default) and runs it.
# Deregisters on stop. Started and restarted by entrypoint.sh, one instance per repository.
set -Eeuo pipefail

: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${GITHUB_PAT:?GITHUB_PAT is required}"

RUNNER_HOME="${RUNNER_HOME:-/home/runner/actions-runner}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-gh}-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-docker}"
EPHEMERAL="${EPHEMERAL:-true}"
DISABLE_UPDATE="${DISABLE_UPDATE:-false}"

# With RUNNER_WORK_ROOT set, the job workspace lives at <root>/<repo>-<runner name>.
# Mount the same path from the host so docker-based actions can bind-mount it.
if [[ -n "${RUNNER_WORK_ROOT:-}" ]]; then
  WORK_DIR="${RUNNER_WORK_ROOT%/}/${GITHUB_REPO}-${RUNNER_NAME}"
else
  WORK_DIR="_work"
fi

API="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"
REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
RUN_PID=""

github_token() { # $1 = registration-token | remove-token
  curl -fsS -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/$1" | jq -er .token
}

clean_workdir() {
  if [[ "$WORK_DIR" == /* ]]; then
    # sudo: job containers may leave root-owned files behind
    sudo find "$WORK_DIR" -mindepth 1 -delete 2>/dev/null || true
  fi
}

cleanup() {
  trap - EXIT TERM INT
  if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  if [[ -f .runner ]]; then
    echo "Deregistering runner ${RUNNER_NAME}"
    ./config.sh remove --token "$(github_token remove-token)" || true
  fi
  clean_workdir
}

cd "$RUNNER_HOME"
trap cleanup EXIT
trap 'exit 143' TERM INT

if [[ "$WORK_DIR" == /* ]]; then
  sudo mkdir -p "$WORK_DIR"
  # chown can be refused on a folder shared from a Mac; that is fine as long as it is writable
  sudo chown "$(id -u):$(id -g)" "$WORK_DIR" 2>/dev/null || true
  if ! touch "$WORK_DIR/.write-test" 2>/dev/null; then
    echo "Work folder ${WORK_DIR} is not writable. On a Mac, share its parent folder with Docker Desktop (see README)." >&2
    exit 1
  fi
  rm -f "$WORK_DIR/.write-test"
fi
clean_workdir

# A restarted runner still has the previous registration on disk
rm -f .runner .credentials .credentials_rsaparams

reg_token="$(github_token registration-token)" || {
  echo "Could not get a registration token. Check that GITHUB_PAT has Administration (read/write) on ${GITHUB_OWNER}/${GITHUB_REPO}." >&2
  exit 1
}

args=(--unattended --replace
      --url "$REPO_URL" --token "$reg_token"
      --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work "$WORK_DIR")
if [[ "$EPHEMERAL" == "true" ]]; then args+=(--ephemeral); fi
if [[ "$DISABLE_UPDATE" == "true" ]]; then args+=(--disableupdate); fi

./config.sh "${args[@]}"

./run.sh &
RUN_PID=$!
rc=0
wait "$RUN_PID" || rc=$?
exit "$rc"
