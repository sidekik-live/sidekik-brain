# syntax=docker/dockerfile:1
# @sidekik/contracts comes from a private GitHub repo, so the install needs a read-only token:
#   docker build --build-arg NPM_GITHUB_TOKEN=... .                     (Railway build variable)
# The token is only used by the install step of the build stage; the runtime image never contains it.
FROM node:22-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare pnpm@10.34.6 --activate
COPY package.json pnpm-lock.yaml ./
ARG NPM_GITHUB_TOKEN
# Railway's builder has no BuildKit secret mounts; the token (if any) comes in as a build variable.
RUN \
    TOKEN="$(cat /run/secrets/NPM_GITHUB_TOKEN 2>/dev/null || printf '%s' "$NPM_GITHUB_TOKEN")"; \
    if [ -n "$TOKEN" ]; then \
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.https://x-access-token:${TOKEN}@github.com/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/"; \
    fi; \
    pnpm install --frozen-lockfile
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN pnpm build && pnpm prune --prod

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8082
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8082)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/src/main.js"]
