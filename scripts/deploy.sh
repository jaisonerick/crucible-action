#!/usr/bin/env bash
# Resolves the machine's tailnet address and runs the deploy, passing the
# registry token on stdin so it never appears in argv or in the log.
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

resolve_machine_ip() {
  local ip
  if ! ip=$(tailscale ip -4 "$MACHINE"); then
    fail "'$MACHINE' is not visible from this runner; the tailnet policy must let 'tag:ci-${PROJECT}' reach '$MACHINE' on tcp:7080"
  fi
  echo "$ip"
}

main() {
  local machine_ip
  machine_ip=$(resolve_machine_ip)
  export CRUCIBLE_MACHINE="$machine_ip"

  "$CRUCIBLE" version

  printf '%s' "$REGISTRY_TOKEN" | "$CRUCIBLE" deploy \
    --file "$FILE" \
    --registry "$REGISTRY" \
    --registry-user "$REGISTRY_USER" \
    "$TAG"
}

main
