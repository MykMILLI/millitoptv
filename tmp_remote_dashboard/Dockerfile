FROM node:24-bookworm-slim AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY vite.config.mjs ./
COPY web ./web
COPY server ./server

RUN node --check server/web-app-routes.mjs && node --check server/migrate-web-apps.mjs && node --test server/web-app-routes.test.mjs && npm run check && npm run build
RUN node --check server/billing-routes.mjs && node --check server/verify-billing-schema.mjs && node --check server/configure-square-secret.mjs && node --test server/billing-routes.test.mjs
RUN node --check server/community-routes.mjs && node --check server/verify-community-schema.mjs && node --test server/community-routes.test.mjs
RUN node --check server/tmdb-discovery.mjs && node --test server/tmdb-discovery.test.mjs
RUN node --check server/profile-sync-routes.mjs && node --check server/verify-profile-sync-schema.mjs && node --test server/profile-sync.test.mjs
RUN node --check server/listening-session-routes.mjs && node --check server/verify-listening-session-schema.mjs && node --test server/listening-session-routes.test.mjs
RUN npm prune --omit=dev

FROM node:24-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends smbclient \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/server ./server
COPY --from=build /app/dist ./dist

EXPOSE 3000
CMD ["node", "server/index.mjs"]

# Millitop candidate runtime read permissions
RUN chmod -R a+rX /app
