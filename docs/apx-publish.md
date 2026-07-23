# apx publish-on-change (ARCH-271)

The reusable workflow that keeps an Infoblox service's API in sync with the
apx-managed catalog (`Infoblox-CTO/apis`) **automatically** — it re-publishes on
every API change instead of drifting the moment the service changes its API.

Foundational shared mechanism for **ARCH-271**, piloted on **athena-identity-service**
(ARCH-229), adopted by the ~43 ARCH-227 brownfield-onboarding repos **by
configuration**.

## Home

This workflow lives in **`infobloxopen/apx-action`** — the repo teams already
consume to install apx. `apx` owns the schema *lifecycle* (convert is
devedge-sdk; release/breaking/catalog are apx); this workflow only **orchestrates**
(`FDS → convert → apx release`). It does not reimplement release logic.

- Reusable workflow: `.github/workflows/apx-publish.yml` (`on: workflow_call`)
- Engine (runs identically in CI and locally): `scripts/apx-publish.sh`
- Prebuilt toolchain: `ghcr.io/infobloxopen/apx-toolchain` (built by
  `.github/workflows/publish-toolchain-image.yml` from the `Dockerfile`)

Because consumers reference the workflow by ref, a fix here reaches every repo by
bumping one ref — no per-repo edit.

## Toolchain (prebuilt image)

The workflow pulls its tools from a **prebuilt, pinned image**
(`ghcr.io/infobloxopen/apx-toolchain:v1`) and lifts the binaries onto `PATH`,
instead of installing + compiling them on every run (which cost ~2 min:
`npm install spectral`, `go install oasdiff`/`protoc-gen-go`, `curl` apx/buf).
It bundles apx, the `openapiv2to3` converter, buf, spectral (standalone binary —
no node/npm), oasdiff, and protoc-gen-go[-grpc], plus yq + jq.

The job stays on `ubuntu-latest` (rather than a `container:` job) on purpose: the
FDS step runs the repo's **own** `docker run ...atlas-gentool` and needs the host
Docker daemon, so the tools ride *alongside* it rather than replacing the host.

**The FDS is cached, not committed.** The FileDescriptorSet the converter reads is a
pure function of two input sets, and the workflow caches it (`actions/cache`)
instead of asking each repo to commit a `.binpb`:

1. **The protos in the compile closure** — the service protos plus every import that
   resolves from the repo (its committed `proto/third-party`).
2. **The gentool image + the recipe** — protos bundled *inside* the image (the
   `google/*` well-known types, `google/api`, …) are versioned by the image pin, and
   the `-I` includes + `--include_imports` flag live in the makefiles alongside it.

The cache key is a content hash over both: every `**/*.proto` and every `**/Makefile*`
(overridable per repo via `fds_key_files:`). Any change to a proto, an include, or the
gentool pin flips the key, so on a cache hit the publish script skips `make <fds_target>`
entirely — the atlas-gentool `docker run` (the slow step) runs only when an FDS input
actually changed. Correct by construction (a proto change can never publish a stale FDS)
and self-healing (nothing to re-commit). Over-breadth is safe: an unrelated match only
forces a needless regen, never a stale hit.

> **Pin the gentool by digest.** The key hashes the pin *string*, so a floating or
> re-pushable tag could let a re-pushed image serve a stale cached FDS. Pin the image
> by `@sha256:…` (keep the human tag for readability: `atlas-gentool:v21.8.17@sha256:…`).
> This closes the gap *and* makes the un-cached `make fds` reproducible.

**Latest-vs-fast:** the moving `:v1` / `:latest` tags are rebuilt whenever apx or the
converter cut a release, so floating-tag consumers get the newest set as a fast image
*pull*, never a compile; the validators (buf/spectral/oasdiff/protoc-gen-go[-grpc])
stay pinned for reproducibility.

## Formats

One repo can publish any mix of apx's six schema formats — `openapi`, `crd`,
`proto`, `avro`, `jsonschema`, `parquet` — from a single `.apx-publish.yaml`. Each
module declares only the source its format needs; the workflow loops over the
modules, runs the correct **emit step** for each, then runs one common
validate-and-publish tail (`status → breaking → verify-clients → pathlint →
release`).

A module's format is **inferred from the first segment of its id**
(`crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1` → `crd`); an explicit
`format:` field overrides. The catalog path is the id, so a module lands under its
format's subtree (`/openapi`, `/crd`, …) by construction.

