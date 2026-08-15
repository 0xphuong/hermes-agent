# syntax=docker/dockerfile:1.7
#
# Hermes Agent + the `claude` CLI + the claude_proxy service, in one image.
#
# Why one image instead of a sidecar container: hermes reaches the proxy at
# 127.0.0.1, so there is no second container to keep in sync, no hop across the
# bridge network, and no port published anywhere. The proxy has no auth of its
# own — loopback-inside-the-container is the only place it is safe to run
# without putting something authenticating in front of it.
#
# Build:
#   ./setup.sh --with-claude-code      # writes docker-compose.override.yml
#   docker compose up -d --build       # if you keep your own override
#
# Pin both moving parts in production:
#   docker compose build \
#     --build-arg HERMES_IMAGE_TAG=v1.2.3 \
#     --build-arg CLAUDE_PROXY_REF=<commit-sha>

# Declared before the first FROM so every stage can resolve it. setup.sh passes
# the same HERMES_IMAGE_TAG the compose `image:` line uses, so the built image
# and the pulled one never drift onto different bases.
ARG HERMES_IMAGE_TAG=latest

FROM nousresearch/hermes-agent:${HERMES_IMAGE_TAG} AS base

# ---------------------------------------------------------------------------
# Stage 1 — Claude Code CLI
#
# Built apart from the runtime purely so npm's working files stay out of the
# final image: only the install prefix is copied forward. The base image
# already ships Node.js 26 + npm, so this stage needs no extra toolchain.
# ---------------------------------------------------------------------------
FROM base AS claude-cli

USER root
ARG CLAUDE_CODE_VERSION=2.1.229
RUN npm install -g --prefix /opt/claude \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# ---------------------------------------------------------------------------
# Stage 2 — Runtime
# ---------------------------------------------------------------------------
FROM base

LABEL org.opencontainers.image.title="hermes-agent with claude-proxy" \
      org.opencontainers.image.description="Hermes Agent plus the Claude Code CLI and a supervised claude_proxy service" \
      org.opencontainers.image.source="https://github.com/0xphuong/hermes-agent" \
      org.opencontainers.image.base.name="docker.io/nousresearch/hermes-agent"

# Everything below needs root — and the image must STILL BE root at the end.
# s6-overlay's stage2 hook runs usermod/groupmod/chown before each service's
# run script drops to the hermes user with `s6-setuidgid`. A trailing
# `USER hermes` would break that hook, and PUID/PGID handling along with it.
# The upstream image ends as root for exactly this reason; do not "fix" it.
USER root

# Symlinked rather than added to PATH, so a change in how the base image builds
# its PATH cannot quietly make the binary unreachable.
COPY --from=claude-cli /opt/claude /opt/claude
RUN ln -sf /opt/claude/bin/claude /usr/local/bin/claude

# `claude -p` inherits the service's working directory, and it walks up from
# there looking for CLAUDE.md to fold into its system prompt. Give it an empty,
# writable directory of its own so that discovery finds nothing and the model
# sees the same context no matter where s6 happens to start the service.
RUN install -d -o hermes -g hermes -m 0755 /workspace

# s6 service wiring, ahead of the download because it changes far less often —
# a new server.py must not invalidate this layer.
#
# COPY merges into the existing tree: it adds s6-rc.d/claude-proxy/ and the
# empty s6-rc.d/user/contents.d/claude-proxy marker that enables it, leaving
# the dashboard and main-hermes services already there untouched. The chmod is
# belt-and-braces for checkouts that lose the executable bit (Windows, or a tar
# unpacked without modes) — s6 silently ignores a non-executable run script.
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/claude-proxy/run \
               /etc/s6-overlay/s6-rc.d/claude-proxy/finish

# The proxy itself, pulled from its own repo rather than vendored here — one
# copy, one place to edit. /opt/hermes is the immutable install tree, read-only
# to the runtime, which is where code belongs; mutable state stays on
# /opt/data. fastapi and uvicorn already ship in /opt/hermes/.venv, so there is
# nothing to install.
#
# The build needs network access to raw.githubusercontent.com. The default ref
# tracks main, so a rebuild can silently pick up new upstream code — pass a tag
# or commit for anything you care about, or add a checksum to fail loudly
# instead of drifting:
#   ADD --checksum=sha256:<digest> ...
ARG CLAUDE_PROXY_REPO=0xphuong/claude-cli-adapter
ARG CLAUDE_PROXY_REF=refs/heads/main
ADD https://raw.githubusercontent.com/${CLAUDE_PROXY_REPO}/${CLAUDE_PROXY_REF}/claude_proxy/server.py \
    /opt/hermes/claude_proxy/server.py

# Two separate chmods, both load-bearing:
#   * ADD from a URL writes the file 0600 root-owned — unreadable by the
#     hermes user the service runs as.
#   * A mode applied to the path as a whole also lands on the implicitly
#     created parent directory. Left at 0444 it becomes dr--r--r-- with no
#     execute bit, so hermes cannot traverse it. Root reads straight through,
#     so the build and any root shell look fine while the service dies with
#     `[Errno 13] Permission denied` on a file whose own mode looks readable.
RUN chmod 0755 /opt/hermes/claude_proxy \
 && chmod 0444 /opt/hermes/claude_proxy/server.py
