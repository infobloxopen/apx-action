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

Because consumers reference the workflow by ref, a fix here reaches every repo by
bumping one ref — no per-repo edit.

## Pipeline

```
make <fds_target>                     # the repo's OWN pinned gentool: --descriptor_set_out --include_imports
openapiv2to3 -descriptor <fds> <swagger> <out>   # enriched OpenAPI v3 (v0.60.0; tolerant matching is the default)
apx release status <id> --canonical-dir <clone>  # drift: unchanged | changed | absent (schema-scoped, ignores go.mod)
apx breaking <new> --against <published>          # public = blocking, internal = advisory
apx pathlint --ingress <rendered> --spec <specs> --warn-only   # path reconciliation — a metric, never a gate (R4)
```

- **check** (PR): report drift + breaking + path-reconciliation. Fails only on a
  **blocking breaking change to a public module**; everything else is a report.
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
2. **`apx.yaml`** — standard apx project config. `module_roots` must include where
   the workflow stages converted specs (`build/apx-modules`).
3. **`.apx-publish.yaml`** — the entire per-repo adoption surface:
   ```yaml
   canonical_repo: github.com/Infoblox-CTO/apis   # or a sandbox
   forge: github                                   # github | gitea
   fds_target: fds
   converter_version: v0.60.0
   version_bump: minor
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
