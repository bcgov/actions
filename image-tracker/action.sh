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

# ---- Inputs & Auto-Detection -----------------------------------------------
# 1. Repository: Detect from git remote if not provided
if [[ -z "${REPOSITORY:-${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}}" ]]; then
    remote_url=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$remote_url" == *"github.com"* ]]; then
        # Parse owner/repo and strip .git
        REPOSITORY=$(printf '%s' "$remote_url" | sed -E 's|.*github.com[:/]([^/]+/[^/.]+).*|\1|')
    fi
fi
REPOSITORY="${REPOSITORY:-${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}}"

# 2. Packages: Use positional arguments if provided, else fall back to env/inputs
if [[ $# -gt 0 ]]; then
    PACKAGE_INPUT=$(IFS=,; echo "$*")
else
    PACKAGE_INPUT="${PACKAGE:-${INPUT_PACKAGE:-}}"
fi

# 3. Other Settings
REVISION="${REVISION:-${INPUT_REVISION:-HEAD}}"
DIR="${DIR:-${INPUT_DIR:-.}}"
TOKEN="${TOKEN:-${INPUT_TOKEN:-${GITHUB_TOKEN:-}}}"
MAX_TAGS="${MAX_TAGS:-${INPUT_MAX_TAGS:-500}}"
MAX_DEPTH="${MAX_DEPTH:-${INPUT_MAX_DEPTH:-1}}"

# ---- Validation ------------------------------------------------------------
if [[ ! "$MAX_TAGS" =~ ^[0-9]+$ ]] || [[ "$MAX_TAGS" -le 0 ]]; then
    log_error "MAX_TAGS must be a positive integer."
    exit 1
fi
if [[ ! "$MAX_DEPTH" =~ ^[0-9]+$ ]] || [[ "$MAX_DEPTH" -le 0 ]]; then
    log_error "MAX_DEPTH must be a positive integer."
    exit 1
fi
if [[ -z "$PACKAGE_INPUT" ]]; then
    log_error "Missing required package names. Usage: $0 pkg1 [pkg2 ...]"
    exit 1
fi
# No hard exit here; we attempt anonymous access in registry_token()
if [[ -z "$REPOSITORY" ]]; then
    log_error "No repository detected. Set REPOSITORY or run from a git repo."
    exit 1
fi

if [[ ! -d "$DIR" ]]; then
    log_error "Invalid directory '$DIR'."
    exit 1
fi
cd "$DIR"

# ---- State -----------------------------------------------------------------
declare -A PR_MAP
declare -A PR_NUM_MAP
declare -A PR_TITLE_MAP
declare -A CANDIDATE_MAP
declare -A IMAGE_PATHS
declare -A IMAGES
declare -a MISSING
declare -a PKG_ORDER

# ---- Git Ancestry Resolution -----------------------------------------------
PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)

if [[ -z "$PIVOT_SHA" && "$REVISION" =~ ^[0-9a-f]{7,40}$ ]]; then
    log_info "Revision $REVISION not found locally. Checking for PR metadata..."
    pr_data=$(GITHUB_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${REVISION}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
    
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
    # Extract (#123) or (#123) followed by anything
    pr_from_msg=$(printf '%s' "$msg" | grep -oE '\(#[0-9]+\)' | grep -oE '[0-9]+' | head -1 || true)
    
    if [[ -n "$pr_from_msg" ]]; then
        [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Mapped %s to PR #%s (from msg)\n" "${sha:0:7}" "$pr_from_msg" >&2
        PR_NUM_MAP["$sha"]="$pr_from_msg"
    fi
    
    # Optional: fetch full metadata from API if needed for titles
    if command -v gh &>/dev/null; then
        pr_data=""
        if [[ -n "$TOKEN" ]]; then
            pr_data=$(GITHUB_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${sha}/pulls" --jq '.[] | [.head.sha, .number, .title] | @tsv' 2>/dev/null | head -1 || true)
        fi
        
        if [[ -n "$pr_data" ]]; then
             { IFS=$'\t' read -r head_sha pr_num_api pr_title; } <<< "$pr_data"
             if [[ -n "$pr_num_api" && "$pr_num_api" != "null" ]]; then
                 [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Mapped %s to PR #%s (from API)\n" "${sha:0:7}" "$pr_num_api" >&2
                 PR_NUM_MAP["$sha"]="$pr_num_api"
                 PR_TITLE_MAP["$sha"]="$pr_title"
                 if [[ -n "$head_sha" && "$head_sha" != "null" ]]; then
                     PR_MAP["$sha"]="$head_sha"
                     PR_NUM_MAP["$head_sha"]="$pr_num_api"
                     PR_TITLE_MAP["$head_sha"]="$pr_title"
                 fi
             fi
        fi
    fi
done

# ---- Registry Logic --------------------------------------------------------
repo_name="${REPOSITORY#*/}"
lc_repo="${REPOSITORY,,}"
# ---- Map package names to GHCR image paths ---------------------------------
# Normalize separators: turn commas and whitespace into newlines
package_list=$(echo "$PACKAGE_INPUT" | tr ',' '\n' | tr -s '[:space:]' '\n')
while IFS= read -r pkg; do
    pkg="${pkg//[[:space:]]/}"
    [[ -z "$pkg" ]] && continue
    if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
        IMAGE_PATHS["$pkg"]="${lc_repo}"
    else
        IMAGE_PATHS["$pkg"]="${lc_repo}/${pkg,,}"
    fi
    PKG_ORDER+=("$pkg")
done <<< "$package_list"

if [[ ${#PKG_ORDER[@]} -eq 0 ]]; then
    log_error "PACKAGE_INPUT did not contain any valid package names."
    exit 1
fi

registry_token() {
    local repo="$1"
    if [[ -n "${TOKEN:-}" ]]; then
        curl -sS -u "x:${TOKEN}" "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r '.token'
    else
        curl -sS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r '.token'
    fi
}

matches_candidate() {
    local rev="$1"
    local tag="${2:-}"
    [[ -z "$rev" ]] && return 1
    
    for cand in "${!CANDIDATE_MAP[@]}"; do
        # 1. Direct SHA match
        if [[ "$cand" == "$rev"* ]] || [[ "$rev" == "$cand"* ]]; then
            [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (SHA): %s == %s\n" "$cand" "$rev" >&2
            return 0
        fi
        
        # 2. PR Head match (API-dependent)
        local ph="${PR_MAP[$cand]:-}"
        if [[ -n "$ph" ]] && { [[ "$ph" == "$rev"* ]] || [[ "$rev" == "$ph"* ]]; }; then
            [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Head): %s maps to %s\n" "$cand" "$ph" >&2
            return 0
        fi
        
        # 3. PR Number match (The bridge)
        local pn="${PR_NUM_MAP[$cand]:-}"
        if [[ -n "$pn" ]]; then
            # Match if the revision label itself is the PR tag
            if [[ "$rev" == "pr-$pn" ]]; then
                [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Label): %s maps to pr-%s\n" "$cand" "$pn" >&2
                return 0
            fi
            # Match if the tag we are probing is the PR tag
            if [[ "$tag" == "pr-$pn" ]]; then
                [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Tag Bridge): %s matches tag pr-%s\n" "$cand" "$pn" >&2
                return 0
            fi
        fi
    done
    return 1
}

probe_tag() {
    local image_path="$1" tag="$2" bearer="$3"
    local base="https://ghcr.io/v2/${image_path}"
    local accept="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, */*"
    
    local hfile
    hfile=$(mktemp)
    local mbody mdigest mtype
    
    mbody=$(curl -sS -L -D "$hfile" -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept}" "${base}/manifests/${tag}")
    mdigest=$(grep -iE '^docker-content-digest:' "$hfile" | tail -1 | awk '{print $2}' | tr -d '\r')
    mtype=$(printf '%s' "$mbody" | jq -r '.mediaType // empty' 2>/dev/null || true)
    
    # Fallback to body digest if not in headers
    [[ -z "$mdigest" ]] && mdigest=$(printf '%s' "$mbody" | jq -r '.digest // empty' 2>/dev/null || true)
    
    if [[ -z "$mdigest" || "$mdigest" == "null" ]]; then
        rm -f "$hfile"
        return 1
    fi
    
    # Extract metadata (OCI Annotations)
    local revision created
    revision=$(printf '%s' "$mbody" | jq -r '.annotations["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
    created=$(printf '%s' "$mbody" | jq -r '.annotations["org.opencontainers.image.created"] // empty' 2>/dev/null || true)

    # Multi-arch Index Navigation
    if [[ "$mtype" == *"index"* || "$mtype" == *"manifest.list"* ]]; then
        local cd
        cd=$(printf '%s' "$mbody" | jq -r '.manifests[] | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown") | .digest' 2>/dev/null | head -1)
        [[ -z "$cd" ]] && cd=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
        if [[ -n "$cd" ]]; then
            mbody=$(curl -sS -L -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept}" "${base}/manifests/${cd}")
            [[ -z "$revision" || "$revision" == "null" ]] && revision=$(printf '%s' "$mbody" | jq -r '.annotations["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
            [[ -z "$created" || "$created" == "null" ]] && created=$(printf '%s' "$mbody" | jq -r '.annotations["org.opencontainers.image.created"] // empty' 2>/dev/null || true)
        fi
    fi

    # Config Blob Fallback
    if [[ -z "$revision" || "$revision" == "null" ]]; then
        local cd_final
        cd_final=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
        if [[ -n "$cd_final" ]]; then
            local config
            config=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${cd_final}")
            revision=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
            [[ -z "$created" || "$created" == "null" ]] && created=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.created"] // empty' 2>/dev/null || true)
        fi
    fi
    
    rm -f "$hfile"
    if matches_candidate "$revision" "$tag"; then
        for cand in "${!CANDIDATE_MAP[@]}"; do
             local ph="${PR_MAP[$cand]:-}"
             local pn="${PR_NUM_MAP[$cand]:-}"
             if [[ -z "$pn" ]]; then
                 if [[ "$tag" =~ ^pr-([0-9]+)$ ]]; then
                     pn="${BASH_REMATCH[1]}"
                 elif [[ "$tag" =~ ^[0-9]+$ ]]; then
                     pn="$tag"
                 fi
             fi
             
             # Decoupled decision: does the revision label match OR does the tag follow a known pattern?
             local pattern_match=false
             if [[ "$tag" == "sha-${cand:0:7}" || "$tag" == "pr-$pn" || ( -n "$ph" && "$tag" == "sha-${ph:0:7}" ) ]]; then
                 pattern_match=true
             fi

             if [[ "$revision" == "$cand"* || ( -n "$ph" && "$revision" == "$ph"* ) || "$pattern_match" == "true" ]]; then
                 local title="${PR_TITLE_MAP[$cand]:-}"
                 [[ -z "$title" || "$title" == "null" ]] && title=$(git log -1 --format=%s "$cand" 2>/dev/null || echo "Unknown commit message")
                 
                 local display_ref="$tag"
                 if [[ "$tag" == "sha-${cand:0:7}" || "$tag" == "pr-$pn" || ( -n "$ph" && "$tag" == "sha-${ph:0:7}" ) ]]; then
                     display_ref="$tag"
                 fi

                 # 1. Stderr for human logs
                 local audit_msg="[✓] HIT: $display_ref ($mdigest)"
                 [[ -n "$pn" ]] && audit_msg+=" | PR #$pn"
                 [[ -n "$title" ]] && audit_msg+=": $title"
                 [[ -n "$created" ]] && audit_msg+=" | Built: $created"
                 log_info "$audit_msg"
                 
                 # 2. Stdout for machine-readable pipe-delimited payload
                 printf '%s|%s|%s|%s|%s' "$cand" "$mdigest" "$created" "$pn" "$title"
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
    
    local raw_data=""
    if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
        # Fetch both digest (name) and tags for each version
        raw_data=$(GH_TOKEN="$TOKEN" gh api "/orgs/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq 'if length > 0 then .[] | [.name, (.metadata.container.tags | join(","))] | @tsv else empty end' 2>/dev/null || true)
        if [[ -z "$raw_data" ]]; then
            raw_data=$(GH_TOKEN="$TOKEN" gh api "/users/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq 'if length > 0 then .[] | [.name, (.metadata.container.tags | join(","))] | @tsv else empty end' 2>/dev/null || true)
        fi
    fi
    
    local tags_seen=0
    if [[ -n "$raw_data" ]]; then
        while IFS=$'\t' read -r digest tags; do
            [[ -z "$digest" ]] && continue
            tags_seen=$((tags_seen + 1))
            [[ "$tags_seen" -gt "$MAX_TAGS" ]] && return 2
            
            printf "\r      -> [%d/%d] Inspecting digest: %s... \033[K" "$tags_seen" "$MAX_TAGS" "${digest:0:15}" >&2
            
            # Use the most relevant tag from the list for probing (e.g. pr-N or N if it exists)
            local probe_ref="$digest"
            IFS=',' read -ra tag_arr <<< "$tags"
            for t in "${tag_arr[@]}"; do
                if [[ "$t" =~ ^(pr-)?[0-9]+$ ]]; then
                    probe_ref="$t"
                    break
                fi
            done

            local res
            res=$(probe_tag "$image_path" "$probe_ref" "$bearer" || true)
            if [[ -n "$res" ]]; then echo -ne "\r\033[K" >&2; echo "$res"; return 0; fi
        done <<< "$raw_data"
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
    res=""
    # 1. Forensic Trace (Primary)
    for candidate in "${CANDIDATES[@]}"; do
        pr_head="${PR_MAP[$candidate]:-}"
        pr_num="${PR_NUM_MAP[$candidate]:-}"
        
        # 1. Explicit PR Tag Probe (from commit message/API)
        if [[ -n "$pr_num" ]]; then
            res=$(probe_tag "$path" "pr-${pr_num}" "$bearer" || true)
            [[ -z "$res" ]] && res=$(probe_tag "$path" "${pr_num}" "$bearer" || true)
        fi
        
        # 2. PR Head SHA Probe (API-dependent)
        if [[ -z "$res" && -n "$pr_head" ]]; then
            res=$(probe_tag "$path" "sha-${pr_head:0:7}" "$bearer" || true)
        fi
        
        # 3. Direct Commit SHA Probe
        if [[ -z "$res" ]]; then
            res=$(probe_tag "$path" "sha-${candidate:0:7}" "$bearer" || true)
        fi
        
        if [[ -n "$res" ]]; then
            break
        fi
    done

    if [[ -z "$res" ]]; then
        log_info "Forensic trace missed; falling back to iterative scan..."
        if res=$(resolve_digest "$path" "$bearer"); then
             :
        else
             rc=$?
             if [[ $rc -eq 2 ]]; then
                 log_error "Iterative scan stopped for $path because MAX_TAGS ($MAX_TAGS) was exceeded. Increase MAX_TAGS to continue."
                 exit 2
             fi
             res=""
        fi
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
    
    IMAGES["$pkg"]="$res"
    IMAGES_JSON=$(printf '%s' "$IMAGES_JSON" | jq -c --arg k "$pkg" --arg v "$ref" '.[$k] = $v')
done

log_endgroup

# Output results
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf "images=%s\n" "$IMAGES_JSON" >> "$GITHUB_OUTPUT"
    
    # Restore legacy outputs for backward compatibility
    # If multiple packages, these will represent the FIRST one (legacy behavior)
    first_pkg="${PKG_ORDER[0]:-}"
    r_pr=""
    if [[ -n "$first_pkg" ]]; then
        first_payload="${IMAGES["$first_pkg"]:-}"
        if [[ -n "$first_payload" ]]; then
            { IFS='|' read -r _ r_digest _ p_pr _; } <<< "$first_payload"
            f_path="${IMAGE_PATHS["$first_pkg"]:-}"
            printf "image=ghcr.io/%s@%s\n" "$f_path" "$r_digest" >> "$GITHUB_OUTPUT"
            printf "digest=%s\n" "$r_digest" >> "$GITHUB_OUTPUT"
            if [[ -n "$p_pr" && "$p_pr" != "null" ]]; then
                r_pr="$p_pr"
            fi
            
            # JSON map of digests only
            DIGESTS_JSON=$(printf '%s' "$IMAGES_JSON" | jq -c 'map_values(split("@")[1])')
            printf "digests=%s\n" "$DIGESTS_JSON" >> "$GITHUB_OUTPUT"
        fi
    fi
    printf "pr=%s\n" "$r_pr" >> "$GITHUB_OUTPUT"
else
    printf "\n--- Results ---\n%s\n" "$IMAGES_JSON"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_error "Failed to resolve: ${MISSING[*]}"
    exit 1
fi
