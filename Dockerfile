# proto-benchmarks: every toolchain needed to build and run all harnesses.
#
#   docker build -t proto-benchmarks .
#   docker run --rm --cpuset-cpus=0-2 -v "$PWD/results:/bench/results" proto-benchmarks [run.sh options]
#
# All implementations are built at image build time (./run.sh --build-only), so running the
# container needs no network and starts benchmarking immediately.
FROM ubuntu:24.04 AS toolchain

ARG PROTOBUF_VERSION=36.2
ARG GO_VERSION=1.26.0
ARG NODE_VERSION=22.22.1
ARG ZIG_VERSION=0.16.0
ARG SWIFT_VERSION=6.2.4
ARG RUST_TOOLCHAIN=stable
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=C.UTF-8 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup \
    GOPATH=/go \
    PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/zig:/usr/local/node/bin:/usr/local/swift/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- system packages: C/C++ toolchain, Java 21 + Maven, Python, .NET 8, misc
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config autoconf automake libtool \
      git curl ca-certificates unzip zip xz-utils util-linux \
      python3 python3-venv python3-pip \
      openjdk-21-jdk-headless maven \
      dotnet-sdk-8.0 \
      binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev libpython3-dev \
      libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev tzdata zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- Swift (official Linux toolchain tarball)
RUN curl -fsSL -o /tmp/swift.tar.gz \
      "https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz" \
    && mkdir -p /usr/local/swift && tar -xzf /tmp/swift.tar.gz -C /usr/local/swift --strip-components=1 \
    && rm /tmp/swift.tar.gz && swift --version

# ---- optional: trust an extra CA (corporate TLS-inspecting proxies). Base64 of a PEM certificate.
#      docker build --build-arg EXTRA_CA_CERT_B64="$(base64 -w0 proxy-ca.pem)" ...
ARG EXTRA_CA_CERT_B64=""
RUN if [ -n "$EXTRA_CA_CERT_B64" ]; then \
      echo "$EXTRA_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/extra-ca.crt \
      && update-ca-certificates \
      && keytool -importcert -noprompt -trustcacerts -alias extra-ca -file /usr/local/share/ca-certificates/extra-ca.crt \
           -cacerts -storepass changeit; \
    fi
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt

# ---- protoc (release binary; same version as the C++/Java/Python/C# runtimes and zig-protobuf's CI)
RUN curl -fsSL -o /tmp/protoc.zip \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protoc-${PROTOBUF_VERSION}-linux-x86_64.zip" \
    && unzip -q -o /tmp/protoc.zip -d /usr/local && chmod +x /usr/local/bin/protoc && rm /tmp/protoc.zip \
    && protoc --version

# ---- libprotobuf (C++ runtime) built from source, installed to /usr/local
RUN curl -fsSL -o /tmp/protobuf.tar.gz \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-${PROTOBUF_VERSION}.tar.gz" \
    && mkdir -p /tmp/protobuf && tar -xzf /tmp/protobuf.tar.gz -C /tmp/protobuf --strip-components=1 \
    && cmake -S /tmp/protobuf -B /tmp/protobuf/build -G Ninja \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
         -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON -Dprotobuf_BUILD_SHARED_LIBS=OFF \
         -Dprotobuf_INSTALL=ON -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/protobuf/build --parallel "$(nproc)" \
    && cmake --install /tmp/protobuf/build \
    && rm -rf /tmp/protobuf /tmp/protobuf.tar.gz && ldconfig

# ---- protobuf-c (runtime + protoc-gen-c) from the distribution. protobuf-c's own protoc-gen-c
#      does not compile against libprotobuf >= 30 (removed descriptor APIs); the distro plugin works
#      with any protoc because the plugin protocol is stable, and the C runtime has no dependency.
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-c-compiler libprotobuf-c-dev \
    && rm -rf /var/lib/apt/lists/* && command -v protoc-gen-c && pkg-config --modversion libprotobuf-c

# ---- Rust
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" --no-modify-path \
    && rustc --version && cargo --version

# ---- Go
RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz && go version

# ---- Node.js
RUN curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && mkdir -p /usr/local/node && tar -xJf /tmp/node.tar.xz -C /usr/local/node --strip-components=1 \
    && rm /tmp/node.tar.xz && node --version && npm --version

# ---- Zig
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && mkdir -p /usr/local/zig && tar -xJf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz && zig version

# ---- protoc release archive, kept for zig-protobuf: its build.zig.zon declares the protoc release
#      zip as a (lazy) package dependency and requests it even when -Dprotoc points at an installed
#      binary. zig/zig-protobuf/build.sh seeds the Zig package cache from $PROTOC_ARCHIVE_DIR instead
#      of downloading it again at harness-build time (one less network dependency, no proxy issues).
ENV PROTOC_ARCHIVE_DIR=/usr/local/share/protoc-archives
RUN mkdir -p "$PROTOC_ARCHIVE_DIR" \
    && curl -fsSL --retry 5 --retry-all-errors -o "$PROTOC_ARCHIVE_DIR/protoc-${PROTOBUF_VERSION}-linux-x86_64.zip" \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protoc-${PROTOBUF_VERSION}-linux-x86_64.zip" \
    && unzip -tq "$PROTOC_ARCHIVE_DIR/protoc-${PROTOBUF_VERSION}-linux-x86_64.zip"

RUN swift --version && java -version 2>&1 | head -n1 && mvn --version | head -n1 && dotnet --version && python3 --version

# ---- the benchmark suite: build everything now so that running needs no network
FROM toolchain AS bench
WORKDIR /bench
COPY . /bench
ENV PROTOC=/usr/local/bin/protoc PROTOBUF_PREFIX=/usr/local PROTO_BENCH_IMAGE=proto-benchmarks
# zig-protobuf commit under test (the v6.0.0 line); pass --build-arg ZIG_PROTOBUF_REF=<sha-or-branch> to benchmark another one.
ARG ZIG_PROTOBUF_REF=65aa24107dedbd87fece8bb95c19c2d545d23e1a
ENV ZIG_PROTOBUF_REF=${ZIG_PROTOBUF_REF}
# Only used while building the image (e.g. to hand proxy settings to Maven); not persisted.
ARG JAVA_TOOL_OPTIONS=""
RUN ./run.sh --build-only --results /tmp/build-results || (cat /tmp/build-results/failures.txt; exit 1) \
    # package-manager caches are not needed to run the prebuilt harnesses
    && rm -rf /tmp/build-results /usr/local/cargo/registry /go/pkg/mod /root/.cache /root/.npm /root/.nuget/packages

VOLUME ["/bench/results"]
# Everything is prebuilt, so the container runs without rebuilding. To rebuild inside the
# container (e.g. after mounting a modified checkout) use: --entrypoint ./run.sh
ENTRYPOINT ["./run.sh", "--skip-build"]
CMD []
