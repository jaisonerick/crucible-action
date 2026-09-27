#!/usr/bin/env bash
# Dependency-free test runner for scripts/*.sh. No bats, no network.
# Each test case runs in a fresh temp directory with stub gh, tailscale and
# crucible executables first on PATH.
#
# shellcheck disable=SC2317,SC2329 # every test_* and helper function below
#   is invoked indirectly, by name, from the dispatch loop in main(); SC2317
#   is how older releases of the linter report that, SC2329 newer ones.
# shellcheck disable=SC2030,SC2031 # each run_* helper exports inputs into a
#   subshell on purpose, to isolate one test case's environment from the next.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS_DIR="$ROOT_DIR/scripts"

FAILED=0

ok() { echo "ok - $1"; }

not_ok() {
  echo "not ok - $1"
  if [[ -n "${2:-}" ]]; then
    local detail="${2//$'\n'/$'\n    '}"
    printf '    %s\n' "$detail"
  fi
  FAILED=$((FAILED + 1))
}

new_case() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-action-test.XXXXXX")
  mkdir -p "$dir/bin"
  echo "$dir"
}

# write_stub <dir> <name> <<'EOF' ... EOF
write_stub() {
  local dir="$1" name="$2"
  cat >"$dir/bin/$name"
  chmod +x "$dir/bin/$name"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    not_ok "$label" "expected to find: $needle
got: $haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$label"
  else
    not_ok "$label" "expected NOT to find: $needle
got: $haystack"
  fi
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    not_ok "$label" "expected: $expected
actual:   $actual"
  fi
}

# run_resolve <dir> runs resolve.sh in <dir> with the caller's local
# PROJECT, FILE, CRUCIBLE_VERSION, RUNNER_OS, RUNNER_ARCH,
# TAILSCALE_AUDIENCE, TAILSCALE_OAUTH_SECRET, CRUCIBLE_TOKEN,
# REGISTRY_TOKEN. Writes stdout/stderr/status/GITHUB_OUTPUT under <dir>.
run_resolve() {
  local dir="$1"
  : >"$dir/GITHUB_OUTPUT"
  local status=0
  (
    export PATH="$dir/bin:$PATH"
    export GITHUB_OUTPUT="$dir/GITHUB_OUTPUT"
    export CRUCIBLE_TOKEN="${CRUCIBLE_TOKEN:-}"
    export REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"
    export TAILSCALE_AUDIENCE="${TAILSCALE_AUDIENCE:-}"
    export TAILSCALE_OAUTH_SECRET="${TAILSCALE_OAUTH_SECRET:-}"
    export PROJECT="${PROJECT:-}"
    export FILE="${FILE:-crucible.yml}"
    export CRUCIBLE_VERSION="${CRUCIBLE_VERSION:-latest}"
    export RUNNER_OS="${RUNNER_OS:-Linux}"
    export RUNNER_ARCH="${RUNNER_ARCH:-X64}"
    cd "$dir"
    bash "$SCRIPTS_DIR/resolve.sh"
  ) >"$dir/stdout" 2>"$dir/stderr" || status=$?
  echo "$status" >"$dir/status"
}

# run_download <dir> runs download.sh with the caller's local GH_TOKEN,
# ASSET, RELEASE, GH_STUB_FIXTURES, GH_STUB_LOG.
run_download() {
  local dir="$1"
  : >"$dir/GITHUB_OUTPUT"
  local status=0
  (
    export PATH="$dir/bin:$PATH"
    export GITHUB_OUTPUT="$dir/GITHUB_OUTPUT"
    export RUNNER_TEMP="$dir"
    export GH_TOKEN="${GH_TOKEN:-dummy-token}"
    export ASSET="${ASSET:-crucible-linux-amd64}"
    export RELEASE="${RELEASE:-latest}"
    export GH_STUB_FIXTURES="${GH_STUB_FIXTURES:-$dir/fixtures}"
    export GH_STUB_LOG="${GH_STUB_LOG:-$dir/gh-args.log}"
    cd "$dir"
    bash "$SCRIPTS_DIR/download.sh"
  ) >"$dir/stdout" 2>"$dir/stderr" || status=$?
  echo "$status" >"$dir/status"
}

