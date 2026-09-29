#!/usr/bin/env bash
# Download a pinned actionlint binary and lint the workspace. Missing binary is fatal.
set -euo pipefail

version="${ACTIONLINT_VERSION:-v1.7.12}"
config="${ACTIONLINT_CONFIG:?ACTIONLINT_CONFIG is required}"
workspace="${ACTIONLINT_WORKSPACE:-${GITHUB_WORKSPACE:-.}}"

if [[ ! -f "$config" ]]; then
  echo "::error title=actionlint config missing::${config}"
  exit 1
fi

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
# The lint-failure workflow checks this so a checkout error cannot pass as a lint failure.
touch "${RUNNER_TEMP:-/tmp}/pr-validate-actionlint-ran"
"$bin" -config-file "$config"
