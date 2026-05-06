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

if [[ -z "$PACKAGE_INPUT" ]]; then
    echo "::error::Missing required input 'package'."
    exit 1
fi
if [[ -z "$TOKEN" ]]; then
    echo "::error::No token available. Pass 'token' input or set GITHUB_TOKEN."
    exit 1
fi

# ---- Resolve git history to candidate SHAs ---------------------------------
cd "$DIR"
# Get the "pivot" commit (the starting point for history walking)
PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)
if [[ -z "$PIVOT_SHA" ]]; then
    echo "::error::Could not resolve git revision '$REVISION' in '$DIR'."
    exit 1
fi

# Generate list of candidate commits from history
mapfile -t CANDIDATES < <(git rev-list -n "$MAX_DEPTH" "$PIVOT_SHA")
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

# ---- Look up the manifest digest whose config carries our commit SHA -------
# Returns "sha256:...<manifest-digest>" on stdout, empty string on miss.
# Strategy:
#   1. List tags (paginated).
#   2. For each tag, fetch manifest (index or single).
#     - If index: pick amd64 child manifest.
#     - Else: use the manifest directly.
#   3. Fetch config blob. If its `org.opencontainers.image.revision` matches
#      the target commit, emit the ORIGINAL (top-level) manifest digest.
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
            # Skip cosign/SBOM helper tags (they are not images we want to resolve).
            [[ "$tag" == sha256-*.sig ]] && continue
            [[ "$tag" == sha256-*.sbom ]] && continue
            [[ "$tag" == sha256-*.att ]] && continue

            tags_seen=$((tags_seen + 1))
            if [[ "$tags_seen" -gt "$MAX_TAGS" ]]; then
                echo "  [!] Reached MAX_TAGS=$MAX_TAGS; stopping search." >&2
                return 2
            fi

            # Fetch top-level manifest + its digest header.
            local manifest_url="${base}/manifests/${tag}"
            local mresp mbody mdigest mtype
            mresp=$(curl -sS -i -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_index}" "$manifest_url")
            mbody=$(printf '%s' "$mresp" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
            mdigest=$(printf '%s' "$mresp" | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {gsub(/\r/,""); print $2; exit}')
            mtype=$(printf '%s' "$mbody" | jq -r '.mediaType // empty' 2>/dev/null || true)

            # Descend into amd64 child if this is a multi-arch index.
            local config_digest
            if [[ "$mtype" == *"index"* || "$mtype" == *"manifest.list"* ]]; then
                # Try to find any valid child (amd64 preferred, then any)
                local child
                child=$(printf '%s' "$mbody" | jq -r '
                    .manifests[]
                    | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown")
                    | .digest' 2>/dev/null | head -1)
                if [[ -z "$child" ]]; then
                    # Fallback: pick the first child regardless of arch/os
                    child=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
                fi
                [[ -z "$child" ]] && continue
                local child_body
                child_body=$(curl -sS -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_manifest}" "${base}/manifests/${child}")
                config_digest=$(printf '%s' "$child_body" | jq -r '.config.digest // empty' 2>/dev/null || true)
            else
                config_digest=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
            fi

            [[ -z "$config_digest" ]] && continue

            # Fetch config blob and check the revision label.
            local revision
            revision=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${config_digest}" \
                | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)

            # Check if the image revision matches any candidate.
            # We support prefix matching to handle short SHAs (7+ chars) generated by some builders.
            for candidate in "${!CANDIDATE_MAP[@]}"; do
                if [[ "$candidate" == "$revision"* ]] && [[ ${#revision} -ge 7 ]]; then
                    printf '%s:%s' "$candidate" "$mdigest"
                    return 0
                fi
            done
        done < <(printf '%s' "$body" | jq -r '.tags[]?' 2>/dev/null)

        # Follow RFC 5988 Link: rel="next"
        if [[ -n "$link_hdr" ]]; then
            local next
            next=$(printf '%s' "$link_hdr" | grep -oE '<[^>]+>' | head -1 | tr -d '<>')
            if [[ -n "$next" ]]; then
                if [[ "$next" == /* ]]; then
                    url="https://ghcr.io${next}"
                else
                    url="$next"
                fi
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

# Iterate in input order so that FIRST_IMAGE/FIRST_DIGEST correspond to the
# first successfully resolved package in the input list.
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
    resolve_rc=0
    result=$(resolve_digest "$image_path" "$bearer") || resolve_rc=$?
    
    if [[ "$resolve_rc" -eq 2 ]]; then
        echo "::error::max_tags ($MAX_TAGS) exceeded resolving $pkg — no image found. Increase max_tags or narrow the search."
        exit 1
    fi
    
    if [[ -z "$result" ]]; then
        echo "  [x] MISS: $pkg (no image found in history matching candidate commits)"
        MISSING+=("$pkg")
        continue
    fi

    # result is "sha:digest"
    resolved_sha="${result%%:*}"
    digest="${result#*:}"
    image_ref="ghcr.io/${image_path}@${digest}"
    echo "  [✓] HIT:  $pkg -> $image_ref (matched commit ${resolved_sha:0:12})"
    IMAGES_JSON=$(printf '%s' "$IMAGES_JSON"  | jq -c --arg k "$pkg" --arg v "$image_ref" '.[$k] = $v')
    DIGESTS_JSON=$(printf '%s' "$DIGESTS_JSON" | jq -c --arg k "$pkg" --arg v "$digest"    '.[$k] = $v')
    # Set first-package outputs on the first successful hit
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
