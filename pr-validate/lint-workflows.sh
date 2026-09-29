#!/usr/bin/env bash
# Download a pinned actionlint binary and lint the workspace. Missing binary is fatal.
set -euo pipefail

version="${ACTIONLINT_VERSION:-v1.7.12}"
# SHA-256 of actionlint_1.7.12_linux_amd64.tar.gz from actionlint_1.7.12_checksums.txt.
# Bump this with the version. The tag can move; the asset checksum cannot.
expected_sha256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
config="${ACTIONLINT_CONFIG:?ACTIONLINT_CONFIG is required}"
workspace="${ACTIONLINT_WORKSPACE:-${GITHUB_WORKSPACE:-.}}"

if [[ ! -f "$config" ]]; then
  echo "::error title=actionlint config missing::${config}"
  exit 1
fi

# ubuntu-24.04 runners only. Other OS/arch combinations fail instead of skipping the lint.
os="$(uname -s)"
arch="$(uname -m)"
if [[ "$os" != "Linux" || "$arch" != "x86_64" ]]; then
  echo "::error title=actionlint unsupported runner::Linux x86_64 is required (got ${os}/${arch})"
  exit 1
fi

version_num="${version#v}"
url="https://github.com/rhysd/actionlint/releases/download/${version}/actionlint_${version_num}_linux_amd64.tar.gz"
bindir="$(mktemp -d)"
archive="$(mktemp)"
trap 'rm -rf "$bindir" "$archive"' EXIT

if ! curl -fsSL "$url" -o "$archive"; then
  echo "::error title=actionlint download failed::Failed to download actionlint ${version}"
  exit 1
fi

if ! printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check --status; then
  echo "::error title=actionlint checksum failed::Checksum mismatch for actionlint ${version}"
  exit 1
fi

if ! tar -xzf "$archive" -C "$bindir" actionlint; then
  echo "::error title=actionlint extract failed::Failed to extract actionlint ${version}"
  exit 1
fi

bin="${bindir}/actionlint"
if [[ ! -x "$bin" ]]; then
  echo "::error title=actionlint missing::actionlint binary not found after download"
  exit 1
fi

cd "$workspace"
shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
if (( ${#workflow_files[@]} == 0 )); then
  echo "::error title=actionlint workflows missing::No workflow files found in ${workspace}/.github/workflows"
  exit 1
fi
# Pass paths explicitly. With no arguments, actionlint walks up looking for a Git
# checkout and exits before reading the files when the workspace is not a repo.
out="${RUNNER_TEMP:-/tmp}/pr-validate-actionlint-out"
"$bin" -config-file "$config" "${workflow_files[@]}" | tee "$out"
