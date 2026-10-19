# Self-hosted GitHub Actions runner in Docker

One container that runs self-hosted GitHub Actions runners (version **2.338.0**) for **all private repositories** of a GitHub account.

A personal GitHub account has no account-wide runners: a runner can only be registered against a single repository. So the container discovers every repository of `GITHUB_OWNER` that the token can administer and keeps one runner process alive for each. New repositories are picked up automatically (every `REFRESH_INTERVAL` seconds), and runners for repositories that disappear are stopped.

Runners are **ephemeral** by default: each runner takes one job, deregisters, and registers again, so every job starts clean.

Jump to: [token](#1-create-the-access-token-minimum-privileges) · [configure](#2-configure) · [start](#3-start) · [**Mac setup with `/opt/github_runner_work`**](#running-on-a-mac-docker-desktop-with-optgithub_runner_work) · [**Linux setup**](#running-on-linux) · [settings](#settings) · [security](#security) · [troubleshooting](#troubleshooting)

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 24.04 + runner 2.338.0 (checksum verified) + Docker CLI |
| `entrypoint.sh` | Supervisor: finds repositories, starts, restarts and stops one runner per repository, gets access to the Docker socket |
| `runner.sh` | Registers and runs a single repository runner, deregisters on stop |
| `docker-compose.yml` | The service definition |
| `.env.example` | Template for your settings and token |

## 1. Create the access token (minimum privileges)

The container needs a token to list your repositories and to request runner registration tokens. Use a **fine-grained personal access token** with a single permission.

1. On GitHub, click your profile picture, then **Settings**.
2. Scroll down and open **Developer settings**, then **Personal access tokens**, then **Fine-grained tokens**.
3. Click **Generate new token**.
4. Fill in the form:
   - **Token name:** `github-runner-docker`
   - **Expiration:** 90 days or less. The runners stop registering when the token expires, so put a reminder in your calendar to replace it.
   - **Resource owner:** your own account (`kuddusic`).
   - **Repository access:**
     - **All repositories** if you want new repositories to be picked up automatically (the default for this setup), or
     - **Only select repositories** and pick the ones you want. Repositories created later are not covered until you add them to the token.
   - **Permissions** > **Repository permissions** > **Administration: Read and write**.
     Leave everything else on "No access". Do not add any account permissions. "Metadata: Read-only" is added automatically and is expected.
5. Click **Generate token** and copy it right away. GitHub shows it only once.

Why **Administration**? GitHub's API requires the repository "Administration" permission (write) to create runner registration and remove tokens. There is no narrower permission for personal repositories. Administration is powerful (it can change repository settings and delete the repository), so:

- keep the token short-lived and limited to the repositories you need,
- keep it only in `.env` (`chmod 600 .env`) and never commit it,
- treat every workflow in these repositories as trusted code (see Security).

Avoid a classic token: its `repo` scope grants far more access than this setup needs.

## 2. Configure

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env`:

- `GITHUB_OWNER`: your GitHub account name (already `kuddusic` in the template).
- `GITHUB_PAT`: the token from step 1.
- `RUNNER_WORK_ROOT`: a host directory for job workspaces, `/opt/github_runner_work` by default. It is mounted at the same path inside the container so jobs that use Docker can bind-mount their workspace. On a Mac, create and share it first (see the Mac section below).

Keep comments in `.env` on their own lines, not after a value.

## 3. Start

```bash
docker compose up -d --build
docker compose logs -f
```

The log shows the repositories that were found, one line per runner start, and runner output prefixed with the repository name, for example `[my-repo] Listening for Jobs`.

Check **Settings > Actions > Runners** in any of your repositories: a runner named `gh-<container id>` should show as **Idle**.

## 4. Use it in workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - uses: actions/checkout@v4
      - run: docker version
```

The runner also carries the `docker` label. Change the labels with `RUNNER_LABELS` in `.env`.

## Running on a Mac (Docker Desktop) with `/opt/github_runner_work`

This runs the same Linux image on a Mac with Docker Desktop (Apple Silicon or Intel; the image builds for your CPU). Job workspaces live in `/opt/github_runner_work` on the Mac.

### A. Prepare the work folder

In Terminal:

```bash
sudo mkdir -p /opt/github_runner_work
sudo chown "$USER":staff /opt/github_runner_work
```

### B. Share the folder with Docker Desktop

Docker Desktop only shares `/Users`, `/Volumes`, `/private`, `/tmp` and `/var/folders` by default, so `/opt/github_runner_work` must be added or the containers cannot use it.

1. Open Docker Desktop and go to **Settings > Resources > File sharing** (the list may be called "Virtual file shares").
2. Add `/opt/github_runner_work`.
3. Click **Apply** (Docker Desktop restarts).

### C. Point the setup at the folder

Go to the folder that holds these files, create `.env` if you have not yet (step 2), and set the work folder:

```bash
cd /path/to/this/folder
sed -i '' 's|^RUNNER_WORK_ROOT=.*|RUNNER_WORK_ROOT=/opt/github_runner_work|' .env
grep '^RUNNER_WORK_ROOT' .env
```

(`sed -i ''` is the macOS form; on Linux use `sed -i`.) A leftover `DOCKER_GID` line in `.env` is no longer used and can be deleted: the container finds the Docker socket's group by itself.

### D. Start and verify

```bash
docker compose up -d --build
docker compose logs -f                                       # look for "repositories: ..." and "Listening for Jobs"
docker compose exec runner docker ps                         # the Docker socket works inside the container
docker compose exec runner ls -ld /opt/github_runner_work    # the shared folder is mounted
```

Then run a test job. Add this workflow to one of your repositories (`.github/workflows/runner-test.yml`), and start it from **Actions > runner-test > Run workflow**:

```yaml
name: runner-test
on: workflow_dispatch
jobs:
  test:
    runs-on: [self-hosted, linux, homelab]
    steps:
      - uses: actions/checkout@v4
      - run: |
          uname -m
          docker version --format '{{.Server.Version}}'
          pwd
          docker run --rm -v "$PWD:/w" alpine ls /w
```

The last line proves that jobs can bind-mount their workspace. It should list the files of your repository. While a job runs you can also see its workspace on the Mac under `/opt/github_runner_work/<repository>-gh-<container id>`.

### E. Keep it running

- Docker Desktop has to be running. Turn on **Settings > General > Start Docker Desktop when you sign in**. The container has `restart: unless-stopped`, so it comes back by itself when Docker starts.
- While the Mac sleeps, is offline, or Docker Desktop is closed, the runners are offline and jobs wait in the queue. To keep the Mac awake while it is on power, change the sleep options in the macOS Energy or Battery settings, or run `caffeinate -s` in a terminal.
- Docker Desktop's CPU and memory limit (**Settings > Resources**) applies to all jobs together.

### Mac notes

- Jobs run in **Linux** (`runs-on: [self-hosted, linux, ...]`). Builds that need macOS itself (Xcode, signing) need a native macOS runner, not this container.
- On Apple Silicon the runner is arm64. Docker images that exist only for amd64 need `--platform linux/amd64` and run emulated and slower.
- The work folders for stopped runners can remain as empty folders under `/opt/github_runner_work`. Run `docker compose down` first, then you can delete them.

## Running on Linux

Works on any Linux host with Docker Engine and the Compose plugin (x86_64 or arm64). Unlike on a Mac, there is no VM and no file-sharing step: the work folder is a plain host directory.

### A. Install Docker

Follow https://docs.docker.com/engine/install/ for your distribution, then check:

```bash
docker --version
docker compose version
```

### B. Prepare the work folder

```bash
sudo mkdir -p /opt/github_runner_work
sudo chown "$USER": /opt/github_runner_work
```

The runner user inside the container needs to write here. If you see `Work folder ... is not writable`, find the container user's id with `docker compose run --rm --entrypoint id runner` and `sudo chown` the folder to that uid (or, as a last resort, `chmod 777` it).

### C. Configure and start

```bash
cp .env.example .env
chmod 600 .env
sed -i 's|^RUNNER_WORK_ROOT=.*|RUNNER_WORK_ROOT=/opt/github_runner_work|' .env   # edit GITHUB_PAT and GITHUB_OWNER too
docker compose up -d --build
docker compose logs -f
```

Verify with the same checks as in the Mac section, step D (`docker compose exec runner docker ps`, and the `runner-test` workflow).

### D. Keep it running

- Enable Docker at boot: `sudo systemctl enable --now docker`. The container has `restart: unless-stopped`, so it comes back by itself.
- If you use SELinux (Fedora, RHEL), the bind mounts may be blocked. Label the work folder with `sudo chcon -Rt container_file_t /opt/github_runner_work`, and expect the Docker socket to need `security_opt: [label=disable]` on the service.
- Rootless Docker or Podman: the socket is not `/var/run/docker.sock`. Change the host side of the socket line under `volumes:` in `docker-compose.yml` (for rootless Docker: `${XDG_RUNTIME_DIR}/docker.sock:/var/run/docker.sock`).

### Linux notes

- The Docker socket's group is detected automatically, so no `DOCKER_GID` setting is needed.
- Jobs run natively (no emulation) on the host's CPU type.
- Security: the socket gives jobs root-equivalent access to the host itself, not to a VM. Prefer a dedicated VM or machine (see Security).

## Settings

All settings go in `.env`.

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_OWNER` | required | Account or organization whose repositories get runners |
| `GITHUB_PAT` | required | The token from step 1 |
| `RUNNER_WORK_ROOT` | `/opt/github_runner_work` | Host directory for job workspaces, mounted at the same path in the container |
| `RUNNER_LABELS` | `homelab,docker` | Extra runner labels (`self-hosted`, `Linux` and the CPU type are always added) |
| `REPO_INCLUDE` | empty | Comma-separated repository names. When set, only these get runners |
| `REPO_EXCLUDE` | empty | Comma-separated repository names to skip |
| `INCLUDE_PUBLIC` | `false` | Also create runners for public repositories (not recommended) |
| `INCLUDE_FORKS` | `false` | Also create runners for forks |
| `REFRESH_INTERVAL` | `300` | Seconds between repository discovery runs |
| `EPHEMERAL` | `true` | One job per runner, then re-register. `false` keeps a long-lived runner |
| `DISABLE_UPDATE` | `false` | Stop the runner from updating itself |

Only repositories that are owned by `GITHUB_OWNER`, where the token has admin rights, are considered. Archived repositories are always skipped.

## Operations

| Task | Command |
|---|---|
| Show status | `docker compose ps` |
| Follow logs | `docker compose logs -f` |
| Stop and deregister all runners | `docker compose down` (allow up to a minute) |
| Run two jobs at once per repository | `docker compose up -d --scale runner=2` |
| Change a setting | Edit `.env`, then `docker compose up -d` |
| Update the runner version | Change `RUNNER_VERSION` in `docker-compose.yml` and both `RUNNER_SHA256_*` values in the `Dockerfile` (listed on the release page at `https://github.com/actions/runner/releases/tag/v<version>`), then `docker compose up -d --build` |

By default each runner takes one job at a time, so each repository can run one job at once. Every extra container adds one more.

The runner updates itself when GitHub requires a newer version. Set `DISABLE_UPDATE=true` to prevent that, but then you must bump the version yourself.

The image contains Docker, git and jq only. Install other tools (Node, Terraform, ...) in a workflow step, or add them to the `Dockerfile`.

## Security

- The container mounts `/var/run/docker.sock`. Jobs can therefore control Docker on the host (on a Mac: inside the Docker Desktop VM), which is effectively root there.
- Jobs run in the same container as the token, and with the Docker socket they can read it. A workflow in any of your repositories can use the token.
- Use this only for **private repositories whose workflows you control**. Never enable it for public repositories: a pull request from a fork could run arbitrary code on your machine.
- On a home network, run it on a VM or an isolated VLAN.
- If you outgrow this, a free GitHub organization gives you one real shared runner, and only a short-lived registration token is needed instead of an Administration token.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `bash: /entrypoint.sh: Permission denied` in `docker compose logs`, container keeps restarting | The script was copied into the image without read permission (the files on the host have owner-only mode 600). The `Dockerfile` now sets `chmod 0755` on the scripts. Rebuild: `docker compose build --no-cache && docker compose up -d` |
| `Repository discovery failed` and the container keeps restarting | The token is wrong, expired, or `GITHUB_OWNER` is misspelled. Create a new token (step 1) |
| `no repositories match` | The token does not include those repositories, none of them is private, or `REPO_INCLUDE` / `REPO_EXCLUDE` filter them all out |
| `Could not get a registration token` for one repository | The token lacks **Administration: Read and write** on that repository |
| A new repository has no runner yet | It is picked up within `REFRESH_INTERVAL` seconds. With "Only select repositories" you must add it to the token |
| `Work folder ... is not writable`, or Docker says the path is not shared (Mac) | Share `/opt/github_runner_work` with Docker Desktop (Mac section, step B) and restart the stack |
| A job's `docker run -v "$PWD:..."` shows an empty folder (Mac) | The work folder is not shared with Docker Desktop (Mac section, step B) |
| `permission denied` on the Docker socket inside a job | Look for `no write access` in `docker compose logs`, and check `docker compose exec runner ls -l /var/run/docker.sock`. The container joins the socket's group at start, which fails only if the socket is not group-writable |
| Offline runners left in a repository's runner list | Remove them under **Settings > Actions > Runners** |
