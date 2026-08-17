#!/usr/bin/env bash
# Image Tracker — Digest-via-OCI-label resolver (Standalone CLI + GitHub Action)
#
# Usage:
#   REPOSITORY=org/repo PACKAGE=pkg1,pkg2 ./action.sh
#
# Inputs (Env Vars):
#   PACKAGE/INPUT_PACKAGE: Comma-separated package names
#   REGISTRY/INPUT_REGISTRY: Target registry (default: ghcr.io)
#   REVISION/INPUT_REVISION: Git ref (default: HEAD)
#   REPOSITORY/INPUT_REPOSITORY: Target repo (default: GITHUB_REPOSITORY)
#   DIR/INPUT_DIR: Working directory (default: .)
#   TOKEN/INPUT_TOKEN: GitHub / Registry Token (default: GITHUB_TOKEN)
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

# ---- Package Mapping -------------------------------------------------------
map_packages() {
    local package_input="$1"
    local repository="$2"
    unset IMAGE_PATHS PKG_ORDER
    declare -gA IMAGE_PATHS
    declare -ga PKG_ORDER
    local repo_name="${repository#*/}"
    local lc_repo="${repository,,}"
    local pkg
    # Normalize separators: turn commas and whitespace into newlines
    while IFS= read -r pkg; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
            IMAGE_PATHS["$pkg"]="${lc_repo}"
        else
            IMAGE_PATHS["$pkg"]="${lc_repo}/${pkg,,}"
        fi
        PKG_ORDER+=("$pkg")
    done < <(echo "$package_input" | tr ',' '\n' | tr -s '[:space:]' '\n')
}

# ---- Registry Logic --------------------------------------------------------
parse_auth_header() {
    local header="$1"
    local realm="" service=""
    local realm_q_re='[Rr][Ee][Aa][Ll][Mm]="([^"]+)"'
    local realm_uq_re='[Rr][Ee][Aa][Ll][Mm]=([^,[:space:]]+)'
    local service_q_re='[Ss][Ee][Rr][Vv][Ii][Cc][Ee]="([^"]+)"'
    local service_uq_re='[Ss][Ee][Rr][Vv][Ii][Cc][Ee]=([^,[:space:]]+)'

    if [[ "$header" =~ $realm_q_re ]]; then
        realm="${BASH_REMATCH[1]}"
    elif [[ "$header" =~ $realm_uq_re ]]; then
        realm="${BASH_REMATCH[1]}"
    fi

    if [[ "$header" =~ $service_q_re ]]; then
        service="${BASH_REMATCH[1]}"
    elif [[ "$header" =~ $service_uq_re ]]; then
        service="${BASH_REMATCH[1]}"
    fi
    printf '%s|%s' "$realm" "$service"
}

registry_token() {
    local repo="$1"
    local reg="${REGISTRY:-ghcr.io}"
    local token="${TOKEN:-}"

    local probe_url="https://${reg}/v2/${repo}/manifests/latest"
    local hfile
    hfile=$(mktemp)
    local status
    status=$(curl -sS -D "$hfile" -o /dev/null -w "%{http_code}" "$probe_url" 2>/dev/null || echo "000")

    # If registry endpoint allows unauthenticated access (2xx), no token needed
    if [[ "$status" =~ ^2 ]]; then
        rm -f "$hfile"
        echo "__NO_AUTH__"
        return 0
    fi

    local auth_header
    auth_header=$(grep -iE '^www-authenticate:' "$hfile" | tr -d '\r' | grep -iE 'Bearer' | head -1 || true)
    rm -f "$hfile"

    if [[ -z "$auth_header" ]]; then
        # Fallback challenge probe to /v2/
        hfile=$(mktemp)
        curl -sS -D "$hfile" -o /dev/null "https://${reg}/v2/" 2>/dev/null || true
        auth_header=$(grep -iE '^www-authenticate:' "$hfile" | tr -d '\r' | grep -iE 'Bearer' | head -1 || true)
        rm -f "$hfile"
    fi

    # If no Bearer challenge found, return __NO_AUTH__ if token is empty, otherwise fail
    if [[ -z "$auth_header" ]]; then
        if [[ -z "$token" ]]; then
            echo "__NO_AUTH__"
            return 0
        fi
        return 1
    fi

    local parsed realm service
    parsed=$(parse_auth_header "$auth_header")
    realm="${parsed%%|*}"
    service="${parsed##*|}"

    if [[ -z "$realm" ]]; then
        return 1
    fi

    local sep="?"
    [[ "$realm" == *\?* ]] && sep="&"
    local params="scope=repository:${repo}:pull"
    [[ -n "$service" ]] && params="service=${service}&${params}"
    local token_url="${realm}${sep}${params}"

    local resp
    if [[ -n "$token" ]]; then
        resp=$(curl -sS -u "x:${token}" "$token_url" 2>/dev/null || true)
    else
        resp=$(curl -sS "$token_url" 2>/dev/null || true)
    fi

    local bearer
    bearer=$(printf '%s' "$resp" | jq -r '.token // .access_token // empty' 2>/dev/null || true)
    if [[ -n "$bearer" && "$bearer" != "null" ]]; then
        echo "$bearer"
        return 0
    fi
    return 1
}