| Format | Source field(s) | Emit step | Staged as | `verify-clients` default | Catalog path |
|---|---|---|---|---|---|
| `openapi` | `swagger` + `fds` | `make <fds_target>` → `openapiv2to3` | `<name>.yaml` | on (client) | `/openapi` |
| `crd` | `crd` | none — CRD YAML used directly | `<name>.yaml` | on (client) | `/crd` |
| `proto` | `fds` | none — FDS used directly | `<name>.binpb` | on (client) | `/proto` |
| `jsonschema` | `jsonschema` | none | `<name>.json` | off | `/jsonschema` |
| `avro` | `avro` | none | `<name>.avsc` | off | `/avro` |
| `parquet` | `parquet` | none | `<name>.parquet` | off | `/parquet` |

Only `openapi` runs the OpenAPI toolchain (`make <fds_target>` → `openapiv2to3`);
every other format uses its committed source verbatim. `make <fds_target>` runs
once for the fds-bearing modules and is **skipped entirely** for a repo of only
crd / message-schema modules.

**Versioning.** `openapi`, `proto`, and the message-schema formats version with
SemVer (`vN` lines bumped by `version_bump`). A `crd`'s version identity **is** its
K8s API version (`v1alpha1` / `v1beta1` / `v1`): content changes republish in place
(no numeric bump), and the stability suffix maps to lifecycle
(`alpha`→experimental, `beta`→beta, none→stable) unless the module sets `lifecycle:`.

> New catalog paths (e.g. `/crd`) must be provisioned in the catalog repo before a
> format can publish there — an owner action, tracked separately from this workflow.

Example — one repo publishing three formats:

```yaml
modules:
  - id: openapi/csp.infoblox.com/iam-identity/v2   # format inferred: openapi
    swagger: pkg/v2/pb/identity.swagger.json
    fds: api-v2.binpb
    audience: public
  - id: crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1
    crd: config/crd/bases/csp.platform.infoblox.com_cspaccountclaims.yaml
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: repo/auditlog/schema/pb/AuditLog.jsonschema
```

A module with no `format:` and an `openapi/…` id behaves exactly as before — no
regression.

## Gating (per concern, format, module)

Two gates run independently per module: the **breaking** gate and the
**verify-clients** (SDK build) gate. Each resolves with this precedence — first
match wins:

1. the module's own field (`breaking:` / `verify_clients:` on the module),
2. `formats.<fmt>.<concern>` (all modules of that format),
3. `gates.<concern>` (repo-wide default),
4. the workflow input (`breaking-gate` / `verify-clients`).

Good global defaults mean most repos configure nothing:

- **breaking** — `auto`: public modules block on a breaking change, internal is advisory.
- **verify-clients** — client-generating formats (`openapi`/`crd`/`proto`) inherit
  the workflow default (`warn` during rollout); non-client formats
  (`avro`/`jsonschema`/`parquet`) default to `off` and never fail the run.

Example — fail hard on the public REST client, warn on CRDs, leave schemas off:

```yaml
gates:
  verify_clients: warn          # repo-wide default for every module
formats:
  openapi:
    verify_clients: fail        # every openapi module must build its client
modules:
  - id: crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1
    crd: config/crd/bases/....yaml
    verify_clients: warn        # this one module only
```

`generators:` may likewise be set per module or per `formats.<fmt>`, falling back
to the repo-wide `verify_clients.generators` (default `go`).

## Pipeline

