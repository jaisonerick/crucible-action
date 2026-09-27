#!/usr/bin/env bash
# Downloads the crucible CLI asset and SHA256SUMS for the resolved release,
# verifies the checksum, and exposes the executable's path.
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

download_release() {
  local dir="$1"
  local args=(release download --repo jaisonerick/crucible
    --pattern "$ASSET" --pattern SHA256SUMS --dir "$dir")

  if [[ "$RELEASE" != "latest" ]]; then
    args=(release download "$RELEASE" --repo jaisonerick/crucible
      --pattern "$ASSET" --pattern SHA256SUMS --dir "$dir")
  fi

  if ! gh "${args[@]}"; then
    fail "could not download '$ASSET' from jaisonerick/crucible release '$RELEASE'; the 'crucible-token' input must be able to read jaisonerick/crucible releases"
  fi
}

verify_checksum() {
  local dir="$1"
  local sums="$dir/SHA256SUMS"

  if [[ ! -f "$sums" ]]; then
    fail "SHA256SUMS was not downloaded alongside '$ASSET'"
  fi

  local matches
  matches=$(grep -c -E "^[0-9a-f]{64}[[:space:]]+${ASSET}\$" "$sums" || true)

  if [[ "$matches" -eq 0 ]]; then
    fail "SHA256SUMS has no line for '$ASSET'"
  fi
  if [[ "$matches" -gt 1 ]]; then
    fail "SHA256SUMS has more than one line for '$ASSET'"
  fi

  if ! (cd "$dir" && grep -E "^[0-9a-f]{64}[[:space:]]+${ASSET}\$" SHA256SUMS | shasum -a 256 -c -); then
    fail "'$ASSET' does not match the checksum in SHA256SUMS"
  fi
}

main() {
  local dir
  dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/crucible-download.XXXXXX")

  download_release "$dir"
  verify_checksum "$dir"

  local binary="$dir/$ASSET"
  chmod +x "$binary"

  echo "crucible-path=${binary}" >>"$GITHUB_OUTPUT"
}

main
