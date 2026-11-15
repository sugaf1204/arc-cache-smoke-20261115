# Copy this recipe into the target application repository and adapt its output.
# Requires --build-arg BASE_IMAGE=<published custom build base>.
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS build
WORKDIR /app
# Single-package example. See README for workspace/monorepo requirements.
COPY package.json pnpm-lock.yaml ./
# Repo ID is required; do not silently share a default store across repositories.
ARG CACHE_SCOPE
ARG TARGETPLATFORM
ARG CACHE_TOOLCHAIN=node24-bookworm-pnpm12
RUN --mount=type=cache,id=${CACHE_SCOPE}-${TARGETPLATFORM}-${CACHE_TOOLCHAIN},target=/var/cache/pnpm,sharing=locked \
    test -n "$CACHE_SCOPE" \
    && pnpm install --frozen-lockfile --store-dir /var/cache/pnpm
COPY . .
RUN pnpm run build
# Build-only output. Add a runtime stage appropriate to the application.

CMD ["cat", "dist/result.txt"]
