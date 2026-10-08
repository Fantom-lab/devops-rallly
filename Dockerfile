FROM node:20-alpine AS base

FROM base AS deps
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app
COPY package.json yarn.lock ./
COPY apps/web/package.json ./apps/web/
COPY packages/ ./packages/
RUN yarn install --frozen-lockfile
FROM deps AS migrator
WORKDIR /app
COPY . .

ENV DATABASE_URL="postgresql://postgres:postgres@localhost:5432/postgres"

CMD ["yarn", "db:deploy"]

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/web/node_modules ./apps/web/node_modules
COPY . .

# Передаем корректные заглушки для валидации переменных при сборке
ENV NEXT_TELEMETRY_DISABLED 1
ENV DATABASE_URL="postgresql://postgres:postgres@localhost:5432/postgres"
ENV SECRET_PASSWORD="dummy_secret_password_for_build_123"
ENV SUPPORT_EMAIL="support@example.com"

RUN yarn build

FROM base AS runner
WORKDIR /app
RUN apk add --no-cache openssl libc6-compat
ENV NODE_ENV production
ENV NEXT_TELEMETRY_DISABLED 1

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

COPY --from=builder /app/apps/web/public ./apps/web/public
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/static ./apps/web/.next/static

USER nextjs
EXPOSE 3000
ENV PORT 3000
ENV HOSTNAME "0.0.0.0"

CMD ["node", "apps/web/server.js"]
