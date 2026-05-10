#!/usr/bin/env bash
# Image Tracker — Digest-via-OCI-label resolver
#
# Given a git commit SHA and a GHCR repository, find image manifests whose
# `org.opencontainers.image.revision` OCI label matches the commit, and
# return their immutable manifest digests.
#
# This is format-agnostic: the tag name (`sha-<7>`, `pr-N`, `latest`, whatever)
# is irrelevant. What matters is the label embedded in the image at build time,
# which `docker/metadata-action` sets by default.

set -euo pipefail

# ---- Inputs ----------------------------------------------------------------
PACKAGE_INPUT="${INPUT_PACKAGE:-}"
REVISION="${INPUT_REVISION:-HEAD}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"
DIR="${INPUT_DIR:-.}"
TOKEN="${INPUT_TOKEN:-${GITHUB_TOKEN:-}}"
MAX_TAGS="${INPUT_MAX_TAGS:-500}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-1}"

# ---- Input Validation ------------------------------------------------------
if [[ -z "$PACKAGE_INPUT" ]]; then
    echo "::error::Missing required input 'package'."
    exit 1
fi
if [[ -z "$TOKEN" ]]; then
    echo "::error::No token available. Pass 'token' input or set GITHUB_TOKEN."
    exit 1
fi

if [[ ! "$MAX_TAGS" =~ ^[0-9]+$ ]]; then
    echo "::error::Invalid input 'max_tags': must be a positive integer."
    exit 1
