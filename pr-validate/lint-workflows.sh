#!/usr/bin/env bash
# Download a pinned actionlint binary and lint the workspace. Missing binary is fatal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Extra runner labels: the runner_labels input (one per line, read with the shared
# list parser), then a caller's .github/actionlint.yaml (or .yml) self-hosted-runner
# labels. Only the caller config's labels are read; its other settings are not used.
# Labels the bundled config already has are skipped, so the default (ubuntu-26.04)
# lints with the bundled config unchanged.
declare -A seen=()
while IFS= read -r label; do
  seen["$label"]=1
done < <(caller_runner_labels "$config")
labels=()
add_labels() { # source label...
  local source="$1" label added=()
  shift
  for label in "$@"; do
    if [[ -n "$label" && -z "${seen[$label]:-}" ]]; then
      seen["$label"]=1
      labels+=("$label")
      added+=("$label")
    fi
  done
  if (( ${#added[@]} > 0 )); then
    echo "Runner labels from ${source}: ${added[*]}"
  fi
}

if ! input_labels="$(node "${here}/../shared/inputs.js" list runner_labels)"; then
  exit 1
fi
mapfile -t input_list <<< "$input_labels"
add_labels runner_labels "${input_list[@]}"

for caller_config in .github/actionlint.yaml .github/actionlint.yml; do
  [[ -f "$caller_config" ]] || continue
  mapfile -t caller_list < <(caller_runner_labels "$caller_config")
  add_labels "$caller_config" "${caller_list[@]}"
  break
done

if (( ${#labels[@]} > 0 )); then
  merged="${RUNNER_TEMP:-/tmp}/pr-validate-actionlint.yaml"
  extra=""
  # Single-quoted YAML keeps glob patterns (private-linux-*) and other characters literal.
  for label in "${labels[@]}"; do
    extra+="    - '${label//\'/\'\'}'"$'\n'
  done
  awk -v extra="$extra" '{ print } /^  labels:$/ { printf "%s", extra }' "$config" > "$merged"
  config="$merged"
fi

# dotglob: hidden files such as .github/workflows/.reusable.yml are workflows too.
shopt -s nullglob dotglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
if (( ${#workflow_files[@]} == 0 )); then
  echo "::error title=actionlint workflows missing::No workflow files found in ${workspace}/.github/workflows"
  exit 1
fi
# Pass paths explicitly. With no arguments, actionlint walks up looking for a Git
# checkout and exits before reading the files when the workspace is not a repo.
out="${RUNNER_TEMP:-/tmp}/pr-validate-actionlint-out"
status=0
"$bin" -config-file "$config" "${workflow_files[@]}" | tee "$out" || status=$?

# Shared list inputs (triggers, packages, tags, keep_digests) take one item per
# line or a single value. actionlint cannot check input formats, so flag other
# formats passed to bcgov/actions* with the same parser the actions use.
if ! node "${here}/list-inputs.js" "${workflow_files[@]}"; then
  status=1
fi
exit "$status"