matches_candidate() {
    local rev="$1"
    local tag="${2:-}"
    [[ -z "$rev" && -z "$tag" ]] && return 1
    
    for cand in "${CANDIDATES[@]}"; do
        # 1. Direct SHA match
        if [[ -n "$rev" ]] && { [[ "$cand" == "$rev"* ]] || [[ "$rev" == "$cand"* ]]; }; then
            [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (SHA): %s == %s\n" "$cand" "$rev" >&2
            return 0
        fi
        
        # 2. PR Head match (API-dependent)
        local ph="${PR_MAP[$cand]:-}"
        if [[ -n "$ph" && -n "$rev" ]] && { [[ "$ph" == "$rev"* ]] || [[ "$rev" == "$ph"* ]]; }; then
            [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Head): %s maps to %s\n" "$cand" "$ph" >&2
            return 0
        fi
        
        # 3. PR Number match (The bridge)
        local pn="${PR_NUM_MAP[$cand]:-}"
        if [[ -n "$pn" ]]; then
            # Match if the revision label itself is the PR tag
            if [[ -n "$rev" && "$rev" == "pr-$pn" ]]; then
                [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Label): %s maps to pr-%s\n" "$cand" "$pn" >&2
                return 0
            fi
            # Match if the tag we are probing is the PR tag
            if [[ -n "$tag" && ( "$tag" == "pr-$pn" || "$tag" == "$pn" ) ]]; then
                [[ "${DEBUG:-}" == "true" ]] && printf "      [d]   Match found (PR Tag Bridge): %s matches tag %s\n" "$cand" "$tag" >&2
                return 0
            fi
        fi
    done
    return 1
}

probe_tag() {
    local image_path="$1" tag="$2" bearer="$3"
    local reg="${REGISTRY:-ghcr.io}"
    local base="https://${reg}/v2/${image_path}"
    local accept="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, */*"

    local auth_args=()
    if [[ -n "$bearer" && "$bearer" != "__NO_AUTH__" ]]; then
        auth_args=(-H "Authorization: Bearer ${bearer}")
    fi

    local hfile
    hfile=$(mktemp)
    local mbody mdigest mtype

    mbody=$(curl -sS -L -D "$hfile" "${auth_args[@]}" -H "Accept: ${accept}" "${base}/manifests/${tag}" 2>/dev/null || true)
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
            mbody=$(curl -sS -L "${auth_args[@]}" -H "Accept: ${accept}" "${base}/manifests/${cd}" 2>/dev/null || true)
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
            config=$(curl -sSL "${auth_args[@]}" "${base}/blobs/${cd_final}" 2>/dev/null || true)
            revision=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)
            [[ -z "$created" || "$created" == "null" ]] && created=$(printf '%s' "$config" | jq -r '.config.Labels["org.opencontainers.image.created"] // empty' 2>/dev/null || true)
        fi
    fi

    rm -f "$hfile"
    if [[ "$tag" =~ ^pr-([0-9]+)$ ]]; then
        DIGEST_PR_MAP["$mdigest"]="${BASH_REMATCH[1]}"
    elif [[ "$tag" =~ ^[0-9]+$ ]]; then
        DIGEST_PR_MAP["$mdigest"]="$tag"
    fi

    if matches_candidate "$revision" "$tag"; then
        for cand in "${CANDIDATES[@]}"; do
             local ph="${PR_MAP[$cand]:-}"
             local pn="${PR_NUM_MAP[$cand]:-}"

             # Decoupled decision: does the revision label match OR does the tag follow a known pattern?
             local pattern_match=false
             if [[ -n "$pn" && ( "$tag" == "pr-$pn" || "$tag" == "$pn" ) ]]; then
                 pattern_match=true
             elif [[ "$tag" == "sha-${cand:0:7}" || ( -n "$ph" && "$tag" == "sha-${ph:0:7}" ) ]]; then
                 pattern_match=true
             fi

             if [[ ( -n "$revision" && "$revision" == "$cand"* ) || ( -n "$ph" && -n "$revision" && "$revision" == "$ph"* ) || ( -n "$pn" && "$revision" == "pr-$pn" ) || "$pattern_match" == "true" ]]; then
                 local title="${PR_TITLE_MAP[$cand]:-}"
                 [[ -z "$title" || "$title" == "null" ]] && title=$(git log -1 --format=%s "$cand" 2>/dev/null || echo "Unknown commit message")

                 local display_ref="$tag"
                 if [[ "$tag" == "sha-${cand:0:7}" || ( -n "$pn" && ( "$tag" == "pr-$pn" || "$tag" == "$pn" ) ) || ( -n "$ph" && "$tag" == "sha-${ph:0:7}" ) ]]; then
                     display_ref="$tag"
                 fi

                 # 1. Stderr for human logs
                 local audit_msg="[✓] HIT: $display_ref ($mdigest)"
                 [[ -n "$pn" ]] && audit_msg+=" | PR #$pn"
                 [[ -n "$title" ]] && audit_msg+=": $title"
                 [[ -n "$created" ]] && audit_msg+=" | Built: $created"
                 log_info "$audit_msg"

                 # 2. Stdout for machine-readable pipe-delimited payload
                 printf '%s|%s|%s|%s|%s' "$cand" "$mdigest" "$created" "${pn:-}" "$title"
                 return 0
             fi
        done
    fi
    return 1
}

