# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION=24.04
ARG ZIG_VERSION=0.17.1

FROM ubuntu:${UBUNTU_VERSION} AS build

ARG ZIG_VERSION
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    curl \
    git \
    libkrb5-dev \
    libssl-dev \
    libzstd-dev \
    make \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) zig_arch=x86_64 ;; \
      arm64) zig_arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt; \
    ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY . .

RUN if [ ! -f deps/mariadb-connector-c/CMakeLists.txt ]; then \
      git submodule update --init --recursive; \
    fi

RUN zig build -Doptimize=ReleaseFast

FROM ubuntu:${UBUNTU_VERSION} AS release

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgssapi-krb5-2 \
    libkrb5-3 \
    libssl3 \
    libzstd1 \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/zig-out/bin/thysql /usr/local/bin/thysql

ENTRYPOINT ["thysql"]
