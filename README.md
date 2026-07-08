# apx-action

GitHub Action to install the [apx](https://github.com/infobloxopen/apx) CLI and its validator toolchain.

## Usage

### Basic — install apx + full toolchain

```yaml
steps:
  - uses: actions/checkout@v5

  - uses: actions/setup-go@v6
    with:
      go-version-file: go.mod

  - uses: infobloxopen/apx-action@v1

  - run: apx lint internal/apis/proto/payments/ledger
  - run: apx breaking internal/apis/proto/payments/ledger
```

### Pin a specific version

```yaml
- uses: infobloxopen/apx-action@v1
  with:
    version: '0.1.0'
```

### Install apx only (no toolchain)

```yaml
- uses: infobloxopen/apx-action@v1
  with:
    install-toolchain: 'false'
```

### Custom tool versions

```yaml
- uses: infobloxopen/apx-action@v1
  with:
    buf-version: 'v1.45.0'
    spectral-version: '6.15.0'
    oasdiff-version: 'v1.11.7'
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `version` | APX version to install | `latest` |
| `install-toolchain` | Install validator toolchain (buf, spectral, oasdiff, protoc-gen-go) | `true` |
| `buf-version` | buf version | `v1.45.0` |
| `spectral-version` | spectral version | `6.15.0` |
| `oasdiff-version` | oasdiff version | `latest` |
| `token` | GitHub token for downloading releases | `${{ github.token }}` |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The installed apx version |

## What gets installed

When `install-toolchain: true` (default), the action installs:

| Tool | Purpose |
|------|---------|
| **apx** | API Publishing eXperience CLI |
| **buf** | Protocol buffer linting & breaking change detection |
| **spectral** | OpenAPI linting |
| **oasdiff** | OpenAPI breaking change detection |
| **protoc-gen-go** | Go code generation from protobuf |
| **protoc-gen-go-grpc** | gRPC Go code generation from protobuf |

## Prerequisites

- **Go** must be set up (e.g. via `actions/setup-go`) if `install-toolchain: true`
- **Node.js** must be available for spectral (pre-installed on GitHub-hosted runners)

## Prebuilt CI image

This composite action installs the toolchain from scratch, which suits ad-hoc steps.
For repeated CI (e.g. the `apx-publish.yml` reusable workflow), pull the **prebuilt,
pinned** image instead — seconds to pull versus ~2 min to install + compile:

```
ghcr.io/infobloxopen/apx-toolchain:v1   # apx + openapiv2to3 + buf + spectral + oasdiff + protoc-gen-go[-grpc] + yq + jq
```

It carries a standalone `spectral` binary (no node/npm) and is multi-arch
(linux/amd64 + arm64). The moving `:v1`/`:latest` tags track the latest apx +
converter; validators are pinned. Built by `.github/workflows/publish-toolchain-image.yml`.

## License

Apache-2.0
