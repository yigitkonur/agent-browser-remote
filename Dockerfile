FROM node:24-slim

# OCI image metadata
LABEL org.opencontainers.image.source="https://github.com/yigitkonur/agent-browser-remote"
LABEL org.opencontainers.image.description="Multi-session agent-browser Docker service with HTTP API"
LABEL org.opencontainers.image.licenses="MIT"

# System dependencies for Chromium
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxrandr2 libgbm1 libasound2 libpangocairo-1.0-0 libgtk-3-0 \
    libx11-6 libxext6 libxfixes3 libxcb1 \
    fonts-liberation ca-certificates wget curl procps tini \
    && rm -rf /var/lib/apt/lists/*

# Install agent-browser globally
RUN npm install -g agent-browser@0.17.1

# Install Playwright Chromium into a predictable path
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npx playwright install --with-deps chromium

# Create non-root user and data directories
RUN groupadd -r ab && useradd -r -g ab -m ab \
    && mkdir -p /data/sockets /data/sessions \
    && chown -R ab:ab /data /opt/playwright-browsers

# Copy and install the API server (pre-built)
WORKDIR /app
COPY api-server/package.json api-server/package-lock.json ./
RUN npm ci --omit=dev
COPY api-server/dist/ ./dist/

# Give app ownership to non-root user
RUN chown -R ab:ab /app

USER ab

ENV NODE_ENV=production
ENV AGENT_BROWSER_SOCKET_DIR=/data/sockets
ENV AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage,--disable-setuid-sandbox,--disable-gpu"

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD wget -q --spider http://localhost:3000/health || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["node", "dist/server.js"]
