#!/usr/bin/env bash
# Image Tracker — Digest-via-OCI-label resolver (Standalone CLI + GitHub Action)
#
# Usage:
#   REPOSITORY=org/repo PACKAGE=pkg1,pkg2 ./action.sh
#
# Inputs (Env Vars):
#   PACKAGE/INPUT_PACKAGE: Comma-separated package names
#   REVISION/INPUT_REVISION: Git ref (default: HEAD)
#   REPOSITORY/INPUT_REPOSITORY: Target repo (default: GITHUB_REPOSITORY)
#   DIR/INPUT_DIR: Working directory (default: .)
#   TOKEN/INPUT_TOKEN: GitHub Token (default: GITHUB_TOKEN)
#   MAX_TAGS/INPUT_MAX_TAGS: Max registry tags to scan (default: 500)
#   MAX_DEPTH/INPUT_MAX_DEPTH: Max git depth to walk (default: 1)

set -euo pipefail

# ---- Logging Helpers -------------------------------------------------------
log_error() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf "::error::%s\n" "$1"
    else
        printf "\e[31m[ERROR]\e[0m %s\n" "$1" >&2
    fi
}
log_warn() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf "::warning::%s\n" "$1"
    else
        printf "\e[33m[WARN]\e[0m %s\n" "$1" >&2
    fi
}
log_info() {
    printf "  [i] %s\n" "$1" >&2
}
log_group() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf "::group::%s\n" "$1"
    else
        printf "\n\e[1m--- %s ---\e[0m\n" "$1" >&2
    fi
}
log_endgroup() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf "::endgroup::\n"
    fi
}

# ---- Inputs & Defaults -----------------------------------------------------
PACKAGE_INPUT="${INPUT_PACKAGE:-${PACKAGE:-}}"
REVISION="${INPUT_REVISION:-${REVISION:-HEAD}}"
REPOSITORY="${INPUT_REPOSITORY:-${REPOSITORY:-${GITHUB_REPOSITORY:-}}}"
DIR="${INPUT_DIR:-${DIR:-.}}"
TOKEN="${INPUT_TOKEN:-${GITHUB_TOKEN:-}}"
MAX_TAGS="${INPUT_MAX_TAGS:-${MAX_TAGS:-500}}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-${MAX_DEPTH:-20}}"

# ---- Validation ------------------------------------------------------------
if [[ -z "$PACKAGE_INPUT" ]]; then
    log_error "Missing required input 'package'. Set PACKAGE or INPUT_PACKAGE."
    exit 1
fi
if [[ -z "$TOKEN" ]]; then
    log_error "No token available. Set TOKEN or GITHUB_TOKEN."
    exit 1
fi
if [[ -z "$REPOSITORY" ]]; then
    log_error "No repository available. Set REPOSITORY or GITHUB_REPOSITORY."
    exit 1
fi

if ! cd "$DIR"; then
    log_error "Invalid directory '$DIR'."
    exit 1
fi

# ---- State -----------------------------------------------------------------
declare -A PR_MAP
declare -A PR_NUM_MAP
declare -A PR_TITLE_MAP
declare -A CANDIDATE_MAP
declare -A IMAGE_PATHS
declare -a PKG_ORDER

# ---- Git Ancestry Resolution -----------------------------------------------
PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)

if [[ -z "$PIVOT_SHA" && "$REVISION" =~ ^[0-9a-f]{7,40}$ ]]; then
    log_info "Revision $REVISION not found locally. Checking for PR metadata..."
    pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${REVISION}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
    
    if [[ -n "$pr_data" ]]; then
        { IFS=$'\t' read -r head_sha pr_num pr_title; } <<< "$pr_data"
        log_info "Revision matches PR #$pr_num. Fetching ref..."
        git fetch origin "pull/${pr_num}/head:refs/remotes/origin/pr/${pr_num}" --quiet || true
        PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)
        if [[ -n "$PIVOT_SHA" ]]; then
            PR_TITLE_MAP["$PIVOT_SHA"]="$pr_title"
            [[ -n "$head_sha" && "$head_sha" != "null" ]] && PR_TITLE_MAP["$head_sha"]="$pr_title"
        fi
    fi
fi

if [[ -z "$PIVOT_SHA" ]]; then
    log_error "Could not resolve git revision '$REVISION'."
    exit 1
fi

mapfile -t CANDIDATES < <(git rev-list --topo-order -n "$MAX_DEPTH" "$PIVOT_SHA")

