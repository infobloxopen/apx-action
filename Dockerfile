# apx publish-on-change toolchain image (ghcr.io/infobloxopen/apx-toolchain).
#
# A prebuilt, pinned bundle of every binary the apx publish-on-change pipeline
# (scripts/apx-publish.sh) needs, so CI can PULL the toolchain in seconds instead
# of installing + compiling it from scratch on every run (npm install spectral,
# go install oasdiff/protoc-gen-go, curl apx/buf). See .github/workflows/apx-publish.yml.
#
# Latest-vs-fast split (ARCH-271): apx + the openapiv2to3 converter track their
# latest releases (the moving :v1 / :latest image tags are rebuilt when they cut a
# release, so floating-tag consumers get the newest set — as a fast image *pull*,
# never a compile). The validators (buf / spectral / oasdiff / protoc-gen-go[-grpc])
# are PINNED for reproducibility.
#
# Multi-arch: linux/amd64 + linux/arm64. The Go converter is CROSS-compiled from the
# native build platform (no emulation); the prebuilt release binaries are selected
# per TARGETARCH and only downloaded (emulation cost is negligible for curl).

# ── Stage 1: cross-compile the openapiv2to3 converter (devedge-sdk) ────────────
FROM --platform=$BUILDPLATFORM golang:1.23-bookworm AS converter
ARG TARGETOS
ARG TARGETARCH
# devedge-sdk cmd/openapiv2to3 — enriched OpenAPI v3 conversion (tracks latest).
ARG CONVERTER_VERSION=v0.60.0
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
RUN --mount=type=secret,id=github_token \
    set -eu; \
    if [ -f /run/secrets/github_token ]; then \
      git config --global url."https://x-access-token:$(cat /run/secrets/github_token)@github.com/".insteadOf "https://github.com/"; \
    fi; \
    # No GOBIN: `go install` refuses GOBIN when cross-compiling. Cross builds land in
    # $GOPATH/bin/${GOOS}_${GOARCH}; native in $GOPATH/bin — locate either robustly.
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
      go install "github.com/infobloxopen/devedge-sdk/cmd/openapiv2to3@${CONVERTER_VERSION}"; \
    bin="$(find "$(go env GOPATH)/bin" -type f -name openapiv2to3 | head -1)"; \
    mkdir -p /out; cp "$bin" /out/openapiv2to3

# ── Stage 2: assemble the pinned toolchain on a small glibc base ───────────────
FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH

# Pinned validator versions (reproducibility). apx tracks latest (resolved by the
# publish workflow and passed in); the converter is baked from stage 1.
ARG APX_VERSION=latest
ARG BUF_VERSION=v1.45.0
ARG SPECTRAL_VERSION=6.15.0
ARG OASDIFF_VERSION=v1.22.0
ARG PROTOC_GEN_GO_VERSION=v1.36.11
ARG PROTOC_GEN_GO_GRPC_VERSION=v1.6.2
ARG YQ_VERSION=v4.53.3
ARG JQ_VERSION=1.8.2

