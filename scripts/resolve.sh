#!/usr/bin/env bash
# Validates inputs and resolves the project name, the Tailscale tag, the
# release asset name and the normalized crucible version, writing them to
# GITHUB_OUTPUT for the steps that follow.
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

mask_secrets() {
  if [[ -n "${CRUCIBLE_TOKEN:-}" ]]; then
    echo "::add-mask::${CRUCIBLE_TOKEN}"
  fi
  if [[ -n "${REGISTRY_TOKEN:-}" ]]; then
    echo "::add-mask::${REGISTRY_TOKEN}"
  fi
}

validate_tailscale_credentials() {
  local have_audience=0
  local have_secret=0
  [[ -n "${TAILSCALE_AUDIENCE:-}" ]] && have_audience=1
  [[ -n "${TAILSCALE_OAUTH_SECRET:-}" ]] && have_secret=1

  if (( have_audience == 1 && have_secret == 1 )); then
    fail "set only one of 'tailscale-audience' and 'tailscale-oauth-secret', not both"
  fi
  if (( have_audience == 0 && have_secret == 0 )); then
    fail "set one of 'tailscale-audience' (workload identity federation) or 'tailscale-oauth-secret' (OAuth client)"
  fi
}

# Extracts the value of the top-level `project:` key from a YAML file,
# accepting an unquoted, single-quoted or double-quoted value with an
# optional trailing comment. No YAML parser is used.
extract_project_from_file() {
  local file="$1"
  local matches
  matches=$(grep -c -E '^project:' "$file" || true)

  if [[ "$matches" -eq 0 ]]; then
    fail "'$file' has no top-level 'project:' key; set the 'project' input instead"
  fi
  if [[ "$matches" -gt 1 ]]; then
    fail "'$file' has more than one top-level 'project:' key; set the 'project' input instead"
  fi

  grep -E '^project:' "$file" \
    | sed -E 's/^project:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]*$//' \
    | sed -E 's/^"(.*)"$/\1/' \
    | sed -E "s/^'(.*)'\$/\\1/"
}

resolve_project() {
  local project="${PROJECT:-}"

  if [[ -z "$project" ]]; then
    local file="${FILE:-crucible.yml}"
    if [[ ! -f "$file" ]]; then
      fail "'$file' not found; set the 'project' input or add the file"
    fi
    project=$(extract_project_from_file "$file")
  fi

  if [[ ! "$project" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
    fail "project name '$project' does not match ^[a-z][a-z0-9-]{0,31}\$; set the 'project' input"
  fi

  echo "$project"
}

resolve_asset() {
  case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
    Linux/X64)
      echo "crucible-linux-amd64"
      ;;
    Linux/ARM64)
      echo "crucible-linux-arm64"
      ;;
    macOS/ARM64)
      echo "crucible-darwin-arm64"
      ;;
    *)
      fail "unsupported runner ${RUNNER_OS:-}/${RUNNER_ARCH:-}; supported: Linux/X64, Linux/ARM64, macOS/ARM64"
      ;;
  esac
}

normalize_version() {
  local version="${CRUCIBLE_VERSION:-latest}"

  if [[ "$version" == "latest" ]]; then
    echo "latest"
  elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "v${version}"
  elif [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$version"
  else
    fail "crucible-version '$version' is not 'latest', '0.8.0' or 'v0.8.0'"
  fi
}

main() {
  mask_secrets
  validate_tailscale_credentials

  local project
  project=$(resolve_project)
  local asset
  asset=$(resolve_asset)
  local release
  release=$(normalize_version)

  {
    echo "project=${project}"
    echo "tailscale-tag=tag:ci-${project}"
    echo "asset=${asset}"
    echo "release=${release}"
  } >>"$GITHUB_OUTPUT"
}

main
