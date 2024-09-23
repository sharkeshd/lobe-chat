## Base image for all the stages
FROM node:20-slim AS base

ARG USE_CN_MIRROR
ENV DEBIAN_FRONTEND="noninteractive"

RUN set -ex; \
    if [ "${USE_CN_MIRROR:-false}" = "true" ]; then \
        sed -i "s/deb.debian.org/mirrors.ustc.edu.cn/g" "/etc/apt/sources.list.d/debian.sources"; \
    fi; \
    apt update && \
    apt install --no-install-recommends -y busybox proxychains-ng && \
    apt full-upgrade -y && \
    apt autoremove -y --purge && \
    apt clean && \
    busybox --install -s && \
    addgroup --system --gid 1001 nodejs && \
    adduser --system --home "/app" --gid 1001 --uid 1001 nextjs && \
    chown -R nextjs:nodejs "/etc/proxychains4.conf" && \
    rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*

## Builder image, install all the dependencies and build the app
FROM base AS builder

ARG USE_CN_MIRROR
ENV NODE_OPTIONS="--max-old-space-size=8192" \
    NEXT_PUBLIC_BASE_PATH="" \
    NEXT_PUBLIC_SENTRY_DSN="" \
    SENTRY_ORG="" \
    SENTRY_PROJECT="" \
    NEXT_PUBLIC_ANALYTICS_POSTHOG="" \
    NEXT_PUBLIC_POSTHOG_HOST="" \
    NEXT_PUBLIC_POSTHOG_KEY="" \
    NEXT_PUBLIC_ANALYTICS_UMAMI="" \
    NEXT_PUBLIC_UMAMI_SCRIPT_URL="" \
    NEXT_PUBLIC_UMAMI_WEBSITE_ID=""

WORKDIR /app

COPY package.json ./
COPY .npmrc ./

RUN set -ex; \
    if [ "${USE_CN_MIRROR:-false}" = "true" ]; then \
        npm config set registry "https://registry.npmmirror.com/"; \
    fi; \
    corepack enable && \
    corepack use pnpm && \
    pnpm install && \
    mkdir -p /deps && \
    pnpm add sharp --prefix /deps

COPY . .

RUN npm run build:docker

## Application image, copy all the files for production
FROM scratch AS app

COPY --from=builder /app/public /app/public
COPY --from=builder /app/.next/standalone /app/
COPY --from=builder /app/.next/static /app/.next/static
COPY --from=builder /deps/node_modules/.pnpm /app/node_modules/.pnpm

## Production image, copy all the files and run next
FROM base

COPY --from=app --chown=nextjs:nodejs /app /app

ENV NODE_ENV="production" \
    HOSTNAME="0.0.0.0" \
    PORT="3210" \
    ACCESS_CODE="" \
    API_KEY_SELECT_MODE="" \
    DEFAULT_AGENT_CONFIG="" \
    SYSTEM_AGENT="" \
    FEATURE_FLAGS="" \
    PROXY_URL=""

USER nextjs

EXPOSE 3210/tcp

CMD ["/bin/sh", "-c", "if [ -n \"$PROXY_URL\" ]; then \
    IP_REGEX='^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}$'; \
    PROXYCHAINS='proxychains -q'; \
    host_with_port=\"${PROXY_URL#*//}\"; \
    host=\"\${host_with_port%%:*}\"; \
    port=\"\${PROXY_URL##*:}\"; \
    protocol=\"\${PROXY_URL%%://*}\"; \
    if ! [[ \"\$host\" =~ \$IP_REGEX ]]; then \
        nslookup=\$(nslookup -q=\"A\" \"\$host\" | tail -n +3 | grep 'Address:'); \
        if [ -n \"\$nslookup\" ]; then \
            host=\$(echo \"\$nslookup\" | tail -n 1 | awk '{print \$2}'); \
        fi; \
    fi; \
    printf \"%s\\n\" \
        'localnet 127.0.0.0/255.0.0.0' \
        'localnet ::1/128' \
        'proxy_dns' \
        'remote_dns_subnet 224' \
        'strict_chain' \
        'tcp_connect_time_out 8000' \
        'tcp_read_time_out 15000' \
        '[ProxyList]' \
        \"\$protocol \$host \$port\" > \"/etc/proxychains4.conf\"; \
    fi; \
    ${PROXYCHAINS} node \"/app/server.js\";"]