# Runtime deps the engine shells out to: bash, git, make, curl, ca-certs, tar.
# jq + yq (mikefarah v4) are installed as pinned binaries below (debian's `yq`
# package is an unrelated tool). These apt packages land in /usr/bin.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl git make tar xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Everything the engine puts on PATH lives in /usr/local/bin so the reusable
# workflow can lift the whole directory out of the image in one `docker cp`.
# Tracing (set -x) is intentionally OFF here: the download commands carry the
# GITHUB_TOKEN in an Authorization header and must not be echoed to the build log.
RUN --mount=type=secret,id=github_token \
    set -eu; \
    GITHUB_TOKEN="$( [ -f /run/secrets/github_token ] && cat /run/secrets/github_token || true )"; \
    AUTH=(); if [ -n "$GITHUB_TOKEN" ]; then AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); fi; \
    dl() { curl -fsSL --retry 3 "${AUTH[@]}" "$1" -o "$2"; }; \
    # Extract a single named binary from a tarball regardless of internal layout
    # (some archives are flat, others are ./-prefixed with README/LICENSE).
    untar_bin() { local d; d="$(mktemp -d)"; tar -xzf "$1" -C "$d"; \
      install -m0755 "$(find "$d" -type f -name "$2" | head -1)" "$BIN/$2"; rm -rf "$d"; }; \
    case "$TARGETARCH" in \
      amd64) BUF_ARCH=x86_64;  SPECTRAL_ARCH=x64;   GOARCH=amd64 ;; \
      arm64) BUF_ARCH=aarch64; SPECTRAL_ARCH=arm64; GOARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    BIN=/usr/local/bin; mkdir -p "$BIN"; tmp="$(mktemp -d)"; \
    \
    # apx (tracks latest). install.sh prepends "v" to VERSION and verifies SHA-256;
    # pass the version WITHOUT a leading "v" (empty => resolve latest).
    APXV="${APX_VERSION#v}"; if [ "$APXV" = latest ]; then APXV=""; fi; \
    echo "==> apx ${APXV:-latest}"; \
    curl -fsSL https://raw.githubusercontent.com/infobloxopen/apx/main/install.sh \
      | VERSION="$APXV" INSTALL_DIR="$BIN" bash; \
    \
    echo "==> buf ${BUF_VERSION}"; \
    dl "https://github.com/bufbuild/buf/releases/download/${BUF_VERSION}/buf-Linux-${BUF_ARCH}" "$BIN/buf"; \
    chmod +x "$BIN/buf"; \
    \
    echo "==> spectral v${SPECTRAL_VERSION} (standalone binary — no node/npm)"; \
    dl "https://github.com/stoplightio/spectral/releases/download/v${SPECTRAL_VERSION}/spectral-linux-${SPECTRAL_ARCH}" "$BIN/spectral"; \
    chmod +x "$BIN/spectral"; \
    \
    echo "==> oasdiff ${OASDIFF_VERSION}"; \
    dl "https://github.com/oasdiff/oasdiff/releases/download/${OASDIFF_VERSION}/oasdiff_${OASDIFF_VERSION#v}_linux_${GOARCH}.tar.gz" "$tmp/oasdiff.tgz"; \
    untar_bin "$tmp/oasdiff.tgz" oasdiff; \
    \
    echo "==> protoc-gen-go ${PROTOC_GEN_GO_VERSION}"; \
    dl "https://github.com/protocolbuffers/protobuf-go/releases/download/${PROTOC_GEN_GO_VERSION}/protoc-gen-go.${PROTOC_GEN_GO_VERSION}.linux.${GOARCH}.tar.gz" "$tmp/pgg.tgz"; \
    untar_bin "$tmp/pgg.tgz" protoc-gen-go; \
    \
    echo "==> protoc-gen-go-grpc ${PROTOC_GEN_GO_GRPC_VERSION}"; \
    dl "https://github.com/grpc/grpc-go/releases/download/cmd/protoc-gen-go-grpc/${PROTOC_GEN_GO_GRPC_VERSION}/protoc-gen-go-grpc.${PROTOC_GEN_GO_GRPC_VERSION}.linux.${GOARCH}.tar.gz" "$tmp/pggg.tgz"; \
    untar_bin "$tmp/pggg.tgz" protoc-gen-go-grpc; \
    \
    echo "==> yq ${YQ_VERSION} + jq ${JQ_VERSION}"; \
    dl "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${GOARCH}" "$BIN/yq"; chmod +x "$BIN/yq"; \
    dl "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${GOARCH}" "$BIN/jq"; chmod +x "$BIN/jq"; \
    \
    rm -rf "$tmp"

COPY --from=converter /out/openapiv2to3 /usr/local/bin/openapiv2to3

# Fail the build loudly if any tool is missing, and record resolved versions.
RUN set -eux; \
    for t in apx openapiv2to3 buf spectral oasdiff protoc-gen-go protoc-gen-go-grpc yq jq git make bash; do \
      command -v "$t" >/dev/null || { echo "MISSING: $t" >&2; exit 1; }; \
    done; \
    apx --version || true; \
    buf --version; oasdiff --version || true; \
    protoc-gen-go --version; protoc-gen-go-grpc --version; \
    yq --version; jq --version; \
    spectral --version || true

LABEL org.opencontainers.image.source="https://github.com/infobloxopen/apx-action" \
      org.opencontainers.image.description="Prebuilt, pinned toolchain for the apx publish-on-change workflow (apx, openapiv2to3, buf, spectral, oasdiff, protoc-gen-go[-grpc], yq, jq)." \
      org.opencontainers.image.licenses="Apache-2.0"

ENV PATH="/usr/local/bin:${PATH}"
CMD ["bash"]