fi
if [[ ! "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
    echo "::error::Invalid input 'max_depth': must be a positive integer."
    exit 1
fi

if ! cd "$DIR"; then
    echo "::error::Invalid input 'dir': unable to change to directory '$DIR'."
    exit 1
fi

# Batch-fetch closed PR data: merge_commit_sha -> head_sha
# This allows us to resolve images built from PR heads that were squash-merged.
# We also use this to aid in resolution of missing commits (e.g. from forks).
declare -A PR_MAP
declare -A PR_NUM_MAP
if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
    echo "  [i] Batch-fetching PR merge map..."
    while IFS=$'\t' read -r merge_sha head_sha pr_num; do
        if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
            [[ -n "$merge_sha" && "$merge_sha" != "null" ]] && PR_MAP["$merge_sha"]="$head_sha"
            [[ -n "$merge_sha" && "$merge_sha" != "null" ]] && PR_NUM_MAP["$merge_sha"]="$pr_num"
            [[ -n "$head_sha" && "$head_sha" != "null" ]] && PR_NUM_MAP["$head_sha"]="$pr_num"
        fi
    done < <(GH_TOKEN="$TOKEN" gh api --paginate "/repos/${REPOSITORY}/pulls?state=all&per_page=100" \
        --jq '.[] | [.merge_commit_sha, .head.sha, .number] | @tsv' 2>/dev/null || true)
    echo "  [i] PR Map populated with ${#PR_MAP[@]} entries."
fi

# Get the "pivot" commit (the starting point for history walking)
PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)

# If the pivot is missing and looks like a SHA, check if it's a known PR head
if [[ -z "$PIVOT_SHA" && "$REVISION" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "  [w] Revision $REVISION not found in local history. Checking PR map..."
    matched_pr=""
    for key in "${!PR_NUM_MAP[@]}"; do
        if [[ "$key" == "$REVISION"* ]]; then
            matched_pr="${PR_NUM_MAP[$key]}"
            break
        fi
    done
    
    if [[ -n "$matched_pr" ]]; then
        echo "  [i] Revision matches head of PR #$matched_pr. Attempting to fetch PR ref..."
        git fetch origin "pull/${matched_pr}/head:refs/remotes/origin/pr/${matched_pr}" --quiet || true
        PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)
    fi
fi

if [[ -z "$PIVOT_SHA" ]]; then
    echo "::error::Could not resolve git revision '$REVISION' in '$DIR'."
    echo "  [d] Current branch: $(git branch --show-current || echo 'DETACHED')"
    echo "  [d] HEAD:           $(git rev-parse HEAD 2>/dev/null || echo 'UNKNOWN')"
    exit 1
fi

# Generate list of candidate commits from history (including all parents of merges)
mapfile -t CANDIDATES < <(git rev-list --topo-order -n "$MAX_DEPTH" "$PIVOT_SHA")
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "::error::No commits found for revision $REVISION."
    exit 1
fi

# Convert to associative array for O(1) lookup during tag iteration
declare -A CANDIDATE_MAP
for sha in "${CANDIDATES[@]}"; do
    CANDIDATE_MAP["$sha"]=1
done

echo "::group::Image Tracker — resolving ancestry for $REVISION"
echo "  Repository: $REPOSITORY"
echo "  Starting SHA: $PIVOT_SHA"
echo "  Max Depth:    $MAX_DEPTH"
echo "  Candidates:   ${#CANDIDATES[@]} commit(s) in history"

# ---- Map package names to GHCR image paths ---------------------------------
# Convention: if package name matches the repo name, image lives at the repo
# root path (ghcr.io/<owner>/<repo>); otherwise nested under the package name.
declare -A IMAGE_PATHS
declare -a PKG_ORDER  # to preserve input order for first-package outputs
repo_name="${REPOSITORY#*/}"
lc_repo="${REPOSITORY,,}"

# Normalize separators: turn commas and whitespace into newlines, then read line by line
while IFS= read -r pkg; do
    pkg="${pkg//[[:space:]]/}"
    [[ -z "$pkg" ]] && continue
    # If the package name matches the repo name, image lives at the repo
    # root path (ghcr.io/<owner>/<repo>); otherwise nested under the package name.
    if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
        IMAGE_PATHS["$pkg"]="${lc_repo}"
        PKG_ORDER+=("$pkg")
    else
        IMAGE_PATHS["$pkg"]="${lc_repo}/${pkg,,}"
        PKG_ORDER+=("$pkg")
    fi
done < <(echo "$PACKAGE_INPUT" | tr ',' '\n' | tr -s '[:space:]' '\n')

if [[ ${#IMAGE_PATHS[@]} -eq 0 ]]; then
    echo "::error::No valid package names found in input '${PACKAGE_INPUT}'. Provide at least one package name."
    exit 1
fi

echo "  Packages:   ${!IMAGE_PATHS[*]}"
echo ""

# ---- Per-package registry auth ---------------------------------------------
# GHCR issues tokens scoped to one repository at a time. We fetch a fresh
# token per image path. Uses the Bearer pattern documented by the v2 API.
registry_token() {
    local image_path="$1"
    curl -sS -u "x:${TOKEN}" \
        "https://ghcr.io/token?scope=repository:${image_path}:pull" \
        | jq -r '.token'
}

# Helper to check if a revision string matches a candidate SHA or its PR info.
# handles partial SHA matches correctly.
matches_candidate() {
    local rev="$1"
    [[ -z "$rev" ]] && return 1
    
    for cand in "${!CANDIDATE_MAP[@]}"; do
        # Check direct SHA match (handles both short and long)
        if [[ "$cand" == "$rev"* ]] || [[ "$rev" == "$cand"* ]]; then
            return 0
        fi
        # Check PR head match (squash-merge support)
        local ph="${PR_MAP[$cand]:-}"
        if [[ -n "$ph" ]] && { [[ "$ph" == "$rev"* ]] || [[ "$rev" == "$ph"* ]]; }; then
            return 0
        fi
        # Check PR number match (tag support)
        local pn="${PR_NUM_MAP[$cand]:-}"
        if [[ -n "$pn" && "$rev" == "pr-$pn" ]]; then
            return 0
        fi
    done
    return 1
}

# Probe a specific tag directly.
# Returns "sha:digest" on success, empty on failure.
probe_tag() {
    local image_path="$1"
    local tag="$2"
    local bearer="$3"
    local base="https://ghcr.io/v2/${image_path}"
    local accept_index="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
    local accept_manifest="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

    local mresp mdigest
    mresp=$(curl -sS -i -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_index}" "${base}/manifests/${tag}")
    mdigest=$(printf '%s' "$mresp" | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {gsub(/\r/,""); print $2; exit}')
    
    if [[ -n "$mdigest" ]]; then
        # Fetch config to verify the revision label (Tags are mutable; labels are our authority)
        local mbody mtype config_digest
        mbody=$(printf '%s' "$mresp" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
        mtype=$(printf '%s' "$mbody" | jq -r '.mediaType // empty' 2>/dev/null || true)
        
        if [[ "$mtype" == *"index"* || "$mtype" == *"manifest.list"* ]]; then
            config_digest=$(printf '%s' "$mbody" | jq -r '
                .manifests[]
                | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown")
                | .digest' 2>/dev/null | head -1)
            [[ -z "$config_digest" ]] && config_digest=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
            [[ -n "$config_digest" ]] && mbody=$(curl -sS -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_manifest}" "${base}/manifests/${config_digest}")
        fi
        config_digest=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
        
        if [[ -n "$config_digest" ]]; then
            local revision
            revision=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${config_digest}" \
                | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
            
            local match_str="$revision"
            if ! matches_candidate "$match_str"; then
                local tag_val="${tag#sha-}"
                if matches_candidate "$tag_val"; then
                    match_str="$tag_val"
                fi
            fi
            
            # Prefer the OCI revision label, but if it is missing or does not match any
            # candidate, allow a matching sha-derived tag value to stand in. This is safe
            # because we only accept the tag when it matches one of the known candidates.
            if matches_candidate "$match_str"; then
                # Find which candidate it matched
                for cand in "${!CANDIDATE_MAP[@]}"; do
                    local pn="${PR_NUM_MAP[$cand]:-}"
                    local ph="${PR_MAP[$cand]:-}"
                    if [[ "$cand" == "$match_str"* ]] || [[ "$match_str" == "$cand"* ]] || \
                       [[ -n "$ph" && "$ph" == "$match_str"* ]] || [[ -n "$ph" && "$match_str" == "$ph"* ]] || \
                       [[ -n "$pn" && "$match_str" == "pr-$pn" ]]; then
                        printf '%s:%s' "$cand" "$mdigest"
                        return 0
                    fi
                done
            fi
        fi
    fi
    return 1
}

# ---- Look up the manifest digest whose config carries our commit SHA -------
# Returns "sha256:...<manifest-digest>" on stdout, empty string on miss.
resolve_digest() {
    local image_path="$1"
    local bearer="$2"
    local base="https://ghcr.io/v2/${image_path}"
    local tags_seen=0

    # Accept headers
    local accept_index="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
    local accept_manifest="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

    # Paginate tags
    local url="${base}/tags/list?n=100"
    while [[ -n "$url" ]]; do
        local raw
        raw=$(curl -sS -i -H "Authorization: Bearer ${bearer}" "$url")
        local body
        body=$(printf '%s' "$raw" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
        local link_hdr
        link_hdr=$(printf '%s' "$raw" | awk 'BEGIN{IGNORECASE=1} /^link:/ {print; exit}')

        local tag
        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue
            # Skip cosign/SBOM helper tags.
            [[ "$tag" == sha256-*.sig ]] && continue
            [[ "$tag" == sha256-*.sbom ]] && continue
            [[ "$tag" == sha256-*.att ]] && continue

            tags_seen=$((tags_seen + 1))
            if [[ "$tags_seen" -gt "$MAX_TAGS" ]]; then
                echo "  [!] Reached MAX_TAGS=$MAX_TAGS; stopping search." >&2
                return 2
            fi

            # Check if tag is one of our candidates (High-confidence hit)
            tag_sha="${tag#sha-}"
            if matches_candidate "$tag_sha"; then
                 # Pull manifest to get digest
                 local mresp mdigest
                 mresp=$(curl -sS -i -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_index}" "${base}/manifests/${tag}")
                 mdigest=$(printf '%s' "$mresp" | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {gsub(/\r/,""); print $2; exit}')
                 if [[ -n "$mdigest" ]]; then
                    # Find which candidate it matched
                    for cand in "${!CANDIDATE_MAP[@]}"; do
                        local pn="${PR_NUM_MAP[$cand]:-}"
                        local ph="${PR_MAP[$cand]:-}"
                        if [[ "$cand" == "$tag_sha"* ]] || [[ "$tag_sha" == "$cand"* ]] || \
                           [[ -n "$ph" && "$ph" == "$tag_sha"* ]] || [[ -n "$ph" && "$tag_sha" == "$ph"* ]] || \
                           [[ -n "$pn" && "$tag_sha" == "pr-$pn" ]]; then
                            printf '%s:%s' "$cand" "$mdigest"
                            return 0
                        fi
                    done
                 fi
            fi

            # Iterative deep search (Label check)
            local manifest_url="${base}/manifests/${tag}"
            local mresp mbody mdigest mtype
            mresp=$(curl -sS -i -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_index}" "$manifest_url")
            mbody=$(printf '%s' "$mresp" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
            mdigest=$(printf '%s' "$mresp" | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {gsub(/\r/,""); print $2; exit}')
            mtype=$(printf '%s' "$mbody" | jq -r '.mediaType // empty' 2>/dev/null || true)

            local config_digest
            if [[ "$mtype" == *"index"* || "$mtype" == *"manifest.list"* ]]; then
                local child
                child=$(printf '%s' "$mbody" | jq -r '
                    .manifests[]
                    | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown")
                    | .digest' 2>/dev/null | head -1)
                [[ -z "$child" ]] && child=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
                [[ -z "$child" ]] && continue
                local child_body
                child_body=$(curl -sS -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_manifest}" "${base}/manifests/${child}")
                config_digest=$(printf '%s' "$child_body" | jq -r '.config.digest // empty' 2>/dev/null || true)
            else
                config_digest=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
            fi

            [[ -z "$config_digest" ]] && continue

            local revision
            revision=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${config_digest}" \
                | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)

            local match_str="$revision"
            if ! matches_candidate "$match_str"; then
                local tag_val="${tag#sha-}"
                if matches_candidate "$tag_val"; then
                    match_str="$tag_val"
                fi
            fi

            if matches_candidate "$match_str"; then
                for cand in "${!CANDIDATE_MAP[@]}"; do
                    local pn="${PR_NUM_MAP[$cand]:-}"
                    local ph="${PR_MAP[$cand]:-}"
                    if [[ "$cand" == "$match_str"* ]] || [[ "$match_str" == "$cand"* ]] || \
                       [[ -n "$ph" && "$ph" == "$match_str"* ]] || [[ -n "$ph" && "$match_str" == "$ph"* ]] || \
                       [[ -n "$pn" && "$match_str" == "pr-$pn" ]]; then
                        printf '%s:%s' "$cand" "$mdigest"
                        return 0
                    fi
                done
            fi
        done < <(printf '%s' "$body" | jq -r '.tags[]?' 2>/dev/null)

        if [[ -n "$link_hdr" ]]; then
            local next
            next=$(printf '%s' "$link_hdr" | grep -oE '<[^>]+>' | head -1 | tr -d '<>')
            if [[ -n "$next" ]]; then
                url="${next}"
                [[ "$next" == /* ]] && url="https://ghcr.io${next}"
                continue
            fi
        fi
        url=""
    done
    return 1
}

# ---- Resolve each package --------------------------------------------------
IMAGES_JSON='{}'
DIGESTS_JSON='{}'
FIRST_IMAGE=""
FIRST_DIGEST=""
MISSING=()

for pkg in "${PKG_ORDER[@]}"; do
    image_path="${IMAGE_PATHS[$pkg]}"
    bearer=$(registry_token "$image_path" || true)
    if [[ -z "$bearer" || "$bearer" == "null" ]]; then
        echo "::error::Failed to obtain registry token for ${image_path}."
        MISSING+=("$pkg")
        continue
    fi
    echo "  [>] Searching ghcr.io/${image_path} for matching ancestry..."
    
    result=""
    # 1. Deterministic Probe (Fast Path)
    for candidate in "${CANDIDATES[@]}"; do
        short_sha="${candidate:0:7}"
        result=$(probe_tag "$image_path" "sha-${short_sha}" "$bearer" || true)
        [[ -n "$result" ]] && break
        
        if [[ "${#candidate}" -gt 7 ]]; then
             result=$(probe_tag "$image_path" "sha-${candidate}" "$bearer" || true)
             [[ -n "$result" ]] && break
        fi

        pr_head="${PR_MAP[$candidate]:-}"
        if [[ -n "$pr_head" ]]; then
             result=$(probe_tag "$image_path" "sha-${pr_head:0:7}" "$bearer" || true)
             [[ -n "$result" ]] && break
        fi
        
        pr_num="${PR_NUM_MAP[$candidate]:-}"
        if [[ -n "$pr_num" ]]; then
             result=$(probe_tag "$image_path" "pr-${pr_num}" "$bearer" || true)
             [[ -n "$result" ]] && break
        fi
    done

    # 2. Iterative Search (Fallback)
    if [[ -z "$result" ]]; then
        echo "      (Direct probes failed; falling back to iterative tag search...)"
        resolve_rc=0
        result=$(resolve_digest "$image_path" "$bearer") || resolve_rc=$?
        
        if [[ "$resolve_rc" -eq 2 ]]; then
            echo "::error::max_tags ($MAX_TAGS) exceeded resolving $pkg — no image found."
            exit 1
        fi
    fi
    
    if [[ -z "$result" ]]; then
        echo "  [x] MISS: $pkg (no image found in history matching candidate commits)"
        MISSING+=("$pkg")
        continue
    fi

    resolved_sha="${result%%:*}"
    digest="${result#*:}"
    image_ref="ghcr.io/${image_path}@${digest}"
    
    if [[ "$resolved_sha" != "$PIVOT_SHA" ]]; then
        echo "::warning title=Image Fallback (${pkg})::Target commit ${PIVOT_SHA:0:7} missing image. Using older commit ${resolved_sha:0:7}."
        echo "  [✓] HIT (FALLBACK): $pkg -> $image_ref (matched commit ${resolved_sha:0:12})"
    else
        echo "  [✓] HIT:  $pkg -> $image_ref (matched commit ${resolved_sha:0:12})"
    fi
    
    # Write to step summary for high visibility
    {
        echo "### 📦 Image Tracker: \`${pkg}\`"
        echo "- **Target Commit:** \`${PIVOT_SHA}\`"
        echo "- **Resolved Commit:** \`${resolved_sha}\`"
        echo "- **Image Digest:** \`${digest}\`"
        if [[ "$resolved_sha" != "$PIVOT_SHA" ]]; then
            echo "⚠️ *Note: Fell back to older commit because target image was not found in the registry.*"
        fi
        echo ""
    } >> "$GITHUB_STEP_SUMMARY"

    IMAGES_JSON=$(printf '%s' "$IMAGES_JSON"  | jq -c --arg k "$pkg" --arg v "$image_ref" '.[$k] = $v')
    DIGESTS_JSON=$(printf '%s' "$DIGESTS_JSON" | jq -c --arg k "$pkg" --arg v "$digest"    '.[$k] = $v')
    if [[ -z "$FIRST_IMAGE" ]]; then
        FIRST_IMAGE="$image_ref"
        FIRST_DIGEST="$digest"
    fi
done

echo "::endgroup::"

# ---- Outputs ---------------------------------------------------------------
{
    echo "images=${IMAGES_JSON}"
    echo "digests=${DIGESTS_JSON}"
    echo "image=${FIRST_IMAGE}"
    echo "digest=${FIRST_DIGEST}"
} >> "$GITHUB_OUTPUT"

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve the following package(s) within $MAX_DEPTH commit(s) of $PIVOT_SHA: ${MISSING[*]}"
    exit 1
fi

echo "Resolved ${#IMAGE_PATHS[@]} package(s) for $REVISION history."
