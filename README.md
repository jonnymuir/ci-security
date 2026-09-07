# ci-security

Shared CI security for the Wayfinder estate (`Wayfinder`, `Wayfinder.Umbraco`,
`Umbraco.Prism`) and its consumers (e.g. `NckExchange`). One source of truth instead of
a copy of the same workflow in every repo.

## What it runs

| Check | Posture | |
|---|---|---|
| **CodeQL** | advisory | Advanced setup, configurable languages, `security-extended`. C# uses `build-mode: manual` and replays the real build. Findings → Security tab; do **not** fail the run. |
| **Vulnerable NuGet packages** | **blocking** | `dotnet list package --vulnerable` → a High/Critical fails unless its GHSA/CVE id is in the caller's `.github/allowed-advisories.txt`. Moderate/Low → job summary only. |
| **Dependency review** | **blocking** on PRs | No new High+ vulnerable dependency may be introduced. |
| **Zizmor** | advisory | GitHub Actions SAST over the caller's own workflow files. |
| **security-all** | — | The single status check to require in branch protection. Enforces the two supply-chain gates; CodeQL and Zizmor are advisory. |

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

## Versioning

Pin `@v1` — a moving major tag. Breaking changes go out as `@v2` (the internal
composite-action ref is bumped in lockstep at that point).

## Contents

- `.github/workflows/dotnet-security.yml` — the reusable workflow (`workflow_call`).
- `.github/actions/nuget-vuln-gate/` — composite action wrapping the vuln-gate script;
  usable on its own (e.g. in a deploy workflow before publishing).
