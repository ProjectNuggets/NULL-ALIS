# syntax=docker/dockerfile:1

# ── Stage 1: Build ────────────────────────────────────────────
FROM alpine:3.23 AS builder

RUN apk add --no-cache git zig musl-dev postgresql-dev

ARG TARGETARCH

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN case "${TARGETARCH}" in \
      amd64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dcpu=haswell ;; \
      arm64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac

# ── Stage 2: Config Prep ─────────────────────────────────────
FROM busybox:1.37 AS config

RUN mkdir -p /nullclaw-data/.nullalis /nullclaw-data/workspace

RUN cat > /nullclaw-data/.nullalis/config.json << 'EOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "together-ai/moonshotai/kimi-k2.5"
      }
    }
  },
  "models": {
    "providers": {
      "together-ai": {
        "api_key": "",
        "base_url": "https://api.together.xyz/v1"
      }
    }
  },
  "gateway": {
    "port": 3000,
    "host": "::",
    "allow_public_bind": true
  }
}
EOF

# Default runtime runs as non-root (uid/gid 65534).
# Keep writable ownership for HOME/workspace in safe mode.
RUN chown -R 65534:65534 /nullclaw-data

# ── Stage 3: Runtime Base (shared) ────────────────────────────
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

RUN apk add --no-cache \
      ca-certificates \
      curl \
      tzdata \
      postgresql-libs \
      poppler-utils \
      pandoc

COPY --from=builder /app/zig-out/bin/nullalis /usr/local/bin/nullalis
COPY --from=config /nullclaw-data /nullclaw-data

ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV HOME=/nullclaw-data
ENV NULLCLAW_GATEWAY_PORT=3000

WORKDIR /nullclaw-data
EXPOSE 3000
ENTRYPOINT ["nullalis"]
CMD ["gateway", "--port", "3000", "--host", "::"]

# Optional autonomous mode (explicit opt-in):
#   docker build --target release-root -t nullalis:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
