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
      amd64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dchannels=cli,telegram,email,discord,slack,whatsapp -Dcpu=haswell ;; \
      arm64) zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres -Dchannels=cli,telegram,email,discord,slack,whatsapp ;; \
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
      # PDF: pandoc handles md→pdf via xelatex (branded) /
      # weasyprint (unbranded HTML fallback). Pull in texlive-xetex
      # explicitly — D63's original apk list omitted any LaTeX engine,
      # so produce_document's pandoc PDF path failed with
      # "pdflatex: not found" before this v1.14.22 hotfix.
      # texlive-xetex is ~150 MB; the full `texlive` meta-package is
      # ~3 GB which is not worth the size hit for a single rendering
      # engine.
      #
      # NOTE (v1.14.24, Gate #2 arm64 probe): texlive-xetex on
      # Alpine 3.23 does NOT bundle xcolor.sty, which pandoc's default
      # LaTeX template requires unconditionally. Without
      # `texmf-dist-latexrecommended` (the TeX Live "Recommended
      # LaTeX" collection, 38 MiB, supplies xcolor + ~50 standard
      # packages), the in-build probe `pandoc -o probe.pdf
      # --pdf-engine=xelatex` fails with `LaTeX Error: File
      # 'xcolor.sty' not found.` on BOTH amd64 and arm64. The probe
      # the v1.14.22 CR-03 hotfix added correctly caught this — but
      # the apk install line in the same hotfix was incomplete.
      # Verified fix: 38 MiB image-size cost, single-layer rebuild,
      # both architectures pass the probe.
      texlive-xetex \
      texmf-dist-latexrecommended \
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

# CR-04 (v1.14.22) — bundle Thmanyah brand assets into the runtime
# image. Without this COPY, resolveBundledFontsPath
# (src/tools/produce_document.zig) walks all exe-dir-relative
# candidates, finds none (the binary lives at /usr/local/bin/ — no
# assets/ sibling), and returns null. Every tenant rendered with system
# fonts (DejaVu), silently breaking the "SaaS deploy ships with
# Thmanyah branding ENABLED out of the box" v1.14.21 promise.
#
# Path: /usr/local/share/nullalis/branding/fonts/ is the canonical
# system-wide assets path on Alpine; resolveBundledFontsPath
# candidate "E" matches this exact location.
COPY assets/branding /usr/local/share/nullalis/branding

# Carry-forward package item A.2 (docs/superpowers/plans/CARRY-FORWARD-
# loadable-skills-and-skill-author.md) — ship repo-authored builtin skills
# (e.g. skills/spawn/) into the image at /opt/nullalis/skills/. This is
# NOT under /data: in staging/prod HOME=/data is a PVC mount, so anything
# baked here would be shadowed by the volume at runtime. The pod entrypoint
# is responsible for idempotently seeding this image path onto the PVC
# (`{HOME}/.nullalis/skills/skills/`, no-clobber) at boot — the doubled
# `skills/skills` is REAL: appendSkillsSection passes `~/.nullalis/skills`
# as the builtin_dir and listSkills appends `/skills` to whatever dir it
# is given, so that nested path is the only one the production loader
# scans. The seeding step lives in the deploy chart, not here; this COPY
# only makes the source available inside the image for that step to read.
COPY skills/ /opt/nullalis/skills/

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
    # ── CR-03 / CR-04 verification (v1.14.22) ───────────────────
    # Verify each renderer binary EXISTS *and* PRODUCES OUTPUT. Old
    # check (D63) only ran `--version`, which passes even when the
    # underlying LaTeX engine is missing. Now actually render a tiny
    # PDF — if texlive-xetex is missing, this fails the build.
    pandoc --version > /dev/null && \
    marp --version > /dev/null && \
    python3 -c "import pandas, openpyxl, weasyprint" && \
    echo '# hotfix probe' | pandoc -o /tmp/probe.pdf --pdf-engine=xelatex && \
    rm /tmp/probe.pdf && \
    # CR-04: confirm the brand-font bundle landed at the path
    # resolveBundledFontsPath expects.
    ls /usr/local/share/nullalis/branding/fonts/thmanyahsans/woff2/thmanyahsans-Regular.woff2 > /dev/null && \
    # v1.14.24 (Gate #2 arm64 follow-up): pre-build the fontconfig
    # cache as root so the non-root runtime user (uid 65534) doesn't
    # spam "Fontconfig error: No writable cache directories" on every
    # PDF/HTML render. Build-time cache is world-readable; runtime
    # reads succeed without needing per-user cache write access.
    fc-cache -f -v > /dev/null && \
    echo "renderer chain + branding ready"

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
