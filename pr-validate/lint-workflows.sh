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

# caller_runner_labels FILE: print the self-hosted-runner labels in a caller's
# actionlint config, one per line. Handles block (- label) and flow ([a, b]) lists.
caller_runner_labels() {
  awk '
    function emit(v) {
      gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", v)
      if (v != "") print v
    }
    /^[^[:space:]#]/ { in_runner = ($0 ~ /^self-hosted-runner:/); in_labels = 0; next }
    in_runner && /^[[:space:]]+labels:/ {
      v = $0; sub(/^[^:]*:/, "", v); sub(/[[:space:]]#.*$/, "", v)
      if (v ~ /\[/) {
        gsub(/[][]/, "", v); n = split(v, items, ",")
        for (i = 1; i <= n; i++) emit(items[i])
      } else {
        in_labels = 1
      }
      next
    }
    in_labels && /^[[:space:]]*-/ { v = $0; sub(/^[[:space:]]*-/, "", v); sub(/[[:space:]]#.*$/, "", v); emit(v); next }
    in_labels && /^[[:space:]]*(#.*)?$/ { next }
    in_labels { in_labels = 0 }
  ' "$1"
}

# A caller's .github/actionlint.yaml (or .yml) adds its self-hosted-runner labels to
# the bundled config. Only the labels are read; its other settings are not used.
for caller_config in .github/actionlint.yaml .github/actionlint.yml; do
  [[ -f "$caller_config" ]] || continue
  merged="${RUNNER_TEMP:-/tmp}/pr-validate-actionlint.yaml"
  extra=""
  # Single-quoted YAML keeps glob patterns (private-linux-*) and other characters literal.
  while IFS= read -r label; do
    extra+="    - '${label//\'/\'\'}'"$'\n'
  done < <(caller_runner_labels "$caller_config")
  awk -v extra="$extra" '{ print } /^  labels:$/ { printf "%s", extra }' "$config" > "$merged"
  config="$merged"
  echo "Runner labels from ${caller_config}: $(printf '%s' "$extra" | sed 's/^ *- //' | paste -sd' ' -)"
  break
done

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