# run_deploy <dir> runs deploy.sh with the caller's local CRUCIBLE, MACHINE,
# FILE, TAG, PROJECT, REGISTRY, REGISTRY_USER, REGISTRY_TOKEN.
run_deploy() {
  local dir="$1"
  local status=0
  (
    export PATH="$dir/bin:$PATH"
    export CRUCIBLE="${CRUCIBLE:-$dir/bin/crucible}"
    export MACHINE="${MACHINE:-crucible}"
    export FILE="${FILE:-crucible.yml}"
    export TAG="${TAG:-abc123}"
    export PROJECT="${PROJECT:-demo}"
    export REGISTRY="${REGISTRY:-ghcr.io}"
    export REGISTRY_USER="${REGISTRY_USER:-ci}"
    export REGISTRY_TOKEN="${REGISTRY_TOKEN:-s3cr3t-token}"
    cd "$dir"
    bash "$SCRIPTS_DIR/deploy.sh"
  ) >"$dir/stdout" 2>"$dir/stderr" || status=$?
  echo "$status" >"$dir/status"
}

fixture_sha256sums() {
  local dir="$1"
  (cd "$dir" && shasum -a 256 -- *)
}

### resolve.sh: project resolution ###################################

test_project_from_input() {
  local dir; dir=$(new_case)
  local PROJECT="from-input" TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "project from input: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "project=from-input" "project from input: resolves project"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "tailscale-tag=tag:ci-from-input" "project from input: resolves tailscale tag"
}

test_project_from_file_plain() {
  local dir; dir=$(new_case)
  printf 'project: fromfile\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "project from file (plain): exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "project=fromfile" "project from file (plain): resolves project"
}

test_project_from_file_double_quoted() {
  local dir; dir=$(new_case)
  printf 'project: "fromfile"\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "project from file (double-quoted): exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "project=fromfile" "project from file (double-quoted): resolves project"
}

test_project_from_file_single_quoted() {
  local dir; dir=$(new_case)
  printf "project: 'fromfile'\n" >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "project from file (single-quoted): exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "project=fromfile" "project from file (single-quoted): resolves project"
}

test_project_from_file_commented() {
  local dir; dir=$(new_case)
  printf 'project: fromfile  # the project name\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "project from file (commented): exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "project=fromfile" "project from file (commented): resolves project"
}

test_missing_file() {
  local dir; dir=$(new_case)
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "missing file: fails"
  assert_contains "$(cat "$dir/stderr")" "project" "missing file: mentions project"
}

test_no_project_key() {
  local dir; dir=$(new_case)
  printf 'name: something-else\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "no project key: fails"
  assert_contains "$(cat "$dir/stderr")" "project" "no project key: mentions project"
}

test_several_project_keys() {
  local dir; dir=$(new_case)
  printf 'project: one\nproject: two\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "several project keys: fails"
  assert_contains "$(cat "$dir/stderr")" "project" "several project keys: mentions project"
}

test_invalid_project_name() {
  local dir; dir=$(new_case)
  printf 'project: Bad_Name\n' >"$dir/crucible.yml"
  local TAILSCALE_AUDIENCE="aud"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "invalid project name: fails"
  assert_contains "$(cat "$dir/stderr")" "project" "invalid project name: mentions project"
}

### resolve.sh: tailscale credentials #################################

test_both_tailscale_credentials() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" TAILSCALE_OAUTH_SECRET="secret"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "both tailscale credentials: fails"
  assert_contains "$(cat "$dir/stderr")" "tailscale-audience" "both tailscale credentials: names tailscale-audience"
  assert_contains "$(cat "$dir/stderr")" "tailscale-oauth-secret" "both tailscale credentials: names tailscale-oauth-secret"
}

test_neither_tailscale_credential() {
  local dir; dir=$(new_case)
  local PROJECT="demo"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "neither tailscale credential: fails"
  assert_contains "$(cat "$dir/stderr")" "tailscale-audience" "neither tailscale credential: names tailscale-audience"
  assert_contains "$(cat "$dir/stderr")" "tailscale-oauth-secret" "neither tailscale credential: names tailscale-oauth-secret"
}

