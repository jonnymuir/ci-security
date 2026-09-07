#!/usr/bin/env bash
#
# Fails the build when `dotnet list package --vulnerable` reports a High or Critical
# advisory against any package in the given solution/project, UNLESS that advisory's
# id is recorded in the allow-list file.
#
# Moderate/Low advisories, and anything on the allow-list, are written to the job
# summary but never fail the build. Dependabot alerts are advisory-only and do not
# gate a merge, so this is what actually holds the line on shipped dependencies.
#
# Usage: check-vulnerable-packages.sh <solution-or-project> [allowlist-path]
#        (run after `dotnet restore`)
#
#   allowlist-path defaults to .github/allowed-advisories.txt in the caller repo.
#   A missing allow-list file is treated as "nothing accepted".

set -euo pipefail

TARGET="${1:?usage: check-vulnerable-packages.sh <solution-or-project> [allowlist-path]}"
ALLOWLIST="${2:-.github/allowed-advisories.txt}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# Accepted advisory ids: the leading GHSA-… / CVE-… token on each non-comment line.
# Everything after it (a '#' reason + revisit condition) is for humans.
allowed=""
if [[ -f "$ALLOWLIST" ]]; then
  allowed="$(grep -oE '^(GHSA-[[:alnum:]-]+|CVE-[0-9]{4}-[0-9]+)' "$ALLOWLIST" || true)"
  echo "Allow-list: $ALLOWLIST"
else
  echo "Allow-list: $ALLOWLIST (not present — nothing accepted)"
fi

json="$(dotnet list "$TARGET" package --vulnerable --include-transitive --format json --output-version 1)"

# One row per (package, advisory): "<severity>\t<package>\t<resolved>\t<project>\t<url>"
rows="$(
  jq -r '
    .projects[]? as $p
    | ($p.path | sub(".*/"; "")) as $proj
    | $p.frameworks[]?
    | ((.topLevelPackages // []) + (.transitivePackages // []))[]
    | . as $pkg
    | (.vulnerabilities // [])[]
    | [ .severity, $pkg.id, $pkg.resolvedVersion, $proj, .advisoryurl ]
    | @tsv
  ' <<<"$json"
)"

blocking=""
info=""
fail=0

while IFS=$'\t' read -r severity pkg resolved project url; do
  [[ -z "${severity:-}" ]] && continue
  id="$(grep -oE '(GHSA-[[:alnum:]-]+|CVE-[0-9]{4}-[0-9]+)' <<<"$url" | head -n1 || true)"
  [[ -z "$id" ]] && id="$url"

  case "$(tr '[:upper:]' '[:lower:]' <<<"$severity")" in
    critical|high)
      if [[ -n "$allowed" ]] && grep -qxF "$id" <<<"$allowed"; then
        info+="- ✅ allow-listed — **${pkg}** ${resolved} · ${severity} · ${id} · _${project}_"$'\n'
      else
        blocking+="- ❌ **${pkg}** ${resolved} · ${severity} · [${id}](${url}) · _${project}_"$'\n'
        fail=1
      fi
      ;;
    *)
      info+="- ℹ️ **${pkg}** ${resolved} · ${severity} · ${id} · _${project}_"$'\n'
      ;;
  esac
done <<<"$rows"

{
  echo "## NuGet vulnerability scan — \`${TARGET}\`"
  if [[ -n "$blocking" ]]; then
    echo ""
    echo "### Blocking — High/Critical, not allow-listed"
    echo ""
    printf '%s' "$blocking"
  fi
  if [[ -n "$info" ]]; then
    echo ""
    echo "### Informational — Moderate/Low, or allow-listed"
    echo ""
    printf '%s' "$info"
  fi
  if [[ -z "$blocking$info" ]]; then
    echo ""
    echo "No known-vulnerable packages. 🎉"
  fi
} >>"$SUMMARY"

if [[ "$fail" -ne 0 ]]; then
  echo "::error::High/Critical vulnerable NuGet package(s) not listed in ${ALLOWLIST}"
  printf '%s' "$blocking"
  exit 1
fi

echo "No blocking NuGet vulnerabilities."