The pipeline below is the **`openapi`** emit followed by the common tail. Other
formats skip the first two lines (`make <fds_target>` + `openapiv2to3`) and feed
their source spec straight into `status → breaking → verify-clients → pathlint →
release` — see [Formats](#formats).

```
make <fds_target>                     # the repo's OWN pinned gentool: --descriptor_set_out --include_imports
openapiv2to3 -descriptor <fds> <swagger> <out>   # enriched OpenAPI v3 (v0.60.0; tolerant matching is the default)
apx release status <id> --canonical-dir <clone>  # drift: unchanged | changed | absent (schema-scoped, ignores go.mod)
apx breaking <new> --against <published>          # public = blocking, internal = advisory
apx client verify --input <spec> --generator go   # SDK build gate: generate + compile the client (fail by default)
apx pathlint --ingress <rendered> --spec <specs> --warn-only   # path reconciliation — a metric, never a gate (R4)
```

### SDK build gate (`verify-clients`)

A spec can pass `lint`/`breaking` yet still generate a client that does not
compile — e.g. a path parameter named `url` that shadows the `net/url` import,
or redundant `limit`/`offset` params that collide with `_limit`/`_offset` on one
Go field (see [`infobloxopen/apx`#42](https://github.com/infobloxopen/apx/pull/42)).
For each converted spec the pipeline runs `apx client verify`, which generates a
client and **compiles** it.

The `verify-clients` workflow input is the **run-wide default**; it is resolved
per module (module field > `formats.<fmt>` > `gates` > this input — see
[Gating](#gating-per-concern-format-module)), and by default only
client-generating formats (`openapi`/`crd`/`proto`) run it at all:

| value | behavior |
|-------|----------|
| `warn` (current default) | run and report, never fail |
| `fail` | generate + compile the module's client; **fail the run** (check *and* publish, before any publish PR) if it does not build |
| `off` | skip the gate |

> **Rollout:** the default is temporarily `warn` while active publishers adopt
> the fix; it will move to `fail` (hard gate, opt-out) once their clients build.

Generators default to `go`; override per repo with `verify_clients.generators`,
or per format / module (see [Gating](#gating-per-concern-format-module)) in
`.apx-publish.yaml`. The gate needs the prebuilt `apx-toolchain` image to
provide `apx client verify` — a stale image without it will error (under `fail`,
that fails the publish by design). Rebuild the toolchain image from an apx that
includes the command (>= v0.21.0) before switching the default to `fail`.

- **check** (PR): report drift + breaking + path-reconciliation. Fails on a
  **blocking breaking change to a public module** or a **client that does not
  build** (`verify-clients: fail`); everything else is a report.
- **publish** (push to default branch): for each module whose API `changed` or is
  `absent`, open a **PR into the catalog** and a **drift issue**. Public modules
  with a blocking breaking change are skipped (not silently published).

## Adopt in a service repo (three files)

1. **`make fds`** — add one target that emits a FileDescriptorSet per surface via
   the repo's existing gentool. One flag; no toolchain upgrade, no service rewrite:
   ```make
   fds:
   	$(GENERATOR) $(FDS_INCLUDES) --include_imports \
   		--descriptor_set_out=$(PROJECT_ROOT)/api-v1.binpb $(PROJECT_ROOT)/pkg/v1/pb/identity.proto
   ```
   Pin the gentool image **by digest** (`ghcr.io/…/atlas-gentool:v21.8.17@sha256:…`),
   not a bare tag — the FDS cache trusts the pin, and a digest makes it immutable.
   If your gentool pin does **not** live in a `Makefile*` (e.g. it's in a `.env` or a
   script), list the file(s) that carry it under `fds_key_files:` (below) so the cache
   key sees a gentool bump.
2. **`apx.yaml`** — standard apx project config. `module_roots` must include where
   the workflow stages converted specs (`build/apx-modules`).
3. **`.apx-publish.yaml`** — the entire per-repo adoption surface:
   ```yaml
   canonical_repo: github.com/Infoblox-CTO/apis   # or a sandbox
   forge: github                                   # github | gitea
   fds_target: fds
   converter_version: v0.60.0
   version_bump: minor
   # branch_targets:               # optional (ARCH-271) — service source branch →
   #   main: main                  # apis base branch. Default main/master→main,
   #   master: main                # develop→develop; tweakable. A base branch other
   #   develop: develop            # than main is a pre-release (beta) channel.
   # fds_key_files:                # optional — files that determine the FDS bytes.
   #   - '**/*.proto'              # default: all protos + every Makefile* (the
   #   - '**/Makefile*'            # gentool pin + includes). Override only if your
   #   - 'build/gentool.version'   # gentool pin lives outside a Makefile*.
   modules:
     - id: openapi/csp.infoblox.com/identity/v2    # R10 module ID
       swagger: pkg/v2/pb/identity.swagger.json    # committed gateway swagger
       fds: api-v2.binpb                           # FDS from `make fds`
       lifecycle: stable
       audience: public                            # public blocks on breaking; internal is advisory
     - id: openapi/csp.infoblox.com/identity-internal/v2
       swagger: pkg/v2/pb/identity.private.swagger.json
       fds: api-v2.binpb
       audience: internal                          # only if the private swagger is a real byte-different superset (R3)
   pathlint:
     chart: helm/identity
   ```

Then two thin caller workflows (see the athena pilot's
`.github/workflows/api-catalog-{pr,publish}.yml`):

```yaml
# on: pull_request
jobs:
  check:
    uses: infobloxopen/apx-action/.github/workflows/apx-publish.yml@v1
    with: { mode: check, apx-action-ref: v1 }
    secrets:
      apx-app-id:          ${{ secrets.APX_SUBMIT_APP_ID }}
      apx-app-private-key: ${{ secrets.APX_SUBMIT_APP_PRIVATE_KEY }}
```

```yaml
# on: push to the default branch
jobs:
  publish:
    uses: infobloxopen/apx-action/.github/workflows/apx-publish.yml@v1
    with: { mode: publish, apx-action-ref: v1 }
    secrets:
      apx-app-id:          ${{ secrets.APX_SUBMIT_APP_ID }}
      apx-app-private-key: ${{ secrets.APX_SUBMIT_APP_PRIVATE_KEY }}
```

### Credentials (least privilege, no per-repo secrets)

The workflow mints a **short-lived installation token** from a dedicated
least-privilege **catalog "submit" GitHub App** via `create-github-app-token`,
scoped to the catalog repo. The App needs only `contents:write` +
`pull_requests:write` + `issues:write` on the catalog — **no tag-ruleset bypass
and no admin** — so it can push an `apx/release/*` branch and open a PR + drift
issue, but cannot push tags, merge, or bypass branch protection (merges still
require the catalog's `CODEOWNERS` review). Its `APX_SUBMIT_APP_ID` /
`APX_SUBMIT_APP_PRIVATE_KEY` live as **organization secrets in the consuming
repos' org** (not this repo — a reusable workflow resolves secrets from the
caller's context), so the ~40 adopting repos manage nothing beyond `secrets:`
passing. This is deliberately a *different, narrower* App than the canonical
repo's high-privilege release/finalize App.

## R10 module IDs

`openapi/«system».infoblox.com/«family»-«surface»/«line»`. The ratified family
roster under `csp.infoblox.com` is `ddi, wapi, infra, iam, td, platform` (plus
`sso.infoblox.com`). The name slot never derives from the serving path — serving
facts stay in the AppContract. The roster must ship as a machine-readable file in
the catalog repo before fleet onboarding (see WS-035 R10).

## Forge switch (finding G1)

`apx release submit` opens the catalog PR natively on **GitHub** — the fleet path
against `Infoblox-CTO/apis`. For a **non-GitHub sandbox** (the dogfood Gitea), set
`forge: gitea`; the engine uses Gitea's REST API for the PR + issue (apx's native
submit is GitHub-only). `--canonical-dir` reads the catalog for drift/breaking with
no network and works with any forge.

## Notes & caveats

- **Baseline:** the workflow's deterministic conversion is the source of truth. The
  first `publish` run establishes the published baseline; subsequent runs read
  `unchanged` until the API actually changes. A hand-edited catalog spec will read
  as `changed`/`breaking` against a fresh convert — let the workflow own the spec.
- **Version:** `version_bump` (default `minor`) bumps the latest published version;
  a first publish uses `v<line>.0.0`.
- **Branch routing (ARCH-271):** the source branch resolves through
  `branch_targets` to the catalog base branch. main/master publish stable to apis
  `main`; develop publishes to apis `develop` as pre-releases (`vX.Y.Z-beta.N`
  carrying a short commit hash, e.g. `v1.2.0-beta.1.g1a2b3c4d5e6f`). A fail-closed
  ratchet rejects a beta at or below the line's highest GA — the PR check fails,
  and so does the develop-branch publish before tagging. The routing branch is
  event-aware: on **push** it is the pushed branch (`github.ref_name`); on a
  **pull_request** it is the PR's **base branch** (`github.base_ref`) — the branch
  the PR merges into — because `github.ref_name` there is the `<PR#>/merge` ref,
  which routes to no channel. Keying the check on the base branch makes a PR into
  `develop` run the pre-release channel and its ratchet (a real pre-merge gate),
  and a PR into `main`/`master` run the stable channel — matching the publish that
  the merge will trigger.
- **Gateway era:** read the actual `--swagger_out` vs `--openapiv2_out` flag from the
  repo's Makefile when onboarding; do not infer it from the gentool tag.
- **Converter:** v0.60.0 made tolerant `(verb,path)`-from-FDS matching the default
  (`-strict` opts back into fail-loud; `-compat` is a deprecated no-op).

## Piloted end to end

Proven on athena-identity-service against a local Gitea catalog: first publish
(3 modules `absent` → PRs + drift issues → merged baseline) → re-check all
`unchanged` → an out-of-band swagger change flips only that module to `changed`
(additive, `breaking=ok`) → `publish` opens the republish PR (v2.1.0) carrying the
new path + a drift issue. Path-reconciliation reported `undeclared=4 unreachable=9`
as a warning throughout.
