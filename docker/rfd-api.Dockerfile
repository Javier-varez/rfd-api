# Image for the rfd-api service.
#
# Build from the repository root, which is the expected build context:
#   podman build -t rfd-api -f docker/rfd-api.Dockerfile .
#
# Neither config.toml nor mappers.toml are baked into the image. Mount them:
#   /etc/rfd-api/config.toml   first entry of the default config search path
#   /etc/rfd-api/mappers.toml  pointed at by `initial_mappers` in config.toml

ARG RUST_VERSION=1.97.1
ARG DEBIAN_RELEASE=trixie

FROM docker.io/library/rust:${RUST_VERSION}-${DEBIAN_RELEASE} AS builder

# libpq-dev is needed by pq-sys (diesel/postgres); cmake, clang and perl are
# needed by aws-lc-sys and ring.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        clang \
        cmake \
        libclang-dev \
        libpq-dev \
        perl \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/rfd

COPY . .

# The `local-dev` feature is deliberately not enabled: it exposes an
# unauthenticated POST /login/local endpoint. Do not build this image with
# --all-features.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/usr/src/rfd/target,sharing=locked \
    cargo build --release --locked --package rfd-api \
    && install -Dm755 target/release/rfd-api /out/rfd-api

FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 rfd

COPY --from=builder /out/rfd-api /usr/local/bin/rfd-api

USER rfd

# Running from /etc/rfd-api means a mappers file mounted alongside the config
# is also found by the bare `mappers.toml` lookup, in addition to the explicit
# `initial_mappers` path.
WORKDIR /etc/rfd-api

# Metadata only. The port actually bound comes from `server_port` in the
# mounted config, so keep the two in sync when publishing the port.
EXPOSE 8080

# The binary is subcommand shaped, so `podman run <image> validate` and
# `podman run <image> version` work as-is.
ENTRYPOINT ["/usr/local/bin/rfd-api"]
CMD ["start"]
