# Copy this recipe into the target application repository and adapt its output.
# Requires --build-arg BASE_IMAGE=<published custom build base>.
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS build
WORKDIR /app
# Single-package example. See README for workspace/monorepo requirements.
COPY package.json pnpm-lock.yaml ./
ARG CACHE_SCOPE=app
RUN --mount=type=cache,id=${CACHE_SCOPE}-pnpm,target=/var/cache/pnpm,sharing=locked \
    pnpm install --frozen-lockfile --store-dir /var/cache/pnpm
COPY . .
RUN pnpm run build
# Build-only output. Add a runtime stage appropriate to the application.

CMD ["cat", "dist/result.txt"]
