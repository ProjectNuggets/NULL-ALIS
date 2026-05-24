# nullalis Playwright MCP — production container image.
#
# Build:  docker build -t nullalis/playwright-mcp .
# Run:    docker run --rm -i nullalis/playwright-mcp
#
# stdin/stdout is the JSON-RPC channel. `-i` (interactive, no -t) keeps stdin
# open without allocating a TTY so the client speaks raw lines.
#
# We use Playwright's official image because installing the right Chromium
# system dependencies (fonts, X libs, etc.) on a vanilla base is a per-distro
# rabbit hole. The version is pinned to the playwright npm dep — bump together.

FROM mcr.microsoft.com/playwright:v1.49.0-jammy

WORKDIR /app

# Install only prod deps first for cache reuse.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

# Build artifacts.
COPY tsconfig.json ./
COPY src ./src
RUN npm install --no-save typescript@5.6.2 \
    && ./node_modules/.bin/tsc -p tsconfig.json \
    && npm prune --omit=dev

# Run as the unprivileged user that the base image provides for Chromium.
USER pwuser

ENV PLAYWRIGHT_HEADLESS=true \
    NODE_ENV=production

ENTRYPOINT ["node", "/app/dist/server.js"]
