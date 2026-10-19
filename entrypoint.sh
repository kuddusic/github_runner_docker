#!/usr/bin/env bash
# Supervisor: finds every repository of GITHUB_OWNER that the token can administer and keeps
# one runner (runner.sh) alive for each. GitHub has no runner scope that spans all repositories
# of a personal account, so this is one runner process per repository, all inside this container.
set -Eeuo pipefail

# Docker socket access: join whichever group owns the socket (it differs between a Linux host and
# Docker Desktop for Mac), then re-run this script under that group. No GID setting needed.
SOCK="${DOCKER_SOCKET:-/var/run/docker.sock}"
if [[ -S "$SOCK" && ! -w "$SOCK" && -z "${DOCKER_GROUP_DONE:-}" ]]; then
  sock_gid="$(stat -c %g "$SOCK")"
  sock_group="$(getent group "$sock_gid" | cut -d: -f1 || true)"
  if [[ -z "$sock_group" ]]; then
    sock_group="dockersock"
    sudo groupadd -g "$sock_gid" "$sock_group"
  fi
  sudo usermod -aG "$sock_group" "$(id -un)"
  export DOCKER_GROUP_DONE=1
  exec sg "$sock_group" -c "exec bash '$0'"
fi
if [[ -S "$SOCK" && ! -w "$SOCK" ]]; then
  echo "[supervisor] warning: no write access to $SOCK, jobs that use Docker will fail" >&2
fi

: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${GITHUB_PAT:?GITHUB_PAT is required}"

REPO_INCLUDE="${REPO_INCLUDE:-}"              # comma-separated repo names; empty = all
REPO_EXCLUDE="${REPO_EXCLUDE:-}"              # comma-separated repo names to skip
INCLUDE_PUBLIC="${INCLUDE_PUBLIC:-false}"     # public repos are skipped unless "true"
INCLUDE_FORKS="${INCLUDE_FORKS:-false}"       # forks are skipped unless "true"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-300}"   # seconds between repository discovery runs
RESTART_GAP="${RESTART_GAP:-10}"              # minimum seconds between starts of one runner
TICK="${TICK:-5}"                             # seconds between supervisor checks
BASE_HOME="${BASE_HOME:-/home/runner/actions-runner}"
RUNNERS_ROOT="${RUNNERS_ROOT:-/home/runner/runners}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/runner.sh}"

declare -A RUNNER_PIDS=() STARTED=()
WANTED=""

log() { echo "[supervisor] $*"; }

# One page of repositories the token can see, as JSON
api_repos() { # $1 = page
  curl -fsS \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&per_page=100&page=$1"
}

# Names of repos owned by GITHUB_OWNER where the token has admin (needed to register runners)
discover_repos() {
  local page=1 chunk n out=""
  while :; do
    chunk="$(api_repos "$page")" || return 1
    jq -e 'type == "array"' >/dev/null <<<"$chunk" || return 1
    n="$(jq 'length' <<<"$chunk")"
    out+="$(jq -r --arg owner "$GITHUB_OWNER" --arg pub "$INCLUDE_PUBLIC" --arg forks "$INCLUDE_FORKS" '
      .[] | select((.owner.login | ascii_downcase) == ($owner | ascii_downcase)
                   and .permissions.admin == true
                   and .archived == false and .disabled == false
                   and ($pub == "true" or .private == true)
                   and ($forks == "true" or .fork == false))
      | .name' <<<"$chunk")"$'\n'
    if (( n < 100 )); then break; fi
    page=$((page + 1))
  done
  printf '%s' "$out" | sed '/^$/d' | sort -u
}

in_list() { # $1 = name, $2 = comma-separated list
  local item items=()
  IFS=',' read -ra items <<<"$2" || true
  for item in "${items[@]}"; do
    item="${item// /}"
    if [[ -n "$item" && "${item,,}" == "${1,,}" ]]; then return 0; fi
  done
  return 1
}

filter_repos() {
  local repo
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if [[ -n "$REPO_INCLUDE" ]] && ! in_list "$repo" "$REPO_INCLUDE"; then continue; fi
    if in_list "$repo" "$REPO_EXCLUDE"; then continue; fi
    echo "$repo"
  done
}

# Every runner gets its own copy of the runner install (hard links, so it costs almost no space)
prepare_dir() {
  local dir="$RUNNERS_ROOT/$1"
  if [[ ! -x "$dir/run.sh" ]]; then
    mkdir -p "$RUNNERS_ROOT"
    rm -rf "$dir"
    cp -al "$BASE_HOME" "$dir" 2>/dev/null || cp -a "$BASE_HOME" "$dir"
  fi
}

start_runner() {
  local repo=$1
  prepare_dir "$repo" || { log "could not prepare a runner directory for $repo"; return 0; }
  GITHUB_REPO="$repo" RUNNER_HOME="$RUNNERS_ROOT/$repo" \
    bash "$RUNNER_SCRIPT" > >(sed -u "s|^|[$repo] |") 2>&1 &
  RUNNER_PIDS[$repo]=$!
  STARTED[$repo]=$(date +%s)
  log "started runner for $repo"
}

stop_runner() {
  local pid="${RUNNER_PIDS[$1]:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  unset -v "RUNNER_PIDS[$1]"
}

reconcile() {
  local repo now pid
  now=$(date +%s)
  for repo in "${!RUNNER_PIDS[@]}"; do
    if ! grep -qxF "$repo" <<<"$WANTED"; then
      log "stopping runner for $repo (no longer in the list)"
      stop_runner "$repo"
    fi
  done
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    pid="${RUNNER_PIDS[$repo]:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
      unset -v "RUNNER_PIDS[$repo]"
    fi
    if (( now - ${STARTED[$repo]:-0} >= RESTART_GAP )); then start_runner "$repo"; fi
  done <<<"$WANTED"
}

shutdown() {
  trap - EXIT TERM INT
  log "stopping all runners"
  local repo
  for repo in "${!RUNNER_PIDS[@]}"; do
    kill -TERM "${RUNNER_PIDS[$repo]}" 2>/dev/null || true
  done
  wait || true
}

trap shutdown EXIT
trap 'exit 143' TERM INT

first=1
next_discovery=0
while :; do
  now=$(date +%s)
  if (( now >= next_discovery )); then
    if repos="$(discover_repos)"; then
      new="$(filter_repos <<<"$repos")"
      if (( first )) || [[ "$new" != "$WANTED" ]]; then
        WANTED="$new"
        if [[ -z "$WANTED" ]]; then
          log "no repositories match for ${GITHUB_OWNER}. Check the token's access, owner name and the include/exclude settings."
        else
          log "repositories: $(tr '\n' ' ' <<<"$WANTED")"
        fi
      fi
      first=0
    elif (( first )); then
      echo "Repository discovery failed. Check GITHUB_PAT and GITHUB_OWNER." >&2
      exit 1
    else
      log "repository discovery failed, keeping the previous list"
    fi
    next_discovery=$((now + REFRESH_INTERVAL))
  fi
  reconcile
  sleep "$TICK" & wait $!
done