# Populate PR metadata for candidates
for sha in "${CANDIDATES[@]}"; do
    CANDIDATE_MAP["$sha"]=1
    msg=$(git log -1 --format=%s "$sha" 2>/dev/null || true)
    # Extract (#123) with potential trailing whitespace
    pr_num=$(printf '%s' "$msg" | grep -oE '\(#[0-9]+\)\s*$' | grep -oE '[0-9]+' || true)
    if [[ -n "$pr_num" ]]; then
        PR_NUM_MAP["$sha"]="$pr_num"
    fi
    
    # Optional: fetch full metadata from API if needed for titles
    # (Skip if you want speed, but we use it for the audit trail)
    if [[ -n "$pr_num" && -z "${PR_TITLE_MAP[$sha]:-}" ]]; then
        pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${sha}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
        if [[ -n "$pr_data" ]]; then
             { IFS=$'\t' read -r head_sha pr_num_api pr_title; } <<< "$pr_data"
             if [[ -n "$head_sha" && "$head_sha" != "null" ]]; then
                 PR_MAP["$sha"]="$head_sha"
                 PR_NUM_MAP["$sha"]="$pr_num_api"
                 PR_NUM_MAP["$head_sha"]="$pr_num_api"
                 PR_TITLE_MAP["$sha"]="$pr_title"
                 PR_TITLE_MAP["$head_sha"]="$pr_title"
             fi
        fi
    fi
done

# ---- Registry Logic --------------------------------------------------------
repo_name="${REPOSITORY#*/}"
lc_repo="${REPOSITORY,,}"
while IFS= read -r pkg; do
    pkg="${pkg//[[:space:]]/}"
    [[ -z "$pkg" ]] && continue
    if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
        IMAGE_PATHS["$pkg"]="${lc_repo}"
    else
        IMAGE_PATHS["$pkg"]="${lc_repo}/${pkg,,}"
    fi
    PKG_ORDER+=("$pkg")
done < <(echo "$PACKAGE_INPUT" | tr ',' '\n' | tr -s '[:space:]' '\n')

registry_token() {
    curl -sS -u "x:${TOKEN}" "https://ghcr.io/token?scope=repository:${1}:pull" | jq -r '.token'
}

matches_candidate() {
    local rev="$1"
    [[ -z "$rev" ]] && return 1
    for cand in "${!CANDIDATE_MAP[@]}"; do
        if [[ "$cand" == "$rev"* ]] || [[ "$rev" == "$cand"* ]]; then return 0; fi
        local ph="${PR_MAP[$cand]:-}"
        if [[ -n "$ph" ]] && { [[ "$ph" == "$rev"* ]] || [[ "$rev" == "$ph"* ]]; }; then return 0; fi
        local pn="${PR_NUM_MAP[$cand]:-}"
        if [[ -n "$pn" && "$rev" == "pr-$pn" ]]; then return 0; fi
    done
    return 1
}

