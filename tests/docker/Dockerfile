# Linux test environment for fast-worktree — the image `tests/check` builds so
# that CI and a local machine run byte-for-byte the same checks. Mirrors the
# dependency set in .github/workflows/ci.yml.
#
# The repo is bind-mounted at /work at run time (see tests/check), so editing a
# file and re-running needs no rebuild; only changes to this Dockerfile or the
# entrypoint force one.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# tmux: the isolated-socket integration tests (tests/shims/tmux execs the real
#   binary). fish: the completions parse test. shellcheck: ./tests/lint.
#   postgresql(+client): the DB suite runs real createdb/dropdb/psql. jq/sqlite3:
#   the usage pipeline. golang-go: the transcript parser build. git: the suite
#   builds throwaway repos.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash tmux fish git jq sqlite3 file \
      postgresql postgresql-client ca-certificates curl coreutils xz-utils \
    && rm -rf /var/lib/apt/lists/*

# shellcheck from the upstream release, NOT apt (Ubuntu ships an older 0.9.0
# that reports SC2015 infos a current shellcheck does not, so `./tests/lint`
# would fail here but pass on a developer's machine). Pin the version the repo
# lints clean under so the container and local `shellcheck` agree.
ENV SHELLCHECK_VERSION=0.11.0
RUN case "$(dpkg --print-architecture)" in \
      amd64) sc_arch=x86_64 ;; \
      arm64) sc_arch=aarch64 ;; \
      *) sc_arch="$(uname -m)" ;; \
    esac \
    && curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" -o /tmp/sc.tar.xz \
    && tar -C /tmp -xJf /tmp/sc.tar.xz \
    && mv "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/ \
    && rm -rf /tmp/sc.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}" \
    && shellcheck --version

# Go from the official tarball under /usr/local/go, NOT apt's golang-go (which
# lands in /usr/bin). Keeping the toolchain out of the base system PATH matches
# how CI runners and version managers expose it, so a test that hides Go with a
# stripped-down PATH (usage_parser.bats) behaves the same here as everywhere.
# GOTOOLCHAIN=local forbids fetching a different toolchain over the network.
ENV GO_VERSION=1.23.4
ENV PATH=/usr/local/go/bin:$PATH
ENV GOTOOLCHAIN=local
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz \
    && go version

# bats-core, same pinned tag as the workflow.
RUN git clone --depth 1 --branch v1.14.0 https://github.com/bats-core/bats-core.git /tmp/bats-core \
    && /tmp/bats-core/install.sh /usr/local \
    && rm -rf /tmp/bats-core \
    && bats --version

# Warm the Go build cache in an image layer. The parser tests build a tiny
# stand-in that imports only the standard library; without a warm cache each
# one cold-compiles stdlib (~2s locally, >15s on a slow CI runner — enough to
# trip BATS_TEST_TIMEOUT). tests/unit/usage_parser.bats pins GOCACHE to this
# same location (the root user's default), so the tests reuse this layer.
RUN go build std

COPY tests/docker/entrypoint.sh /usr/local/bin/fw-test-entrypoint
RUN chmod +x /usr/local/bin/fw-test-entrypoint

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/fw-test-entrypoint"]
# Default: exactly what CI runs. Override by passing args to `tests/check`.
CMD ["sh", "-c", "./tests/run && ./tests/lint"]
