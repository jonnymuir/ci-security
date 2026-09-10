# ci-security

Shared CI security for the Wayfinder estate (`Wayfinder`, `Wayfinder.Umbraco`,
`Umbraco.Prism`) and its consumers (e.g. `NckExchange`). One source of truth instead of
a copy of the same workflow in every repo.

## What it runs

| Check | Posture | |
|---|---|---|
| **Vulnerable NuGet packages** | **blocking** (via `security-all`) | `dotnet list package --vulnerable` → a High/Critical fails unless its GHSA/CVE id is in the caller's `.github/allowed-advisories.txt`. Moderate/Low → job summary only. |
| **Dependency review** | **blocking** on PRs (via `security-all`) | No new High+ vulnerable dependency may be introduced. |
| **CodeQL** | via required check-run | Advanced setup, configurable languages, `security-extended`. C# uses `build-mode: manual` and replays the real build. SARIF → Security tab. The action never fails its own job — make the **`CodeQL`** check-run required (see below). |
| **Zizmor** | via required check-run | GitHub Actions SAST over the caller's own workflow files. SARIF → Security tab. Make the **`zizmor`** check-run required (see below). |

### Required checks

- **`security / security-all`** — the supply-chain gate (NuGet + dependency-review).
- **`CodeQL`** and **`zizmor`** — the code-scanning check-runs. They go red when a PR
  introduces a finding. Add them as required too, once the repo's existing findings are
  triaged to zero, so new findings can't merge.

## Use it

Add `.github/workflows/security.yml` to the consuming repo:

```yaml
name: Security
on:
  pull_request:
  push:
    branches: [ main ]
  schedule:
    - cron: '0 3 * * 1'   # Mondays 03:00 UTC
  workflow_dispatch:

jobs:
  security:
    uses: jonnymuir/ci-security/.github/workflows/dotnet-security.yml@v1
    permissions:
      contents: read
      security-events: write
      actions: read
      pull-requests: write
    with:
      solution: Wayfinder.slnx
      # optional — dirs to `npm ci && npm run build` before the C# CodeQL build:
      node-build: '["Wayfinder.Editor.Client"]'
      # optional overrides:
      # dotnet-version: '10.0.x'
      # codeql-languages: '["csharp", "javascript-typescript"]'
      # allowed-advisories-path: .github/allowed-advisories.txt
```

Checks appear as `security / <job>` — require **`security / security-all`** in branch
protection.

### One-time per repo

1. **Disable CodeQL default setup** (advanced setup here conflicts with it):

   ```sh
   gh api -X PATCH repos/OWNER/REPO/code-scanning/default-setup -f state=not-configured
   ```

2. **Add `.github/allowed-advisories.txt`** (may be empty). One accepted advisory per
   line: `GHSA-… # reason, and when to revisit`. The vuln gate fails on any
   unlisted High/Critical.

3. **`.github/dependabot.yml` stays in each repo** — Dependabot only reads its own
   repo's file. Keep a `github-actions` ecosystem entry so the `@v1` pin above is kept
   current. Example with a 7-day supply-chain cooldown:

   ```yaml
   version: 2
   updates:
     - package-ecosystem: nuget
       directory: "/"
       schedule: { interval: weekly, day: monday }
       cooldown: { default-days: 7 }
       groups: { dotnet: { patterns: ["*"], update-types: ["minor", "patch"] } }
     - package-ecosystem: github-actions
       directory: "/"
       schedule: { interval: weekly, day: monday }
       cooldown: { default-days: 7 }
       groups: { actions: { patterns: ["*"] } }
   ```

## DAST (dynamic) — `dast-baseline.yml`

`dotnet-security.yml` above is SAST (analyses source). `dast-baseline.yml` runs
**OWASP ZAP** against a *running* instance of the app — passive rules only, no active
attacks, non-destructive. Catches what SAST can't: missing/mis-set security headers
(CSP, HSTS, `X-*`), cookie flags (`Secure` / `HttpOnly` / `SameSite`), cache-control on
sensitive responses, info disclosure, the `Server` header.

**Posture: advisory** (`fail-action: false`) — uploads a report artifact + writes it to
the job summary, never blocks. Once the caller has triaged its findings into a checked-in
ZAP rules file (accepted findings marked `IGNORE`), flip `fail-action: true` and add the
**`DAST baseline`** check-run to branch protection — the same "advisory then required"
path SAST took.

Because it boots an app, it lives in its **own** `dast.yml` in the consuming repo, not in
`security.yml`. Run it on a schedule + `workflow_dispatch` (a PR gate can come later, once
tuned).

```yaml
name: DAST
on:
  schedule:
    - cron: '0 4 * * *'   # nightly
  workflow_dispatch:

jobs:
  baseline:
    uses: jonnymuir/ci-security/.github/workflows/dast-baseline.yml@v1
    permissions:
      contents: read
    with:
      boot-command: dotnet run --project Wayfinder.ReferenceApp --urls http://127.0.0.1:8080
      target-url: http://127.0.0.1:8080
      health-path: /account/login
      node-build: '["Wayfinder.Editor.Client"]'   # bundles the host serves as static assets
      # rules-file-path: .zap/rules.tsv           # default; create it empty on first adoption
      # fail-action: false                        # default; flip to true once tuned
```

Add an empty `.zap/rules.tsv` to the consuming repo on first adoption (one triaged
finding per line: `<alert-id>\t<IGNORE|WARN|FAIL>\t<url regex>\t# note`). The ZAP
container mounts the repo root, so the path is repo-root-relative.

`action-baseline` runs ZAP with `--network=host`, so `127.0.0.1:<port>` inside the scan
reaches the app this workflow booted on the runner.

## Versioning

Pin `@v1` — a moving major tag. Breaking changes go out as `@v2` (the internal
composite-action ref is bumped in lockstep at that point).

## Contents

- `.github/workflows/dotnet-security.yml` — reusable SAST + supply-chain (`workflow_call`).
- `.github/workflows/dast-baseline.yml` — reusable OWASP ZAP baseline scan (`workflow_call`).
- `.github/actions/nuget-vuln-gate/` — composite action wrapping the vuln-gate script;
  usable on its own (e.g. in a deploy workflow before publishing).
