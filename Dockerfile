# The single place for versions and checksums. linux/arm64 and linux/amd64 are pinned.
ARG BASE_IMAGE=debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
ARG RUST_IMAGE=rust:1.99.1-slim-trixie@sha256:9daf2b244ccc30523e55cafe32edf8465671ba567d0101620e5612ccb76ea1a7

FROM ${BASE_IMAGE} AS guard
RUN arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64 | amd64) ;; \
      *) echo "oas-glance-dev supports only arm64 and amd64, got: $arch" >&2; exit 1 ;; \
    esac; \
    touch /arch-ok

FROM ${BASE_IMAGE} AS fetch-base
COPY --from=guard /arch-ok /arch-ok
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/*

FROM fetch-base AS neovim
ARG NVIM_TAG=v0.12.6
ARG NVIM_SHA256_ARM64=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
ARG NVIM_SHA256_AMD64=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87
RUN case "$(dpkg --print-architecture)" in \
      arm64) asset=nvim-linux-arm64.tar.gz sha="$NVIM_SHA256_ARM64" ;; \
      amd64) asset=nvim-linux-x86_64.tar.gz sha="$NVIM_SHA256_AMD64" ;; \
      *) exit 1 ;; \
    esac \
    && curl -fsSLo /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/${NVIM_TAG}/${asset}" \
    && if [ "$NVIM_TAG" != "nightly" ]; then \
         echo "${sha}  /tmp/nvim.tar.gz" | sha256sum -c -; \
       fi \
    && mkdir -p /opt/nvim \
    && tar -xzf /tmp/nvim.tar.gz --strip-components=1 -C /opt/nvim

FROM fetch-base AS stylua
ARG STYLUA_SHA256_ARM64=8e67539e5fdf7a81cd03cf592b0df18d3bb96ee17a5ea5d9bf67b86387b903b0
ARG STYLUA_SHA256_AMD64=a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895
RUN case "$(dpkg --print-architecture)" in \
      arm64) asset=stylua-linux-aarch64.zip sha="$STYLUA_SHA256_ARM64" ;; \
      amd64) asset=stylua-linux-x86_64.zip sha="$STYLUA_SHA256_AMD64" ;; \
      *) exit 1 ;; \
    esac \
    && curl -fsSLo /tmp/stylua.zip \
      "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/${asset}" \
    && echo "${sha}  /tmp/stylua.zip" | sha256sum -c - \
    && mkdir -p /opt/stylua/bin \
    && unzip -q /tmp/stylua.zip -d /opt/stylua/bin \
    && chmod 0755 /opt/stylua/bin/stylua

FROM fetch-base AS luals
ARG LUALS_SHA256_ARM64=17b8e401a874440adeb649e5024c364f2bb9d15156c74a40e56d1ae9a1b2e4f2
ARG LUALS_SHA256_AMD64=93ad326b10f6c00911dd8c450fa098332dbd8f9f45d1052f5636a2d54479b947
RUN case "$(dpkg --print-architecture)" in \
      arm64) asset=lua-language-server-3.19.2-linux-arm64.tar.gz sha="$LUALS_SHA256_ARM64" ;; \
      amd64) asset=lua-language-server-3.19.2-linux-x64.tar.gz sha="$LUALS_SHA256_AMD64" ;; \
      *) exit 1 ;; \
    esac \
    && curl -fsSLo /tmp/luals.tar.gz \
      "https://github.com/LuaLS/lua-language-server/releases/download/3.19.2/${asset}" \
    && echo "${sha}  /tmp/luals.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/lua-language-server \
    && tar -xzf /tmp/luals.tar.gz -C /opt/lua-language-server

FROM fetch-base AS mini
ARG MINI_TEST_REV=35c67cb7f2dc697ed0c7c06400fcf29a8a521d7d
ARG MINI_DOC_REV=54bb11880f2208a059a8d2564c3f4b586b78e044
RUN fetch() { \
      mkdir -p "$1" && cd "$1" \
      && git init -q \
      && git fetch -q --depth 1 "$2" "$3" \
      && git checkout -q FETCH_HEAD \
      && actual="$(git rev-parse HEAD)" \
      && if [ "$actual" != "$3" ]; then \
           echo "pin mismatch for $2: $actual != $3" >&2; \
           return 1; \
         fi \
      && rm -rf .git; \
    }; \
    fetch /opt/mini/mini.test https://github.com/echasnovski/mini.test "$MINI_TEST_REV" \
    && fetch /opt/mini/mini.doc https://github.com/echasnovski/mini.doc "$MINI_DOC_REV"

FROM fetch-base AS tree-sitter-yaml
ARG TREE_SITTER_YAML_REV=7708026449bed86239b1cd5bce6e3c34dbca6415
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN fetch() { \
      mkdir -p "$1" && cd "$1" \
      && git init -q \
      && git fetch -q --depth 1 "$2" "$3" \
      && git checkout -q FETCH_HEAD \
      && actual="$(git rev-parse HEAD)" \
      && if [ "$actual" != "$3" ]; then \
           echo "pin mismatch for $2: $actual != $3" >&2; \
           return 1; \
         fi \
      && rm -rf .git; \
    }; \
    fetch /build/tree-sitter-yaml https://github.com/tree-sitter-grammars/tree-sitter-yaml "$TREE_SITTER_YAML_REV" \
    && mkdir -p /opt/tree-sitter-yaml/parser \
    && gcc -O2 -fPIC -shared -I src src/parser.c src/scanner.c -o /opt/tree-sitter-yaml/parser/yaml.so \
    && cp LICENSE /opt/tree-sitter-yaml/parser/LICENSE

FROM ${RUST_IMAGE} AS selene
COPY --from=guard /arch-ok /arch-ok
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install --locked --no-default-features --features selene-lib/luajit \
         --git https://github.com/Kampfkarren/selene \
         --rev 77986ebb6bd5ef9406b5dc5b6fb13cb972550833 \
         --root /opt/selene selene

FROM ${BASE_IMAGE}
COPY --from=neovim /opt/nvim /opt/nvim
COPY --from=stylua /opt/stylua /opt/stylua
COPY --from=luals /opt/lua-language-server /opt/lua-language-server
COPY --from=mini /opt/mini /opt/mini
COPY --from=tree-sitter-yaml /opt/tree-sitter-yaml /opt/tree-sitter-yaml
COPY --from=selene /opt/selene /opt/selene
ENV LANG=C.UTF-8 \
    VIMRUNTIME=/opt/nvim/share/nvim/runtime \
    PATH=/opt/nvim/bin:/opt/stylua/bin:/opt/lua-language-server/bin:/opt/selene/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
