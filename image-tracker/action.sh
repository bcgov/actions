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

# On-demand PR map for squash-merge resolution
declare -A PR_MAP
declare -A PR_NUM_MAP
declare -A PR_TITLE_MAP

# Get the "pivot" commit (the starting point for history walking)
PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)

# If the pivot is missing and looks like a SHA, check if it's a known PR head
if [[ -z "$PIVOT_SHA" && "$REVISION" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "  [w] Revision $REVISION not found in local history. Checking for associated PRs..."
    if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
        pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${REVISION}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
        
        # If no PR found and it's a merge commit, try the second parent
        if [[ -z "$pr_data" ]]; then
            parents=$(git show -s --format=%P "${REVISION}^{commit}" 2>/dev/null || true)
            # Check if it has at least 2 parents (is a merge commit)
            if [[ "$parents" == *" "* ]]; then
                second_parent=$(printf '%s' "$parents" | awk '{print $2}')
                pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${second_parent}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
            fi
        fi

        if [[ -n "$pr_data" ]]; then
            # Use a here-string and IFS to handle potential spaces/tabs in the title
            {
                IFS=$'\t' read -r head_sha pr_num pr_title
            } <<< "$pr_data"

            if [[ -n "$pr_num" ]]; then
                printf "  [i] Revision matches PR #%s. Attempting to fetch PR ref...\n" "$pr_num"
                git fetch origin "pull/${pr_num}/head:refs/remotes/origin/pr/${pr_num}" --quiet || true
                PIVOT_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)
                
                # Store the title for the resolved SHA if successful
                if [[ -n "$PIVOT_SHA" ]]; then
                    PR_TITLE_MAP["$PIVOT_SHA"]="$pr_title"
                    [[ -n "$head_sha" && "$head_sha" != "null" ]] && PR_TITLE_MAP["$head_sha"]="$pr_title"
                fi
            fi
        fi
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
    
    # Fetch PR mapping on-demand for this candidate to resolve squash-merges
    if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
        # 1. Try to extract PR number from commit message subject (e.g. "feat: x (#123)")
        msg=$(git log -1 --format=%s "$sha" 2>/dev/null || true)
        # Handle messages like "title (#123)" or "title (#123) "
        pr_from_msg=$(printf '%s' "$msg" | grep -oE '\(#[0-9]+\)\s*$' | grep -oE '[0-9]+' || true)
        
        # 2. Query GitHub API for PR metadata
        pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${sha}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
        
        # If no PR found and it's a merge commit, try the second parent (the PR branch)
        if [[ -z "$pr_data" ]]; then
            parents=$(git show -s --format=%P "$sha" 2>/dev/null || true)
            # Simple check for multiple parents
            case "$parents" in
                *" "*)
                    second_parent=$(printf '%s' "$parents" | awk '{print $2}')
                    pr_data=$(GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${second_parent}/pulls" --jq 'if length > 0 then .[0] | [.head.sha, .number, .title] | @tsv else empty end' 2>/dev/null || true)
                    ;;
            esac
        fi

        if [[ -n "$pr_data" ]]; then
            # Use a here-string and IFS to handle potential spaces/tabs in the title
            {
                IFS=$'\t' read -r head_sha pr_num pr_title
            } <<< "$pr_data"
            
            if [[ "$head_sha" != "null" && -n "$head_sha" ]]; then
                PR_MAP["$sha"]="$head_sha"
                PR_NUM_MAP["$sha"]="$pr_num"
                PR_NUM_MAP["$head_sha"]="$pr_num"
                PR_TITLE_MAP["$sha"]="$pr_title"
                PR_TITLE_MAP["$head_sha"]="$pr_title"
            fi
        elif [[ -n "$pr_from_msg" ]]; then
            # Fallback to PR number from commit message if API fails
            PR_NUM_MAP["$sha"]="$pr_from_msg"
        fi
    fi
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
            config_digest=$(printf '%s' "$mbody" | jq -r '.manifests[] | select(.platform.architecture == "amd64" and (.platform.os // "") != "unknown") | .digest' 2>/dev/null | head -1)
            [[ -z "$config_digest" ]] && config_digest=$(printf '%s' "$mbody" | jq -r '.manifests[0].digest' 2>/dev/null | head -1)
            [[ -n "$config_digest" ]] && mbody=$(curl -sS -H "Authorization: Bearer ${bearer}" -H "Accept: ${accept_manifest}" "${base}/manifests/${config_digest}")
        fi
        config_digest=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null || true)
        if [[ -n "$config_digest" ]]; then
            local revision
            revision=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${config_digest}" \
                | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
            
            # Strict OCI Revision Verification
            # We only accept images where the embedded label matches a known candidate.
            if matches_candidate "$revision"; then
                local created
                created=$(curl -sSL -H "Authorization: Bearer ${bearer}" "${base}/blobs/${config_digest}" \
                    | jq -r '.config.Labels["org.opencontainers.image.created"] // empty' 2>/dev/null || true)
                
                # Find which candidate it matched
                for cand in "${!CANDIDATE_MAP[@]}"; do
                    local pn="${PR_NUM_MAP[$cand]:-}"
                    local ph="${PR_MAP[$cand]:-}"
                    if [[ "$cand" == "$revision"* ]] || [[ "$revision" == "$cand"* ]] || \
                       [[ -n "$ph" && "$ph" == "$revision"* ]] || [[ -n "$revision" && "$revision" == "$ph"* ]] || \
                       [[ -n "$pn" && "$revision" == "pr-$pn" ]]; then
                        # Resolve a human-friendly message
                        local msg="${PR_TITLE_MAP[$cand]:-}"
                        if [[ -z "$msg" || "$msg" == "null" ]]; then
                            # Fallback to git log
                            msg=$(git log -1 --format=%s "$cand" 2>/dev/null || echo "Unknown commit message")
                            # If it's a technical merge message, try to find a PR number in the history
                            if [[ "$msg" == "Merge "* && "$msg" == *" into "* ]]; then
                                local potential_pr
                                potential_pr=$(git log -1 --format=%b "$cand" 2>/dev/null | grep -oE '#[0-9]+' | head -1 || true)
                                [[ -n "$potential_pr" ]] && msg="Merge PR ${potential_pr}"
                            fi
                        fi
                        
                        # Return all metadata pipe-separated
                        printf '%s|%s|%s|%s|%s' "$cand" "$mdigest" "$created" "$pn" "$msg"
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

    local owner_orig="${REPOSITORY%%/*}"
    local pkg="${image_path#*/}"
    local pkg_enc="${pkg//\//%2F}"
    
    # Securely map commits to digests by reading their embedded OCI labels.
    # We fetch the most recent digests from the GitHub API first because it's sorted by date.
    local digests=""
    if command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
        digests=$(GH_TOKEN="$TOKEN" gh api "/orgs/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq '.[].name' 2>/dev/null || true)
        if [[ -z "$digests" ]]; then
            digests=$(GH_TOKEN="$TOKEN" gh api "/users/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq '.[].name' 2>/dev/null || true)
        fi
    fi
    
    local tags_seen=0
    
    # If GH API worked, check recent digests
    if [[ -n "$digests" ]]; then
        while IFS= read -r digest; do
            [[ -z "$digest" ]] && continue
            tags_seen=$((tags_seen + 1))
            if [[ "$tags_seen" -gt "$MAX_TAGS" ]]; then
                echo -ne "\r\033[K" >&2
                echo "  [!] Reached MAX_TAGS=$MAX_TAGS; stopping search." >&2
                return 2
            fi
            echo -ne "\r      -> [${tags_seen}/${MAX_TAGS}] Inspecting digest: ${digest:0:15}... \033[K" >&2
            
            # probe_tag takes a digest as well and checks the OCI label securely
            local result
            result=$(probe_tag "$image_path" "$digest" "$bearer" || true)
            if [[ -n "$result" ]]; then
                echo -ne "\r\033[K" >&2
                echo "$result"
                return 0
            fi
        done <<< "$digests"
    else
        # Fallback to the slow, alphabetical tags/list from GHCR
        local url="${base}/tags/list?n=100"
        while [[ -n "$url" ]]; do
            local raw body link_hdr
            raw=$(curl -sS -i -H "Authorization: Bearer ${bearer}" "$url")
            body=$(printf '%s' "$raw" | awk 'BEGIN{p=0} /^\r?$/{p=1; next} p{print}')
            link_hdr=$(printf '%s' "$raw" | awk 'BEGIN{IGNORECASE=1} /^link:/ {print; exit}')
            
            local tag
            while IFS= read -r tag; do
                [[ -z "$tag" ]] && continue
                [[ "$tag" == sha256-*.sig || "$tag" == sha256-*.sbom || "$tag" == sha256-*.att ]] && continue
                
                tags_seen=$((tags_seen + 1))
                if [[ "$tags_seen" -gt "$MAX_TAGS" ]]; then
                    echo -ne "\r\033[K" >&2
                    echo "  [!] Reached MAX_TAGS=$MAX_TAGS; stopping search." >&2
                    return 2
                fi
                echo -ne "\r      -> [${tags_seen}/${MAX_TAGS}] Inspecting tag: ${tag} \033[K" >&2
                
                local result
                result=$(probe_tag "$image_path" "$tag" "$bearer" || true)
                if [[ -n "$result" ]]; then
                    echo -ne "\r\033[K" >&2
                    echo "$result"
                    return 0
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
    fi
    echo -ne "\r\033[K" >&2
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
    # 1. Forensic Trace (Primary)
    # We walk history backwards and check if a tag exists for each commit (e.g. sha-<commit>).
    for candidate in "${CANDIDATES[@]}"; do
        local pr_head="${PR_MAP[$candidate]:-}"
        local pr_num="${PR_NUM_MAP[$candidate]:-}"
        
        # 1. Try PR Head SHA (e.g. sha-303d1cc) - The most reliable for squash-merges
        if [[ -n "$pr_head" ]]; then
            result=$(probe_tag "$image_path" "sha-${pr_head:0:7}" "$bearer" || true)
        fi
        
        # 2. Try PR Number (e.g. pr-461) - Standard PR build tag
        if [[ -z "$result" && -n "$pr_num" ]]; then
            result=$(probe_tag "$image_path" "pr-${pr_num}" "$bearer" || true)
        fi
        
        # 3. Try Commit SHA (e.g. sha-5845400) - Standard commit build tag
        if [[ -z "$result" ]]; then
            result=$(probe_tag "$image_path" "sha-${candidate:0:7}" "$bearer" || true)
        fi
        
        if [[ -n "$result" ]]; then
            break
        fi
    done

    # 2. Garbage Scrub (Fallback)
    # If the forensic trace misses (e.g. for untagged images or infrequently changed packages),
    # we perform an iterative scan of the last 100 raw digests via the GitHub Packages API.
    if [[ -z "$result" ]]; then
        echo "      (Forensic trace missed; falling back to iterative digest scan...)"
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

    IFS='|' read -r resolved_sha digest created pr_num msg <<< "$result"
    image_ref="ghcr.io/${image_path}@${digest}"
    
    pr_info=""
    [[ -n "$pr_num" && "$pr_num" != "null" ]] && pr_info=" (PR #$pr_num)"
    
    date_info=""
    [[ -n "$created" && "$created" != "null" ]] && date_info=" built on $created"

    if [[ "$resolved_sha" != "$PIVOT_SHA" ]]; then
        echo "::warning title=Image Fallback (${pkg})::Target commit ${PIVOT_SHA:0:7} missing image. Using older commit ${resolved_sha:0:7}${pr_info}${date_info}."
        echo "  [✓] HIT (FALLBACK): $pkg -> $image_ref"
        echo "      Message: $msg"
        echo "      Matched commit ${resolved_sha:0:12}${pr_info}${date_info}"
    else
        echo "  [✓] HIT:  $pkg -> $image_ref"
        echo "      Message: $msg"
        echo "      Matched commit ${resolved_sha:0:12}${pr_info}${date_info}"
    fi
    
    # Write to step summary for high visibility
    {
        echo "### 📦 Image Tracker: \`${pkg}\`"
        echo "- **Merged:** \`${created:-Unknown}\`"
        echo "- **Message:** \`${msg}\`$( [[ -n "$pr_info" ]] && echo " $pr_info" )"
        echo "- **Digest:** \`${digest}\`"
        echo "- **Merge Commit:** \`${PIVOT_SHA}\`"
        echo "- **Image Commit:** \`${resolved_sha}\`"
        if [[ "$resolved_sha" != "$PIVOT_SHA" ]]; then
            echo "⚠️ *Note: Fell back to older commit because target image was not found for the latest revision.*"
        fi
        echo ""
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

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
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve the following package(s) within $MAX_DEPTH commit(s) of $PIVOT_SHA: ${MISSING[*]}"
    exit 1
fi

echo "Resolved ${#IMAGE_PATHS[@]} package(s) for $REVISION history."