probe_tag() {
    local image_path="$1" tag="$2" bearer="$3"
    local base="https://ghcr.io/v2/${image_path}"
    local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
    
    local mresp mdigest
    mresp=$(curl -sS -i -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept}" "${base}/manifests/${tag}")
    mdigest=$(printf '%s' "$mresp" | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {gsub(/\r/,""); print $2; exit}')
    [[ -z "$mdigest" ]] && return 1

    local mbody=$(printf '%s' "$mresp" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
    local mtype=$(printf '%s' "$mbody" | jq -r '.mediaType // empty' 2>/dev/null || true)
    
    if [[ "$mtype" == *"index"* || "$mtype" == *"manifest.list"* ]]; then
        local cd=$(printf '%s' "$mbody" | jq -r '.manifests[] | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown") | .digest' 2>/dev/null | head -1)
        [[ -z "$cd" ]] && cd=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
        [[ -n "$cd" ]] && mbody=$(curl -sS -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept}" "${base}/manifests/${cd}")
    fi

    local cd_final=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
    [[ -z "$cd_final" ]] && return 1

    local config=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${cd_final}")
    local revision=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
    
    if matches_candidate "$revision"; then
        local created=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.created"] // empty' 2>/dev/null || true)
        for cand in "${!CANDIDATE_MAP[@]}"; do
             local ph="${PR_MAP[$cand]:-}"
             local pn="${PR_NUM_MAP[$cand]:-}"
             if [[ "$cand" == "$revision"* ]] || [[ "$revision" == "$cand"* ]] || \
                [[ -n "$ph" && "$ph" == "$revision"* ]] || [[ -n "$revision" && "$revision" == "$ph"* ]] || \
                [[ -n "$pn" && "$revision" == "pr-$pn" ]]; then
                 local msg="${PR_TITLE_MAP[$cand]:-}"
                 [[ -z "$msg" || "$msg" == "null" ]] && msg=$(git log -1 --format=%s "$cand" 2>/dev/null || echo "Unknown commit message")
                 printf '%s|%s|%s|%s|%s' "$cand" "$mdigest" "$created" "$pn" "$msg"
                 return 0
             fi
        done
    fi
    return 1
}

resolve_digest() {
    local image_path="$1" bearer="$2"
    local owner_orig="${REPOSITORY%%/*}"
    local pkg="${image_path#*/}"
    local pkg_enc="${pkg//\//%2F}"
    
    local digests=""
    digests=$(GH_TOKEN="$TOKEN" gh api "/orgs/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq '.[].name' 2>/dev/null || true)
    [[ -z "$digests" ]] && digests=$(GH_TOKEN="$TOKEN" gh api "/users/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq '.[].name' 2>/dev/null || true)
    
    local tags_seen=0
    if [[ -n "$digests" ]]; then
        while IFS= read -r digest; do
            [[ -z "$digest" ]] && continue
            tags_seen=$((tags_seen + 1))
            [[ "$tags_seen" -gt "$MAX_TAGS" ]] && return 2
            printf "\r      -> [%d/%d] Inspecting digest: %s... \033[K" "$tags_seen" "$MAX_TAGS" "${digest:0:15}" >&2
            local res=$(probe_tag "$image_path" "$digest" "$bearer" || true)
            if [[ -n "$res" ]]; then echo -ne "\r\033[K" >&2; echo "$res"; return 0; fi
        done <<< "$digests"
    fi
    echo -ne "\r\033[K" >&2
    return 1
}

# ---- Execution -------------------------------------------------------------
log_group "Image Tracker — resolving ancestry for $REVISION"
log_info "Repository: $REPOSITORY"
log_info "Starting SHA: $PIVOT_SHA"

IMAGES_JSON='{}'
MISSING=()

for pkg in "${PKG_ORDER[@]}"; do
    path="${IMAGE_PATHS[$pkg]}"
    bearer=$(registry_token "$path" || true)
    if [[ -z "$bearer" || "$bearer" == "null" ]]; then
        log_error "Failed to obtain registry token for $path."
        MISSING+=("$pkg")
        continue
    fi
    
    printf "  [>] Searching ghcr.io/%s for matching ancestry...\n" "$path" >&2
    
    res=""
    for candidate in "${CANDIDATES[@]}"; do
        ph="${PR_MAP[$candidate]:-}"
        pn="${PR_NUM_MAP[$candidate]:-}"
        # 1. PR Head
        [[ -n "$ph" ]] && res=$(probe_tag "$path" "sha-${ph:0:7}" "$bearer" || true)
        # 2. PR Number
        [[ -z "$res" && -n "$pn" ]] && res=$(probe_tag "$path" "pr-${pn}" "$bearer" || true)
        # 3. Commit SHA
        [[ -z "$res" ]] && res=$(probe_tag "$path" "sha-${candidate:0:7}" "$bearer" || true)
        [[ -n "$res" ]] && break
    done

    if [[ -z "$res" ]]; then
        log_info "Forensic trace missed; falling back to iterative scan..."
        res=$(resolve_digest "$path" "$bearer" || true)
    fi

    if [[ -z "$res" ]]; then
        printf "  [x] MISS: %s\n" "$pkg" >&2
        MISSING+=("$pkg")
        continue
    fi

    IFS='|' read -r sha digest created pr_num msg <<< "$res"
    ref="ghcr.io/${path}@${digest}"
    printf "  [✓] HIT: %s -> %s\n" "$pkg" "$ref" >&2
    
    # GitHub Action specific reporting
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        {
            echo "### 📦 Image Tracker: \`${pkg}\`"
            echo "- **Message:** \`${msg}\` $( [[ -n "$pr_num" && "$pr_num" != "null" ]] && echo "(PR #$pr_num)" )"
            echo "- **Digest:** \`${digest}\`"
            echo "- **Image Commit:** \`${sha}\`"
            echo ""
        } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi
    
    IMAGES_JSON=$(printf '%s' "$IMAGES_JSON" | jq -c --arg k "$pkg" --arg v "$ref" '.[$k] = $v')
done

log_endgroup

# Output results
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf "images=%s\n" "$IMAGES_JSON" >> "$GITHUB_OUTPUT"
else
    printf "\n--- Results ---\n%s\n" "$IMAGES_JSON"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_error "Failed to resolve: ${MISSING[*]}"
    exit 1
fi
