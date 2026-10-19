FROM ubuntu:24.04

# Runner version is pinned. If you change it, update the two SHA256 values too
# (they are listed on https://github.com/actions/runner/releases/tag/v<version>).
ARG RUNNER_VERSION=2.338.0
ARG RUNNER_SHA256_X64=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
ARG RUNNER_SHA256_ARM64=628b4a7258487b80c1d3c221095a7ded349f5ae0175fd3dfab708d07428f041b
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq sudo tini unzip \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI + buildx/compose plugins only (the daemon comes from the host socket)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# The runner refuses to run as root, so use a normal user
RUN useradd -m -s /bin/bash runner \
 && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner

WORKDIR /home/runner/actions-runner
RUN case "${TARGETARCH:-amd64}" in \
      amd64) ARCH=x64;   SHA="${RUNNER_SHA256_X64}" ;; \
      arm64) ARCH=arm64; SHA="${RUNNER_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz" \
 && echo "${SHA}  runner.tar.gz" | sha256sum -c - \
 && tar xzf runner.tar.gz \
 && rm runner.tar.gz \
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R runner:runner /home/runner

COPY entrypoint.sh runner.sh /
# Explicit mode: files saved with owner-only permissions (600) on the host must still be
# readable and executable by the non-root "runner" user.
RUN chmod 0755 /entrypoint.sh /runner.sh

USER runner
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
