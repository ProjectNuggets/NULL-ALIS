# syntax=docker/dockerfile:1

# ── Stage 1: Build ────────────────────────────────────────────
FROM alpine:3.23 AS builder

# S3.1 — pin Zig to the same version ci.yml + release.yml use via
# `.zigversion`. The Alpine `zig` package drifts with Alpine releases;
# downloading the official tarball at a pinned version eliminates the
# drift hazard and keeps the whole build pipeline on one Zig release.
RUN apk add --no-cache git musl-dev postgresql-dev curl xz tar

ARG TARGETARCH

WORKDIR /app
COPY .zigversion ./
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN ZIG_VERSION="$(cat .zigversion | tr -d '[:space:]')" && \
    case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL --retry 5 --retry-delay 3 --retry-max-time 120 \
         --connect-timeout 30 \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz && \
    mkdir -p /opt/zig && \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && \
    ln -s /opt/zig/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz && \
    zig version

RUN case "${TARGETARCH}" in \
      amd64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dchannels=cli,telegram -Dcpu=haswell ;; \
      arm64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dchannels=cli,telegram ;; \
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
      pandoc \
      # ── produce_document renderer chain (D63) ─────────────────
      # PDF: pandoc handles md→pdf via pdflatex/weasyprint fallback.
      # Pull in weasyprint for the wkhtmltopdf-free path and texlive
      # for pandoc's LaTeX engine.
      py3-pip \
      py3-cffi \
      py3-cairo \
      py3-brotli \
      py3-pillow \
      py3-tinycss2 \
      py3-cssselect2 \
      py3-pyphen \
      pango \
      harfbuzz \
      fontconfig \
      ttf-dejavu \
      # XLSX renderer: pandas + openpyxl via pip
      python3 \
      py3-numpy \
      # PPTX renderer: marp-cli via npm (Node.js)
      nodejs \
      npm \
      # Headless chromium needed by marp-cli for slide rendering
      chromium \
      nss \
      freetype \
      ttf-freefont

COPY --from=builder /app/zig-out/bin/nullalis /usr/local/bin/nullalis
COPY --from=config /nullclaw-data /nullclaw-data

# ── Renderer chain — pip + npm install (D63) ─────────────────
# Install renderer deps in a single layer. `--break-system-packages` is
# safe here: this is a single-purpose runtime image (PEP 668 protection
# is meant for shared OS pythons, not container singletons).
# Chromium path is exposed for marp-cli's --executablePath flag.
RUN pip3 install --no-cache-dir --break-system-packages \
        pandas \
        openpyxl \
        weasyprint && \
    npm install -g --omit=dev @marp-team/marp-cli && \
    # Cleanup npm cache to shrink layer
    npm cache clean --force && \
    # Verify the renderer chain is wired
    pandoc --version > /dev/null && \
    marp --version > /dev/null && \
    python3 -c "import pandas, openpyxl, weasyprint" && \
    echo "renderer chain ready"

ENV CHROME_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

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