### resolve.sh: asset mapping #########################################

test_asset_linux_amd64() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" RUNNER_OS="Linux" RUNNER_ARCH="X64"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "asset mapping Linux/X64: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "asset=crucible-linux-amd64" "asset mapping Linux/X64: resolves asset"
}

test_asset_linux_arm64() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" RUNNER_OS="Linux" RUNNER_ARCH="ARM64"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "asset mapping Linux/ARM64: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "asset=crucible-linux-arm64" "asset mapping Linux/ARM64: resolves asset"
}

test_asset_macos_arm64() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "asset mapping macOS/ARM64: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "asset=crucible-darwin-arm64" "asset mapping macOS/ARM64: resolves asset"
}

test_asset_unsupported() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" RUNNER_OS="Windows" RUNNER_ARCH="X64"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "asset mapping unsupported: fails"
  assert_contains "$(cat "$dir/stderr")" "unsupported" "asset mapping unsupported: says unsupported"
}

### resolve.sh: version normalization #################################

test_version_latest() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" CRUCIBLE_VERSION="latest"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "version latest: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "release=latest" "version latest: stays latest"
}

test_version_bare_semver() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" CRUCIBLE_VERSION="0.8.0"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "version 0.8.0: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "release=v0.8.0" "version 0.8.0: normalizes to v0.8.0"
}

test_version_v_semver() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" CRUCIBLE_VERSION="v0.8.0"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "0" "version v0.8.0: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "release=v0.8.0" "version v0.8.0: stays v0.8.0"
}

test_version_invalid() {
  local dir; dir=$(new_case)
  local PROJECT="demo" TAILSCALE_AUDIENCE="aud" CRUCIBLE_VERSION="not-a-version"
  run_resolve "$dir"
  assert_eq "$(cat "$dir/status")" "1" "version invalid: fails"
  assert_contains "$(cat "$dir/stderr")" "crucible-version" "version invalid: names crucible-version"
}

### download.sh ########################################################

setup_download_fixtures() {
  local dir="$1" asset="$2" good_content="$3"
  mkdir -p "$dir/fixtures"
  printf '%s' "$good_content" >"$dir/fixtures/$asset"
  fixture_sha256sums "$dir/fixtures" >"$dir/fixtures/SHA256SUMS"
}

