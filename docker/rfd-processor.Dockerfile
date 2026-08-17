# Image for the rfd-processor worker.
#
# Build from the repository root, which is the expected build context:
#   podman build -t rfd-processor -f docker/rfd-processor.Dockerfile .
#
# config.toml is not baked into the image. Mount it at:
#   /etc/rfd-processor/config.toml   first entry of the default search path
#
# Beyond the Rust binary this image carries the PDF toolchain that the
# processor shells out to: `asciidoctor-pdf` and `mmdc` (which drives
# Chromium) for rendering, and `node` for the parse-rfd document parser.
# Toolchain versions are pinned by rfd-processor/Gemfile.lock and
# rfd-processor/package-lock.json.

ARG RUST_VERSION=1.97.1
ARG DEBIAN_RELEASE=trixie
ARG BUNDLER_VERSION=4.0.11

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

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/usr/src/rfd/target,sharing=locked \
    cargo build --release --locked --package rfd-processor \
    && install -Dm755 target/release/rfd-processor /out/rfd-processor

# Ruby gems and node modules for the PDF toolchain. This stage shares a base
# image with the runtime stage so the gems built here (under
# vendor/bundle/ruby/<abi>) match the runtime Ruby.
FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim AS toolchain

ARG BUNDLER_VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        nodejs \
        npm \
        ruby \
        ruby-dev \
    && rm -rf /var/lib/apt/lists/* \
    && gem install bundler --version "${BUNDLER_VERSION}" --no-document

WORKDIR /opt/rfd-processor

# Binstubs resolve the Gemfile relative to their own location
# (.bundle/bin/../../Gemfile), so this layout has to be preserved verbatim in
# the runtime stage.
COPY rfd-processor/Gemfile rfd-processor/Gemfile.lock ./
RUN bundle config set --local path vendor/bundle \
    && bundle config set --local bin .bundle/bin \
    && bundle install \
    && bundle binstubs asciidoctor asciidoctor-pdf

# Chromium comes from the distro rather than puppeteer's bundled download.
COPY rfd-processor/package.json rfd-processor/package-lock.json ./
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN npm ci --omit=dev

# asciidoctor-mermaid invokes a bare `mmdc`. Wrap it so Chromium runs without
# its sandbox (unavailable in an unprivileged container) and without relying on
# /dev/shm, which defaults to 64MB under podman and docker. Neither flag
# affects the rendered output.
RUN printf '%s\n' '{"args":["--no-sandbox","--disable-dev-shm-usage"]}' \
        > .bundle/bin/puppeteer.json \
    && printf '%s\n' \
        '#!/bin/sh' \
        'exec /opt/rfd-processor/node_modules/.bin/mmdc \' \
        '    --puppeteerConfigFile /opt/rfd-processor/.bundle/bin/puppeteer.json "$@"' \
        > .bundle/bin/mmdc \
    && chmod +x .bundle/bin/mmdc

FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim AS runtime

# ARGs do not cross stage boundaries, so this has to be redeclared.
ARG BUNDLER_VERSION

ENV DEBIAN_FRONTEND=noninteractive

# The generated binstubs `require "bundler/setup"`, and the lockfile pins
# BUNDLED WITH 4.0.11. Debian's ruby package only provides bundler 2.5.x as a
# default gem, which would send bundler looking for the pinned version at run
# time, so install it here too.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        fonts-dejavu-core \
        fonts-liberation \
        libpq5 \
        nodejs \
        ruby \
    && rm -rf /var/lib/apt/lists/* \
    && gem install bundler --version "${BUNDLER_VERSION}" --no-document \
    && useradd --system --create-home --uid 10001 rfd

COPY --from=toolchain /opt/rfd-processor /opt/rfd-processor
COPY --from=builder /out/rfd-processor /usr/local/bin/rfd-processor

# .bundle/bin supplies `asciidoctor-pdf` and the `mmdc` wrapper. HOME is set
# explicitly because USER does not reliably set it under podman, and Chromium
# fails to create its data directory without a writable home.
ENV PATH=/opt/rfd-processor/.bundle/bin:$PATH \
    HOME=/home/rfd \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1

USER rfd

WORKDIR /etc/rfd-processor

ENTRYPOINT ["/usr/local/bin/rfd-processor"]
CMD ["start"]