resolve_digest() {
    local image_path="$1" bearer="$2"
    local reg="${REGISTRY:-ghcr.io}"
    local owner_orig="${REPOSITORY%%/*}"
    local pkg="${image_path#*/}"
    local pkg_enc="${pkg//\//%2F}"

    local raw_data=""
    if [[ "$reg" == "ghcr.io" ]] && command -v gh &>/dev/null && [[ -n "$TOKEN" ]]; then
        # Fetch both digest (name) and tags for each version
        raw_data=$(GITHUB_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" gh api "/orgs/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq 'if length > 0 then .[] | [.name, (.metadata.container.tags | join(","))] | @tsv else empty end' 2>/dev/null || true)
        if [[ -z "$raw_data" ]]; then
            raw_data=$(GITHUB_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" gh api "/users/${owner_orig}/packages/container/${pkg_enc}/versions?per_page=100" --jq 'if length > 0 then .[] | [.name, (.metadata.container.tags | join(","))] | @tsv else empty end' 2>/dev/null || true)
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
                if [[ "$t" =~ ^pr-([0-9]+)$ ]]; then
                    DIGEST_PR_MAP["$digest"]="${BASH_REMATCH[1]}"
                    probe_ref="$t"
                    break
                elif [[ "$t" =~ ^[0-9]+$ ]]; then
                    DIGEST_PR_MAP["$digest"]="$t"
                    probe_ref="$t"
                    break
                fi
            done

            local res
            res=$(probe_tag "$image_path" "$probe_ref" "$bearer" || true)
            if [[ -n "$res" ]]; then echo -ne "\r\033[K" >&2; echo "$res"; return 0; fi
        done <<< "$raw_data"
    else
        # Standard OCI /v2/<name>/tags/list fallback
        local auth_args=()
        if [[ -n "$bearer" && "$bearer" != "__NO_AUTH__" ]]; then
            auth_args=(-H "Authorization: Bearer ${bearer}")
        fi
        local tags_json
        tags_json=$(curl -sS "${auth_args[@]}" "https://${reg}/v2/${image_path}/tags/list" 2>/dev/null || true)
        local tag_list
        tag_list=$(printf '%s' "$tags_json" | jq -r '.tags[]? // empty' 2>/dev/null || true)
        if [[ -n "$tag_list" ]]; then
            while IFS= read -r tag; do
                [[ -z "$tag" ]] && continue
                tags_seen=$((tags_seen + 1))
                [[ "$tags_seen" -gt "$MAX_TAGS" ]] && return 2

                printf "\r      -> [%d/%d] Inspecting tag: %s... \033[K" "$tags_seen" "$MAX_TAGS" "${tag:0:15}" >&2
                local res
                res=$(probe_tag "$image_path" "$tag" "$bearer" || true)
                if [[ -n "$res" ]]; then echo -ne "\r\033[K" >&2; echo "$res"; return 0; fi
            done <<< "$tag_list"
        fi
    fi
    echo -ne "\r\033[K" >&2
    return 1
}

# ---- Markdown Summary ------------------------------------------------------
render_step_summary() {
    local reg="${REGISTRY:-ghcr.io}"
    local revision_display="${REVISION//|/\\|}"
    local target_str
    if [[ "$REVISION" == "$PIVOT_SHA"* || "$PIVOT_SHA" == "$REVISION"* ]]; then
        target_str="\`${PIVOT_SHA:0:7}\`"
    else
        target_str="\`${PIVOT_SHA:0:7}\` (${revision_display})"
    fi

    echo "### 📦 Image Tracker"
    echo ""
    echo "| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |"
    echo "| :--- | :--- | :--- | :--- | :--- |"

    for pkg in "${PKG_ORDER[@]}"; do
        local pkg_display="${pkg//|/\\|}"
        local payload="${IMAGES[$pkg]:-}"
        local path="${IMAGE_PATHS[$pkg]:-}"
        if [[ -n "$payload" ]]; then
            local sha digest created pr_num msg
            IFS='|' read -r sha digest created pr_num msg <<< "$payload"
            local ref="${reg}/${path}@${digest}"
            local resolved_str="\`${sha:0:7}\`"
            local depth=0
            for i in "${!CANDIDATES[@]}"; do
                if [[ "${CANDIDATES[$i]}" == "$sha"* || "$sha" == "${CANDIDATES[$i]}"* ]]; then
                    depth=$((i + 1))
                    break
                fi
            done
            local depth_str
            if [[ "$depth" -eq 1 ]]; then
                depth_str="1"
            elif [[ "$depth" -gt 1 ]]; then
                depth_str="${depth} (walked)"
            else
                depth_str="—"
            fi
            echo "| \`${pkg_display}\` | ${target_str} | ${resolved_str} | ${depth_str} | \`${ref}\` |"
        else
            echo "| \`${pkg_display}\` | ${target_str} | — | — | *Not resolved* |"
        fi
    done
    echo ""
}

# ---- Main Execution --------------------------------------------------------
run_main() {
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
    REGISTRY="${REGISTRY:-${INPUT_REGISTRY:-ghcr.io}}"
    REGISTRY="${REGISTRY#https://}"
    REGISTRY="${REGISTRY#http://}"
    REGISTRY="${REGISTRY%/}"
    REGISTRY="${REGISTRY:-ghcr.io}"
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
    declare -gA PR_MAP
    declare -gA PR_NUM_MAP
    declare -gA PR_TITLE_MAP
    declare -gA CANDIDATE_MAP
    declare -gA IMAGE_PATHS
    declare -gA IMAGES
    declare -gA DIGEST_PR_MAP
    declare -ga MISSING
    declare -ga PKG_ORDER

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
                api_shas=("$sha")
                # For merge commits, check the second parent (usually the PR head)
                parents=$(git log -1 --format=%P "$sha" 2>/dev/null || true)
                read -ra parent_arr <<< "$parents"
                if [[ ${#parent_arr[@]} -ge 2 ]]; then
                    api_shas+=("${parent_arr[1]}")
                fi
                
                for check_sha in "${api_shas[@]}"; do
                    pr_data=$(GITHUB_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" gh api "/repos/${REPOSITORY}/commits/${check_sha}/pulls" --jq '.[] | [.head.sha, .number, .title] | @tsv' 2>/dev/null | head -1 || true)
                    if [[ -n "$pr_data" ]]; then
                        break
                    fi
                done
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

    # Populate package map
    map_packages "$PACKAGE_INPUT" "$REPOSITORY"
    if [[ ${#PKG_ORDER[@]} -eq 0 ]]; then
        log_error "PACKAGE_INPUT did not contain any valid package names."
        exit 1
    fi

    # ---- Execution -------------------------------------------------------------
    log_group "Image Tracker — resolving ancestry for $REVISION"
    log_info "Registry: $REGISTRY"
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
        ref="${REGISTRY}/${path}@${digest}"
        printf "  [✓] HIT: %s -> %s\n" "$pkg" "$ref" >&2
        
        IMAGES["$pkg"]="$res"
        IMAGES_JSON=$(printf '%s' "$IMAGES_JSON" | jq -c --arg k "$pkg" --arg v "$ref" '.[$k] = $v')
    done

    log_endgroup

    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        render_step_summary >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi

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
                printf "image=%s/%s@%s\n" "$REGISTRY" "$f_path" "$r_digest" >> "$GITHUB_OUTPUT"
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_main "$@"
fi