test_download_latest_good_checksum() {
  local dir; dir=$(new_case)
  local asset="crucible-linux-amd64"
  setup_download_fixtures "$dir" "$asset" "dummy-binary-content"
  write_stub "$dir" "gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$GH_STUB_LOG"
dir=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--dir" ]]; then
    dir="$a"
  fi
  prev="$a"
done
mkdir -p "$dir"
cp "$GH_STUB_FIXTURES"/* "$dir"/
EOF
  local ASSET="$asset" RELEASE="latest"
  run_download "$dir"
  assert_eq "$(cat "$dir/status")" "0" "download latest, good checksum: exits 0"
  assert_contains "$(cat "$dir/GITHUB_OUTPUT")" "crucible-path=" "download latest, good checksum: exposes crucible-path"
  local args; args=$(cat "$dir/gh-args.log")
  assert_contains "$args" $'release\ndownload\n--repo' "download latest: passes no tag before --repo"
  assert_not_contains "$args" "latest" "download latest: does not pass 'latest' as a tag"
}

test_download_version_good_checksum() {
  local dir; dir=$(new_case)
  local asset="crucible-linux-amd64"
  setup_download_fixtures "$dir" "$asset" "dummy-binary-content"
  write_stub "$dir" "gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$GH_STUB_LOG"
dir=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--dir" ]]; then
    dir="$a"
  fi
  prev="$a"
done
mkdir -p "$dir"
cp "$GH_STUB_FIXTURES"/* "$dir"/
EOF
  local ASSET="$asset" RELEASE="v0.8.0"
  run_download "$dir"
  assert_eq "$(cat "$dir/status")" "0" "download v0.8.0, good checksum: exits 0"
  local args; args=$(cat "$dir/gh-args.log")
  assert_contains "$args" $'release\ndownload\nv0.8.0\n--repo' "download v0.8.0: passes v0.8.0 as the tag"
}

test_download_checksum_mismatch() {
  local dir; dir=$(new_case)
  local asset="crucible-linux-amd64"
  mkdir -p "$dir/fixtures"
  printf '%s' "dummy-binary-content" >"$dir/fixtures/$asset"
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$asset" >"$dir/fixtures/SHA256SUMS"
  write_stub "$dir" "gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--dir" ]]; then
    dir="$a"
  fi
  prev="$a"
done
mkdir -p "$dir"
cp "$GH_STUB_FIXTURES"/* "$dir"/
EOF
  local ASSET="$asset" RELEASE="latest"
  run_download "$dir"
  assert_eq "$(cat "$dir/status")" "1" "download checksum mismatch: fails"
}

test_download_asset_missing_from_sums() {
  local dir; dir=$(new_case)
  local asset="crucible-linux-amd64"
  mkdir -p "$dir/fixtures"
  printf '%s' "dummy-binary-content" >"$dir/fixtures/$asset"
  printf '%s  %s\n' "1111111111111111111111111111111111111111111111111111111111111111" "some-other-asset" >"$dir/fixtures/SHA256SUMS"
  write_stub "$dir" "gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--dir" ]]; then
    dir="$a"
  fi
  prev="$a"
done
mkdir -p "$dir"
cp "$GH_STUB_FIXTURES"/* "$dir"/
EOF
  local ASSET="$asset" RELEASE="latest"
  run_download "$dir"
  assert_eq "$(cat "$dir/status")" "1" "download asset missing from SHA256SUMS: fails"
}

### deploy.sh ##########################################################

test_deploy_token_on_stdin_not_argv() {
  local dir; dir=$(new_case)
  write_stub "$dir" "tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ip" ]]; then
  echo "100.64.0.5"
  exit 0
fi
exit 1
EOF
  write_stub "$dir" "crucible" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "version" ]]; then
  echo "crucible test (protocol 1) machine=\${CRUCIBLE_MACHINE:-}"
  exit 0
fi
if [[ "\${1:-}" == "deploy" ]]; then
  printf '%s\n' "\$@" >"$dir/crucible-argv.log"
  cat >"$dir/crucible-stdin.log"
  exit 0
fi
exit 1
EOF
  local REGISTRY_TOKEN="s3cr3t-token" TAG="abc123"
  run_deploy "$dir"
  assert_eq "$(cat "$dir/status")" "0" "deploy: exits 0"
  assert_contains "$(cat "$dir/stdout")" "machine=100.64.0.5" "deploy: sets CRUCIBLE_MACHINE from tailscale ip"
  assert_eq "$(cat "$dir/crucible-stdin.log")" "s3cr3t-token" "deploy: passes token on stdin"
  assert_not_contains "$(cat "$dir/crucible-argv.log")" "s3cr3t-token" "deploy: never passes token in argv"
}

test_deploy_propagates_failure() {
  local dir; dir=$(new_case)
  write_stub "$dir" "tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ip" ]]; then
  echo "100.64.0.5"
  exit 0
fi
exit 1
EOF
  write_stub "$dir" "crucible" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  echo "crucible test (protocol 1)"
  exit 0
fi
if [[ "${1:-}" == "deploy" ]]; then
  cat >/dev/null
  exit 1
fi
exit 1
EOF
  run_deploy "$dir"
  assert_eq "$(cat "$dir/status")" "1" "deploy: propagates crucible deploy failure"
}

test_deploy_tailscale_ip_failure() {
  local dir; dir=$(new_case)
  write_stub "$dir" "tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ip" ]]; then
  echo "stub: no such machine" >&2
  exit 1
fi
exit 1
EOF
  write_stub "$dir" "crucible" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  run_deploy "$dir"
  assert_eq "$(cat "$dir/status")" "1" "deploy: tailscale ip failure fails the step"
  assert_contains "$(cat "$dir/stderr")" "tag:ci-" "deploy: tailscale ip failure names the policy hint"
}

### main ###############################################################

main() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$t"
  done

  echo
  if [[ "$FAILED" -eq 0 ]]; then
    echo "all tests passed"
    exit 0
  else
    echo "$FAILED assertion(s) failed"
    exit 1
  fi
}

main
