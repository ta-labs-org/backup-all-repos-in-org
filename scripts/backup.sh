#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# GitHub Organization Full Backup Script
#
# Backup targets:
#   1.  Repositories (full mirror clone + LFS)
#   2.  Wikis
#   3.  GitHub Projects (v2)
#   4.  Artifacts (GitHub Actions)
#   5.  Releases & Release Assets
#   6.  GitHub Packages (container/npm/maven/nuget/rubygems)
#   7.  Issues & Pull Requests (with comments, labels, milestones)
#   8.  Discussions (GraphQL)
#   9.  Actions Workflow Logs
#  10.  Actions Variables & Environment configs
#  11.  Security Alerts (Dependabot, Code Scanning, Secret Scanning)
#  12.  Teams & Memberships
#  13.  Webhooks (Org + Repo level)
#  14.  Branch Protection Rules & Repository Rulesets
#  15.  Repository Custom Properties
#
# Backup destination: Azure Blob Storage
###############################################################################

# ─── Configuration (environment variables) ───────────────────────────────────
GITHUB_ORG="${GITHUB_ORG:?'GITHUB_ORG is required'}"
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:?'AZURE_STORAGE_ACCOUNT is required'}"
AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:?'AZURE_STORAGE_CONTAINER is required'}"
AZURE_STORAGE_SAS_TOKEN="${AZURE_STORAGE_SAS_TOKEN:-}"

# GitHub Apps authentication
# Either GITHUB_TOKEN is provided directly (e.g. from actions/create-github-app-token)
# or APP_ID + APP_PRIVATE_KEY are provided for self-managed token generation.
GITHUB_APP_ID="${GITHUB_APP_ID:-}"
GITHUB_APP_PRIVATE_KEY="${GITHUB_APP_PRIVATE_KEY:-}"
GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

BACKUP_DIR="${BACKUP_DIR:-/tmp/github-backup}"
DATE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${BACKUP_DIR}/${DATE_STAMP}"
GH_API="https://api.github.com"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# Token expiry tracking (installation tokens expire in 1 hour)
TOKEN_CREATED_AT=0
TOKEN_LIFETIME=3300  # Refresh after 55 minutes (buffer before 60 min expiry)

mkdir -p "${BACKUP_ROOT}"

# Counters
BACKUP_WARNINGS=0

# ─── Helper functions ────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +%H:%M:%S)] $*"
}

warn() {
  echo "[$(date -u +%H:%M:%S)] WARN: $*" >&2
  BACKUP_WARNINGS=$((BACKUP_WARNINGS + 1))
}

# ─── GitHub Apps Token Generation ────────────────────────────────────────────

# Generate JWT from App ID and private key (RS256)
_generate_jwt() {
  local app_id="$1"
  local private_key="$2"

  local now
  now=$(date +%s)
  local iat=$((now - 60))
  local exp=$((now + 600))

  local header
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  local payload
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  local signature
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign <(echo "$private_key") -binary | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# Get installation ID for the org
_get_installation_id() {
  local jwt="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GH_API}/app/installations" \
  | jq -r --arg org "${GITHUB_ORG}" '.[] | select(.account.login == $org) | .id'
}

# Create installation access token
_create_installation_token() {
  local jwt="$1"
  local installation_id="$2"
  curl -fsSL \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -X POST \
    "${GH_API}/app/installations/${installation_id}/access_tokens" \
  | jq -r '.token'
}

# Generate or refresh installation access token from App credentials
refresh_github_token() {
  local now
  now=$(date +%s)

  # Skip if token was recently created
  if [[ $((now - TOKEN_CREATED_AT)) -lt ${TOKEN_LIFETIME} && -n "${GITHUB_TOKEN}" ]]; then
    return 0
  fi

  # If App credentials are not provided, GITHUB_TOKEN must already be set
  if [[ -z "${GITHUB_APP_ID}" ]]; then
    if [[ -z "${GITHUB_TOKEN}" ]]; then
      echo "ERROR: Either GITHUB_TOKEN or GITHUB_APP_ID + private key must be provided" >&2
      exit 1
    fi
    TOKEN_CREATED_AT=$now
    return 0
  fi

  # Resolve private key
  local private_key="${GITHUB_APP_PRIVATE_KEY:-}"
  if [[ -z "$private_key" && -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
    private_key=$(cat "${GITHUB_APP_PRIVATE_KEY_FILE}")
  fi
  if [[ -z "$private_key" ]]; then
    echo "ERROR: GITHUB_APP_PRIVATE_KEY or GITHUB_APP_PRIVATE_KEY_FILE is required when GITHUB_APP_ID is set" >&2
    exit 1
  fi

  log "Generating GitHub App installation access token..."

  local jwt
  jwt=$(_generate_jwt "${GITHUB_APP_ID}" "$private_key")

  local installation_id
  installation_id=$(_get_installation_id "$jwt")
  if [[ -z "$installation_id" || "$installation_id" == "null" ]]; then
    echo "ERROR: Could not find installation for org '${GITHUB_ORG}'. Is the GitHub App installed on this org?" >&2
    exit 1
  fi

  GITHUB_TOKEN=$(_create_installation_token "$jwt" "$installation_id")
  if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to create installation access token" >&2
    exit 1
  fi

  TOKEN_CREATED_AT=$(date +%s)
  export GITHUB_TOKEN
  log "GitHub App token refreshed (installation_id=${installation_id})"
}

# Ensure token is valid (call before API-heavy operations)
ensure_token() {
  local now
  now=$(date +%s)
  if [[ -n "${GITHUB_APP_ID}" && $((now - TOKEN_CREATED_AT)) -ge ${TOKEN_LIFETIME} ]]; then
    refresh_github_token
  fi
}

gh_api() {
  local endpoint="$1"
  shift
  curl -fsSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" \
    "${GH_API}${endpoint}"
}

gh_graphql() {
  local query="$1"
  local variables="${2:-{}}"
  curl -fsSL \
    -H "Authorization: bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"query\":$(echo "$query" | jq -Rs .),\"variables\":${variables}}" \
    "https://api.github.com/graphql"
}

# Paginated GET — collects all pages into a single JSON array
gh_api_paginated() {
  local endpoint="$1"
  local page=1
  local per_page=100
  local results="[]"

  while true; do
    local sep="?"
    [[ "$endpoint" == *"?"* ]] && sep="&"
    local page_data
    page_data=$(gh_api "${endpoint}${sep}per_page=${per_page}&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "$page_data" | jq 'if type == "array" then length else 0 end')
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    results=$(echo "$results" "$page_data" | jq -s '.[0] + .[1]')
    if [[ "$count" -lt "$per_page" ]]; then
      break
    fi
    page=$((page + 1))
  done

  echo "$results"
}

upload_to_blob() {
  local src="$1"
  local blob_path="$2"

  local auth_args=()
  if [[ -n "${AZURE_STORAGE_SAS_TOKEN}" ]]; then
    auth_args+=(--sas-token "${AZURE_STORAGE_SAS_TOKEN}")
  fi

  az storage blob upload \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --container-name "${AZURE_STORAGE_CONTAINER}" \
    --name "${blob_path}" \
    --file "${src}" \
    --overwrite true \
    --auth-mode key \
    "${auth_args[@]}" \
    --only-show-errors
}

# Save JSON to file and upload
save_and_upload() {
  local json_data="$1"
  local local_path="$2"
  local blob_path="$3"

  mkdir -p "$(dirname "$local_path")"
  echo "$json_data" | jq '.' > "$local_path"
  upload_to_blob "$local_path" "$blob_path"
}

# Get all repo full names (cached)
REPO_LIST_CACHE=""
get_all_repos() {
  if [[ -z "$REPO_LIST_CACHE" ]]; then
    REPO_LIST_CACHE=$(gh_api_paginated "/orgs/${GITHUB_ORG}/repos?type=all")
  fi
  echo "$REPO_LIST_CACHE"
}

###############################################################################
# 1. Backup Repositories (mirror clone + LFS → tar.gz → upload)
###############################################################################

backup_repo() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  log "  [repo] Cloning ${repo_full_name} ..."
  local repo_dir="${BACKUP_ROOT}/repos/${repo_name}"
  mkdir -p "${repo_dir}"

  git clone --mirror \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_full_name}.git" \
    "${repo_dir}/${repo_name}.git" 2>/dev/null || {
    warn "[repo] Failed to clone ${repo_full_name}"
    return 0
  }

  # Fetch LFS objects if git-lfs is available
  if command -v git-lfs &>/dev/null; then
    (
      cd "${repo_dir}/${repo_name}.git"
      git lfs fetch --all 2>/dev/null || true
    )
  fi

  local archive="${BACKUP_ROOT}/repos/${repo_name}.tar.gz"
  tar -czf "$archive" -C "${repo_dir}" "${repo_name}.git"
  rm -rf "${repo_dir}/${repo_name}.git"

  upload_to_blob "$archive" "backups/${DATE_STAMP}/repos/${repo_name}.tar.gz"
  log "  [repo] ✓ ${repo_full_name}"
}

backup_all_repos() {
  log "=== [1/15] Backing up repositories ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local repo_names
  repo_names=$(echo "$repos" | jq -r '.[].full_name')
  local count
  count=$(echo "$repos" | jq 'length')
  log "Found ${count} repositories"

  export -f backup_repo upload_to_blob gh_api log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP GH_API BACKUP_WARNINGS

  echo "$repo_names" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_repo "$@"' _ {}
}

###############################################################################
# 2. Backup Wikis
###############################################################################

backup_wiki() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  local wiki_dir="${BACKUP_ROOT}/wikis/${repo_name}"
  mkdir -p "${wiki_dir}"

  git clone \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_full_name}.wiki.git" \
    "${wiki_dir}/wiki" 2>/dev/null || return 0

  local archive="${BACKUP_ROOT}/wikis/${repo_name}-wiki.tar.gz"
  tar -czf "$archive" -C "${wiki_dir}" wiki
  rm -rf "${wiki_dir}/wiki"

  upload_to_blob "$archive" "backups/${DATE_STAMP}/wikis/${repo_name}-wiki.tar.gz"
  log "  [wiki] ✓ ${repo_full_name}"
}

backup_all_wikis() {
  log "=== [2/15] Backing up wikis ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local wiki_repos
  wiki_repos=$(echo "$repos" | jq -r '.[] | select(.has_wiki == true) | .full_name')
  local count
  count=$(echo "$wiki_repos" | grep -c . || true)
  log "Found ${count} repositories with wikis enabled"

  export -f backup_wiki upload_to_blob log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP

  echo "$wiki_repos" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_wiki "$@"' _ {}
}

###############################################################################
# 3. Backup GitHub Projects (v2 — GraphQL)
###############################################################################

backup_projects() {
  log "=== [3/15] Backing up GitHub Projects (v2) ==="
  ensure_token

  local projects_dir="${BACKUP_ROOT}/projects"
  mkdir -p "${projects_dir}"

  local query='
  query($org: String!, $cursor: String) {
    organization(login: $org) {
      projectsV2(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id number title shortDescription closed createdAt updatedAt
          items(first: 100) {
            nodes {
              id type
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2Field { name } } }
                  ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2Field { name } } }
                  ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2Field { name } } }
                  ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } }
                  ... on ProjectV2ItemFieldIterationValue { title field { ... on ProjectV2IterationField { name } } }
                }
              }
              content {
                ... on Issue { title number url state }
                ... on PullRequest { title number url state }
                ... on DraftIssue { title body }
              }
            }
          }
          fields(first: 50) {
            nodes {
              ... on ProjectV2Field { id name dataType }
              ... on ProjectV2SingleSelectField { id name options { id name } }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }
  }'

  local has_next=true
  local cursor="null"
  local all_projects="[]"

  while [[ "$has_next" == "true" ]]; do
    local variables
    if [[ "$cursor" == "null" ]]; then
      variables="{\"org\":\"${GITHUB_ORG}\",\"cursor\":null}"
    else
      variables="{\"org\":\"${GITHUB_ORG}\",\"cursor\":\"${cursor}\"}"
    fi

    local response
    response=$(gh_graphql "$query" "$variables") || { warn "[projects] GraphQL query failed"; break; }

    local page_info
    page_info=$(echo "$response" | jq '.data.organization.projectsV2.pageInfo')
    has_next=$(echo "$page_info" | jq -r '.hasNextPage')
    cursor=$(echo "$page_info" | jq -r '.endCursor')

    local nodes
    nodes=$(echo "$response" | jq '.data.organization.projectsV2.nodes')
    all_projects=$(echo "$all_projects" "$nodes" | jq -s '.[0] + .[1]')
  done

  local count
  count=$(echo "$all_projects" | jq 'length')
  log "Found ${count} projects"

  echo "$all_projects" | jq -c '.[]' | while read -r project; do
    local number title filename
    number=$(echo "$project" | jq -r '.number')
    title=$(echo "$project" | jq -r '.title' | tr ' /' '_-')
    filename="project-${number}-${title}.json"
    save_and_upload "$project" "${projects_dir}/${filename}" "backups/${DATE_STAMP}/projects/${filename}"
    log "  [project] ✓ #${number} ${title}"
  done
}

###############################################################################
# 4. Backup Artifacts (GitHub Actions)
###############################################################################

backup_artifacts_for_repo() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  local artifacts
  artifacts=$(gh_api "/repos/${repo_full_name}/actions/artifacts?per_page=100" 2>/dev/null) || return 0

  local total
  total=$(echo "$artifacts" | jq '.total_count')
  [[ "$total" -eq 0 ]] && return 0

  local artifact_dir="${BACKUP_ROOT}/artifacts/${repo_name}"
  mkdir -p "${artifact_dir}"

  echo "$artifacts" | jq -c '.artifacts[]' | while read -r artifact; do
    local art_id art_name expired
    art_id=$(echo "$artifact" | jq -r '.id')
    art_name=$(echo "$artifact" | jq -r '.name' | tr ' /' '_-')
    expired=$(echo "$artifact" | jq -r '.expired')
    [[ "$expired" == "true" ]] && continue

    local zip_file="${artifact_dir}/${art_name}-${art_id}.zip"
    curl -fsSL \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -L -o "$zip_file" \
      "${GH_API}/repos/${repo_full_name}/actions/artifacts/${art_id}/zip" 2>/dev/null || {
      warn "[artifact] Failed to download ${art_name} from ${repo_full_name}"
      continue
    }
    upload_to_blob "$zip_file" "backups/${DATE_STAMP}/artifacts/${repo_name}/${art_name}-${art_id}.zip"
    log "  [artifact] ✓ ${repo_full_name} / ${art_name}"
  done
}

backup_all_artifacts() {
  log "=== [4/15] Backing up artifacts ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local repo_names
  repo_names=$(echo "$repos" | jq -r '.[].full_name')

  export -f backup_artifacts_for_repo upload_to_blob gh_api log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP GH_API

  echo "$repo_names" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_artifacts_for_repo "$@"' _ {}
}

###############################################################################
# 5. Backup Releases & Release Assets
###############################################################################

backup_releases_for_repo() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  local releases
  releases=$(gh_api_paginated "/repos/${repo_full_name}/releases")
  local count
  count=$(echo "$releases" | jq 'length')
  [[ "$count" -eq 0 ]] && return 0

  local release_dir="${BACKUP_ROOT}/releases/${repo_name}"
  mkdir -p "${release_dir}"

  # Save release metadata
  echo "$releases" | jq '.' > "${release_dir}/releases.json"
  upload_to_blob "${release_dir}/releases.json" "backups/${DATE_STAMP}/releases/${repo_name}/releases.json"

  # Download release assets
  echo "$releases" | jq -c '.[]' | while read -r release; do
    local tag_name
    tag_name=$(echo "$release" | jq -r '.tag_name' | tr ' /' '_-')

    echo "$release" | jq -c '.assets[]?' | while read -r asset; do
      local asset_id asset_name
      asset_id=$(echo "$asset" | jq -r '.id')
      asset_name=$(echo "$asset" | jq -r '.name')

      local asset_file="${release_dir}/${tag_name}--${asset_name}"
      curl -fsSL \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -L -o "$asset_file" \
        "${GH_API}/repos/${repo_full_name}/releases/assets/${asset_id}" 2>/dev/null || {
        warn "[release] Failed to download asset ${asset_name} from ${repo_full_name}@${tag_name}"
        continue
      }
      upload_to_blob "$asset_file" "backups/${DATE_STAMP}/releases/${repo_name}/${tag_name}/${asset_name}"
      log "  [release] ✓ ${repo_full_name}@${tag_name} / ${asset_name}"
    done
  done
}

backup_all_releases() {
  log "=== [5/15] Backing up releases & assets ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local repo_names
  repo_names=$(echo "$repos" | jq -r '.[].full_name')

  export -f backup_releases_for_repo upload_to_blob gh_api gh_api_paginated log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP GH_API

  echo "$repo_names" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_releases_for_repo "$@"' _ {}
}

###############################################################################
# 6. Backup GitHub Packages
###############################################################################

backup_all_packages() {
  log "=== [6/15] Backing up GitHub Packages ==="
  ensure_token

  local packages_dir="${BACKUP_ROOT}/packages"
  mkdir -p "${packages_dir}"

  local package_types=("npm" "maven" "nuget" "rubygems" "container")

  for pkg_type in "${package_types[@]}"; do
    local packages
    packages=$(gh_api_paginated "/orgs/${GITHUB_ORG}/packages?package_type=${pkg_type}" 2>/dev/null) || continue

    local count
    count=$(echo "$packages" | jq 'length')
    [[ "$count" -eq 0 ]] && continue

    log "  [packages] Found ${count} ${pkg_type} packages"

    echo "$packages" | jq -c '.[]' | while read -r package; do
      local pkg_name
      pkg_name=$(echo "$package" | jq -r '.name' | tr ' /' '_-')

      local pkg_dir="${packages_dir}/${pkg_type}/${pkg_name}"
      mkdir -p "${pkg_dir}"
      echo "$package" | jq '.' > "${pkg_dir}/metadata.json"

      # Get package versions
      local versions
      versions=$(gh_api_paginated "/orgs/${GITHUB_ORG}/packages/${pkg_type}/${pkg_name}/versions" 2>/dev/null) || continue
      echo "$versions" | jq '.' > "${pkg_dir}/versions.json"

      upload_to_blob "${pkg_dir}/metadata.json" \
        "backups/${DATE_STAMP}/packages/${pkg_type}/${pkg_name}/metadata.json"
      upload_to_blob "${pkg_dir}/versions.json" \
        "backups/${DATE_STAMP}/packages/${pkg_type}/${pkg_name}/versions.json"

      log "  [packages] ✓ ${pkg_type}/${pkg_name} ($(echo "$versions" | jq 'length') versions)"
    done
  done

  # For container packages, also pull and save Docker images
  if command -v docker &>/dev/null; then
    local container_packages
    container_packages=$(gh_api_paginated "/orgs/${GITHUB_ORG}/packages?package_type=container" 2>/dev/null) || true
    local container_count
    container_count=$(echo "$container_packages" | jq 'length')

    if [[ "$container_count" -gt 0 ]]; then
      log "  [packages] Pulling ${container_count} container images..."
      echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ORG}" --password-stdin 2>/dev/null || true

      echo "$container_packages" | jq -r '.[].name' | while read -r img_name; do
        local image="ghcr.io/${GITHUB_ORG}/${img_name}:latest"
        docker pull "$image" 2>/dev/null || { warn "[packages] Cannot pull ${image}"; continue; }

        local tar_file="${packages_dir}/container/${img_name}/image-latest.tar"
        mkdir -p "$(dirname "$tar_file")"
        docker save "$image" -o "$tar_file" 2>/dev/null || { warn "[packages] Cannot save ${image}"; continue; }

        gzip "$tar_file"
        upload_to_blob "${tar_file}.gz" \
          "backups/${DATE_STAMP}/packages/container/${img_name}/image-latest.tar.gz"
        docker rmi "$image" 2>/dev/null || true
        log "  [packages] ✓ container/${img_name}:latest (image saved)"
      done
    fi
  else
    log "  [packages] Docker not available — skipping container image pulls (metadata still saved)"
  fi
}

###############################################################################
# 7. Backup Issues & Pull Requests (with comments, labels, milestones)
###############################################################################

backup_issues_for_repo() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  local issues_dir="${BACKUP_ROOT}/issues/${repo_name}"
  mkdir -p "${issues_dir}"

  # Milestones
  local milestones
  milestones=$(gh_api_paginated "/repos/${repo_full_name}/milestones?state=all")
  echo "$milestones" | jq '.' > "${issues_dir}/milestones.json"
  upload_to_blob "${issues_dir}/milestones.json" \
    "backups/${DATE_STAMP}/issues/${repo_name}/milestones.json"

  # Labels
  local labels
  labels=$(gh_api_paginated "/repos/${repo_full_name}/labels")
  echo "$labels" | jq '.' > "${issues_dir}/labels.json"
  upload_to_blob "${issues_dir}/labels.json" \
    "backups/${DATE_STAMP}/issues/${repo_name}/labels.json"

  # Issues (includes PRs) — all states
  local issues
  issues=$(gh_api_paginated "/repos/${repo_full_name}/issues?state=all&sort=created&direction=asc")
  local count
  count=$(echo "$issues" | jq 'length')
  [[ "$count" -eq 0 ]] && return 0

  # Save all issues metadata
  echo "$issues" | jq '.' > "${issues_dir}/issues.json"
  upload_to_blob "${issues_dir}/issues.json" \
    "backups/${DATE_STAMP}/issues/${repo_name}/issues.json"

  # Fetch comments for each issue
  local comments_dir="${issues_dir}/comments"
  mkdir -p "${comments_dir}"

  echo "$issues" | jq -c '.[]' | while read -r issue; do
    local issue_number comments_count
    issue_number=$(echo "$issue" | jq -r '.number')
    comments_count=$(echo "$issue" | jq -r '.comments')

    if [[ "$comments_count" -gt 0 ]]; then
      local comments
      comments=$(gh_api_paginated "/repos/${repo_full_name}/issues/${issue_number}/comments" 2>/dev/null) || continue
      echo "$comments" | jq '.' > "${comments_dir}/issue-${issue_number}-comments.json"
      upload_to_blob "${comments_dir}/issue-${issue_number}-comments.json" \
        "backups/${DATE_STAMP}/issues/${repo_name}/comments/issue-${issue_number}.json"
    fi
  done

  # PR review comments
  local pr_numbers
  pr_numbers=$(echo "$issues" | jq -r '.[] | select(.pull_request != null) | .number')

  for pr_num in $pr_numbers; do
    local reviews
    reviews=$(gh_api_paginated "/repos/${repo_full_name}/pulls/${pr_num}/reviews" 2>/dev/null) || continue
    if [[ "$(echo "$reviews" | jq 'length')" -gt 0 ]]; then
      echo "$reviews" | jq '.' > "${comments_dir}/pr-${pr_num}-reviews.json"
      upload_to_blob "${comments_dir}/pr-${pr_num}-reviews.json" \
        "backups/${DATE_STAMP}/issues/${repo_name}/comments/pr-${pr_num}-reviews.json"
    fi

    local review_comments
    review_comments=$(gh_api_paginated "/repos/${repo_full_name}/pulls/${pr_num}/comments" 2>/dev/null) || continue
    if [[ "$(echo "$review_comments" | jq 'length')" -gt 0 ]]; then
      echo "$review_comments" | jq '.' > "${comments_dir}/pr-${pr_num}-review-comments.json"
      upload_to_blob "${comments_dir}/pr-${pr_num}-review-comments.json" \
        "backups/${DATE_STAMP}/issues/${repo_name}/comments/pr-${pr_num}-review-comments.json"
    fi
  done

  log "  [issues] ✓ ${repo_full_name} (${count} issues/PRs)"
}

backup_all_issues() {
  log "=== [7/15] Backing up issues & pull requests ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local repo_names
  repo_names=$(echo "$repos" | jq -r '.[].full_name')

  export -f backup_issues_for_repo upload_to_blob gh_api gh_api_paginated log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP GH_API

  echo "$repo_names" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_issues_for_repo "$@"' _ {}
}

###############################################################################
# 8. Backup Discussions (GraphQL)
###############################################################################

backup_discussions() {
  log "=== [8/15] Backing up discussions ==="
  ensure_token

  local repos
  repos=$(get_all_repos)

  echo "$repos" | jq -c '.[]' | while read -r repo; do
    local repo_full_name repo_name
    repo_full_name=$(echo "$repo" | jq -r '.full_name')
    repo_name=$(echo "$repo" | jq -r '.name')

    local discussions_dir="${BACKUP_ROOT}/discussions/${repo_name}"
    mkdir -p "${discussions_dir}"

    local query='
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        discussions(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id number title body author { login } createdAt updatedAt
            category { id name }
            labels(first: 10) { nodes { name } }
            answer { id body author { login } createdAt }
            comments(first: 100) {
              nodes {
                id body author { login } createdAt updatedAt
                replies(first: 50) {
                  nodes { id body author { login } createdAt }
                }
              }
            }
          }
        }
      }
    }'

    local has_next=true
    local cursor="null"
    local all_discussions="[]"

    while [[ "$has_next" == "true" ]]; do
      local variables
      if [[ "$cursor" == "null" ]]; then
        variables="{\"owner\":\"${GITHUB_ORG}\",\"repo\":\"${repo_name}\",\"cursor\":null}"
      else
        variables="{\"owner\":\"${GITHUB_ORG}\",\"repo\":\"${repo_name}\",\"cursor\":\"${cursor}\"}"
      fi

      local response
      response=$(gh_graphql "$query" "$variables" 2>/dev/null) || break

      local disc_data
      disc_data=$(echo "$response" | jq '.data.repository.discussions // empty')
      [[ -z "$disc_data" ]] && break

      local page_info
      page_info=$(echo "$disc_data" | jq '.pageInfo')
      has_next=$(echo "$page_info" | jq -r '.hasNextPage')
      cursor=$(echo "$page_info" | jq -r '.endCursor')

      local nodes
      nodes=$(echo "$disc_data" | jq '.nodes')
      all_discussions=$(echo "$all_discussions" "$nodes" | jq -s '.[0] + .[1]')
    done

    local count
    count=$(echo "$all_discussions" | jq 'length')
    if [[ "$count" -gt 0 ]]; then
      save_and_upload "$all_discussions" \
        "${discussions_dir}/discussions.json" \
        "backups/${DATE_STAMP}/discussions/${repo_name}/discussions.json"
      log "  [discussions] ✓ ${repo_full_name} (${count} discussions)"
    fi
  done
}

###############################################################################
# 9. Backup Actions Workflow Logs
###############################################################################

backup_workflow_logs_for_repo() {
  local repo_full_name="$1"
  local repo_name
  repo_name=$(basename "$repo_full_name")

  # Get the latest 10 completed workflow runs
  local runs
  runs=$(gh_api "/repos/${repo_full_name}/actions/runs?per_page=10&status=completed" 2>/dev/null) || return 0

  local total
  total=$(echo "$runs" | jq '.total_count')
  [[ "$total" -eq 0 ]] && return 0

  local logs_dir="${BACKUP_ROOT}/workflow-logs/${repo_name}"
  mkdir -p "${logs_dir}"

  # Save run metadata
  echo "$runs" | jq '.' > "${logs_dir}/runs.json"
  upload_to_blob "${logs_dir}/runs.json" \
    "backups/${DATE_STAMP}/workflow-logs/${repo_name}/runs.json"

  echo "$runs" | jq -c '.workflow_runs[:10][]' | while read -r run; do
    local run_id run_name
    run_id=$(echo "$run" | jq -r '.id')
    run_name=$(echo "$run" | jq -r '.name' | tr ' /' '_-')

    local log_file="${logs_dir}/${run_name}-${run_id}.zip"
    curl -fsSL \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -L -o "$log_file" \
      "${GH_API}/repos/${repo_full_name}/actions/runs/${run_id}/logs" 2>/dev/null || continue

    if [[ -s "$log_file" ]]; then
      upload_to_blob "$log_file" \
        "backups/${DATE_STAMP}/workflow-logs/${repo_name}/${run_name}-${run_id}.zip"
    fi
  done

  log "  [workflow-logs] ✓ ${repo_full_name}"
}

backup_all_workflow_logs() {
  log "=== [9/15] Backing up workflow logs ==="
  ensure_token
  local repos
  repos=$(get_all_repos)
  local repo_names
  repo_names=$(echo "$repos" | jq -r '.[].full_name')

  export -f backup_workflow_logs_for_repo upload_to_blob gh_api log warn
  export GITHUB_TOKEN AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
  export BACKUP_ROOT DATE_STAMP GH_API

  echo "$repo_names" | xargs -P "${PARALLEL_JOBS}" -I {} bash -c 'backup_workflow_logs_for_repo "$@"' _ {}
}

###############################################################################
# 10. Backup Actions Variables & Environments
###############################################################################

backup_actions_config() {
  log "=== [10/15] Backing up Actions variables & environments ==="
  ensure_token

  local config_dir="${BACKUP_ROOT}/actions-config"
  mkdir -p "${config_dir}"

  # Org-level variables
  local org_vars
  org_vars=$(gh_api_paginated "/orgs/${GITHUB_ORG}/actions/variables" 2>/dev/null) || true
  if [[ "$(echo "$org_vars" | jq 'length')" -gt 0 ]]; then
    save_and_upload "$org_vars" \
      "${config_dir}/org-variables.json" \
      "backups/${DATE_STAMP}/actions-config/org-variables.json"
    log "  [actions-config] ✓ org variables"
  fi

  # Org-level secrets (names only — values cannot be read)
  local org_secrets
  org_secrets=$(gh_api "/orgs/${GITHUB_ORG}/actions/secrets" 2>/dev/null) || true
  if [[ -n "$org_secrets" ]]; then
    save_and_upload "$org_secrets" \
      "${config_dir}/org-secret-names.json" \
      "backups/${DATE_STAMP}/actions-config/org-secret-names.json"
    log "  [actions-config] ✓ org secret names (values not exportable)"
  fi

  # Per-repo variables, secrets (names), and environments
  local repos
  repos=$(get_all_repos)

  echo "$repos" | jq -c '.[]' | while read -r repo; do
    local repo_full_name repo_name
    repo_full_name=$(echo "$repo" | jq -r '.full_name')
    repo_name=$(echo "$repo" | jq -r '.name')
    local repo_config_dir="${config_dir}/${repo_name}"
    mkdir -p "${repo_config_dir}"

    # Repo variables
    local repo_vars
    repo_vars=$(gh_api_paginated "/repos/${repo_full_name}/actions/variables" 2>/dev/null) || continue
    if [[ "$(echo "$repo_vars" | jq 'length')" -gt 0 ]]; then
      save_and_upload "$repo_vars" \
        "${repo_config_dir}/variables.json" \
        "backups/${DATE_STAMP}/actions-config/${repo_name}/variables.json"
    fi

    # Repo secret names
    local repo_secrets
    repo_secrets=$(gh_api "/repos/${repo_full_name}/actions/secrets" 2>/dev/null) || true
    if [[ -n "$repo_secrets" ]]; then
      save_and_upload "$repo_secrets" \
        "${repo_config_dir}/secret-names.json" \
        "backups/${DATE_STAMP}/actions-config/${repo_name}/secret-names.json"
    fi

    # Environments
    local envs
    envs=$(gh_api "/repos/${repo_full_name}/environments" 2>/dev/null) || continue
    local env_count
    env_count=$(echo "$envs" | jq '.total_count // 0')
    if [[ "$env_count" -gt 0 ]]; then
      save_and_upload "$envs" \
        "${repo_config_dir}/environments.json" \
        "backups/${DATE_STAMP}/actions-config/${repo_name}/environments.json"

      # Environment-level variables and secret names
      echo "$envs" | jq -r '.environments[].name' | while read -r env_name; do
        local env_safe_name
        env_safe_name=$(echo "$env_name" | tr ' /' '_-')

        local env_vars
        env_vars=$(gh_api_paginated "/repos/${repo_full_name}/environments/${env_name}/variables" 2>/dev/null) || continue
        if [[ "$(echo "$env_vars" | jq 'length')" -gt 0 ]]; then
          save_and_upload "$env_vars" \
            "${repo_config_dir}/env-${env_safe_name}-variables.json" \
            "backups/${DATE_STAMP}/actions-config/${repo_name}/env-${env_safe_name}-variables.json"
        fi

        local env_secrets
        env_secrets=$(gh_api "/repos/${repo_full_name}/environments/${env_name}/secrets" 2>/dev/null) || continue
        if [[ -n "$env_secrets" ]]; then
          save_and_upload "$env_secrets" \
            "${repo_config_dir}/env-${env_safe_name}-secret-names.json" \
            "backups/${DATE_STAMP}/actions-config/${repo_name}/env-${env_safe_name}-secret-names.json"
        fi
      done
    fi
  done

  log "  [actions-config] Done"
}

###############################################################################
# 11. Backup Security Alerts
###############################################################################

backup_security_alerts() {
  log "=== [11/15] Backing up security alerts ==="
  ensure_token

  local repos
  repos=$(get_all_repos)

  echo "$repos" | jq -c '.[]' | while read -r repo; do
    local repo_full_name repo_name
    repo_full_name=$(echo "$repo" | jq -r '.full_name')
    repo_name=$(echo "$repo" | jq -r '.name')
    local sec_dir="${BACKUP_ROOT}/security/${repo_name}"
    mkdir -p "${sec_dir}"
    local has_data=false

    # Dependabot alerts
    local dependabot
    dependabot=$(gh_api_paginated "/repos/${repo_full_name}/dependabot/alerts?state=open" 2>/dev/null) || true
    if [[ -n "$dependabot" && "$(echo "$dependabot" | jq 'length')" -gt 0 ]]; then
      save_and_upload "$dependabot" \
        "${sec_dir}/dependabot-alerts.json" \
        "backups/${DATE_STAMP}/security/${repo_name}/dependabot-alerts.json"
      has_data=true
    fi

    # Code scanning alerts
    local code_scanning
    code_scanning=$(gh_api_paginated "/repos/${repo_full_name}/code-scanning/alerts?state=open" 2>/dev/null) || true
    if [[ -n "$code_scanning" && "$(echo "$code_scanning" | jq 'length')" -gt 0 ]]; then
      save_and_upload "$code_scanning" \
        "${sec_dir}/code-scanning-alerts.json" \
        "backups/${DATE_STAMP}/security/${repo_name}/code-scanning-alerts.json"
      has_data=true
    fi

    # Secret scanning alerts
    local secret_scanning
    secret_scanning=$(gh_api_paginated "/repos/${repo_full_name}/secret-scanning/alerts?state=open" 2>/dev/null) || true
    if [[ -n "$secret_scanning" && "$(echo "$secret_scanning" | jq 'length')" -gt 0 ]]; then
      save_and_upload "$secret_scanning" \
        "${sec_dir}/secret-scanning-alerts.json" \
        "backups/${DATE_STAMP}/security/${repo_name}/secret-scanning-alerts.json"
      has_data=true
    fi

    if [[ "$has_data" == "true" ]]; then
      log "  [security] ✓ ${repo_full_name}"
    fi
  done
}

###############################################################################
# 12. Backup Teams & Memberships
###############################################################################

backup_teams() {
  log "=== [12/15] Backing up teams & memberships ==="
  ensure_token

  local teams_dir="${BACKUP_ROOT}/teams"
  mkdir -p "${teams_dir}"

  # Org members
  local members
  members=$(gh_api_paginated "/orgs/${GITHUB_ORG}/members")
  save_and_upload "$members" \
    "${teams_dir}/org-members.json" \
    "backups/${DATE_STAMP}/teams/org-members.json"
  log "  [teams] ✓ org members ($(echo "$members" | jq 'length'))"

  # Outside collaborators
  local outside_collaborators
  outside_collaborators=$(gh_api_paginated "/orgs/${GITHUB_ORG}/outside_collaborators" 2>/dev/null) || true
  if [[ "$(echo "$outside_collaborators" | jq 'length')" -gt 0 ]]; then
    save_and_upload "$outside_collaborators" \
      "${teams_dir}/outside-collaborators.json" \
      "backups/${DATE_STAMP}/teams/outside-collaborators.json"
    log "  [teams] ✓ outside collaborators ($(echo "$outside_collaborators" | jq 'length'))"
  fi

  # Teams
  local teams
  teams=$(gh_api_paginated "/orgs/${GITHUB_ORG}/teams")
  save_and_upload "$teams" \
    "${teams_dir}/teams.json" \
    "backups/${DATE_STAMP}/teams/teams.json"

  local team_count
  team_count=$(echo "$teams" | jq 'length')
  log "  [teams] Found ${team_count} teams"

  echo "$teams" | jq -c '.[]' | while read -r team; do
    local team_slug team_name
    team_slug=$(echo "$team" | jq -r '.slug')
    team_name=$(echo "$team" | jq -r '.name')

    local team_dir="${teams_dir}/${team_slug}"
    mkdir -p "${team_dir}"

    # Team members
    local team_members
    team_members=$(gh_api_paginated "/orgs/${GITHUB_ORG}/teams/${team_slug}/members")
    save_and_upload "$team_members" \
      "${team_dir}/members.json" \
      "backups/${DATE_STAMP}/teams/${team_slug}/members.json"

    # Team repos
    local team_repos
    team_repos=$(gh_api_paginated "/orgs/${GITHUB_ORG}/teams/${team_slug}/repos")
    save_and_upload "$team_repos" \
      "${team_dir}/repos.json" \
      "backups/${DATE_STAMP}/teams/${team_slug}/repos.json"

    log "  [teams] ✓ ${team_name} ($(echo "$team_members" | jq 'length') members, $(echo "$team_repos" | jq 'length') repos)"
  done
}

###############################################################################
# 13. Backup Webhooks (Org + Repo level)
###############################################################################

backup_webhooks() {
  log "=== [13/15] Backing up webhooks ==="
  ensure_token

  local webhooks_dir="${BACKUP_ROOT}/webhooks"
  mkdir -p "${webhooks_dir}"

  # Org webhooks
  local org_hooks
  org_hooks=$(gh_api_paginated "/orgs/${GITHUB_ORG}/hooks" 2>/dev/null) || true
  if [[ "$(echo "$org_hooks" | jq 'length')" -gt 0 ]]; then
    save_and_upload "$org_hooks" \
      "${webhooks_dir}/org-webhooks.json" \
      "backups/${DATE_STAMP}/webhooks/org-webhooks.json"
    log "  [webhooks] ✓ org webhooks ($(echo "$org_hooks" | jq 'length'))"
  fi

  # Repo webhooks
  local repos
  repos=$(get_all_repos)

  echo "$repos" | jq -c '.[]' | while read -r repo; do
    local repo_full_name repo_name
    repo_full_name=$(echo "$repo" | jq -r '.full_name')
    repo_name=$(echo "$repo" | jq -r '.name')

    local hooks
    hooks=$(gh_api_paginated "/repos/${repo_full_name}/hooks" 2>/dev/null) || continue
    local count
    count=$(echo "$hooks" | jq 'length')
    if [[ "$count" -gt 0 ]]; then
      save_and_upload "$hooks" \
        "${webhooks_dir}/${repo_name}-webhooks.json" \
        "backups/${DATE_STAMP}/webhooks/${repo_name}-webhooks.json"
      log "  [webhooks] ✓ ${repo_full_name} (${count} webhooks)"
    fi
  done
}

###############################################################################
# 14. Backup Branch Protection Rules & Repository Rulesets
###############################################################################

backup_protection_rules() {
  log "=== [14/15] Backing up branch protections & rulesets ==="
  ensure_token

  local rules_dir="${BACKUP_ROOT}/protection-rules"
  mkdir -p "${rules_dir}"

  # Org-level rulesets
  local org_rulesets
  org_rulesets=$(gh_api_paginated "/orgs/${GITHUB_ORG}/rulesets" 2>/dev/null) || true
  if [[ "$(echo "$org_rulesets" | jq 'length')" -gt 0 ]]; then
    echo "$org_rulesets" | jq -c '.[]' | while read -r ruleset; do
      local rs_id
      rs_id=$(echo "$ruleset" | jq -r '.id')
      local full_rs
      full_rs=$(gh_api "/orgs/${GITHUB_ORG}/rulesets/${rs_id}" 2>/dev/null) || continue
      echo "$full_rs" | jq '.' > "${rules_dir}/org-ruleset-${rs_id}.json"
      upload_to_blob "${rules_dir}/org-ruleset-${rs_id}.json" \
        "backups/${DATE_STAMP}/protection-rules/org-ruleset-${rs_id}.json"
    done
    save_and_upload "$org_rulesets" \
      "${rules_dir}/org-rulesets.json" \
      "backups/${DATE_STAMP}/protection-rules/org-rulesets.json"
    log "  [rules] ✓ org rulesets ($(echo "$org_rulesets" | jq 'length'))"
  fi

  # Per-repo branch protections and rulesets
  local repos
  repos=$(get_all_repos)

  echo "$repos" | jq -c '.[]' | while read -r repo; do
    local repo_full_name repo_name
    repo_full_name=$(echo "$repo" | jq -r '.full_name')
    repo_name=$(echo "$repo" | jq -r '.name')

    local repo_rules_dir="${rules_dir}/${repo_name}"
    mkdir -p "${repo_rules_dir}"
    local has_data=false

    # Branch protection rules
    local branches
    branches=$(gh_api_paginated "/repos/${repo_full_name}/branches?protected=true" 2>/dev/null) || true

    echo "$branches" | jq -r '.[].name' 2>/dev/null | while read -r branch; do
      local protection
      protection=$(gh_api "/repos/${repo_full_name}/branches/${branch}/protection" 2>/dev/null) || continue
      local safe_branch
      safe_branch=$(echo "$branch" | tr '/' '_')
      save_and_upload "$protection" \
        "${repo_rules_dir}/branch-${safe_branch}-protection.json" \
        "backups/${DATE_STAMP}/protection-rules/${repo_name}/branch-${safe_branch}-protection.json"
    done

    # Repo rulesets
    local repo_rulesets
    repo_rulesets=$(gh_api_paginated "/repos/${repo_full_name}/rulesets" 2>/dev/null) || true
    if [[ "$(echo "$repo_rulesets" | jq 'length')" -gt 0 ]]; then
      save_and_upload "$repo_rulesets" \
        "${repo_rules_dir}/rulesets.json" \
        "backups/${DATE_STAMP}/protection-rules/${repo_name}/rulesets.json"
      has_data=true
    fi

    if [[ "$has_data" == "true" ]]; then
      log "  [rules] ✓ ${repo_full_name}"
    fi
  done
}

###############################################################################
# 15. Backup Repository Custom Properties
###############################################################################

backup_custom_properties() {
  log "=== [15/15] Backing up custom properties ==="
  ensure_token

  local props_dir="${BACKUP_ROOT}/custom-properties"
  mkdir -p "${props_dir}"

  # Org-level custom property definitions
  local org_props
  org_props=$(gh_api_paginated "/orgs/${GITHUB_ORG}/properties/schema" 2>/dev/null) || true
  if [[ "$(echo "$org_props" | jq 'length')" -gt 0 ]]; then
    save_and_upload "$org_props" \
      "${props_dir}/org-property-schema.json" \
      "backups/${DATE_STAMP}/custom-properties/org-property-schema.json"
    log "  [properties] ✓ org property schema"
  fi

  # Per-repo custom property values
  local repo_props
  repo_props=$(gh_api_paginated "/orgs/${GITHUB_ORG}/properties/values" 2>/dev/null) || true
  if [[ "$(echo "$repo_props" | jq 'length')" -gt 0 ]]; then
    save_and_upload "$repo_props" \
      "${props_dir}/repo-property-values.json" \
      "backups/${DATE_STAMP}/custom-properties/repo-property-values.json"
    log "  [properties] ✓ repo property values"
  fi
}

###############################################################################
# Generate backup manifest
###############################################################################

generate_manifest() {
  log "=== Generating backup manifest ==="
  local manifest="${BACKUP_ROOT}/manifest.json"

  local repos
  repos=$(get_all_repos)
  local repo_count
  repo_count=$(echo "$repos" | jq 'length')

  jq -n \
    --arg org "$GITHUB_ORG" \
    --arg date "$DATE_STAMP" \
    --arg storage "${AZURE_STORAGE_ACCOUNT}/${AZURE_STORAGE_CONTAINER}" \
    --argjson repo_count "$repo_count" \
    '{
      organization: $org,
      backup_date: $date,
      storage_destination: $storage,
      backup_path: ("backups/" + $date),
      repository_count: $repo_count,
      backup_targets: [
        "repositories",
        "wikis",
        "projects-v2",
        "artifacts",
        "releases-and-assets",
        "packages",
        "issues-and-pull-requests",
        "discussions",
        "workflow-logs",
        "actions-variables-and-environments",
        "security-alerts",
        "teams-and-memberships",
        "webhooks",
        "branch-protections-and-rulesets",
        "custom-properties"
      ]
    }' > "$manifest"

  upload_to_blob "$manifest" "backups/${DATE_STAMP}/manifest.json"
  log "  [manifest] ✓ uploaded"
}

###############################################################################
# Main
###############################################################################

main() {
  log "============================================"
  log "GitHub Org Full Backup: ${GITHUB_ORG}"
  log "Date: ${DATE_STAMP}"
  if [[ -n "${GITHUB_APP_ID}" ]]; then
    log "Auth: GitHub App (ID: ${GITHUB_APP_ID})"
  else
    log "Auth: Token (pre-configured)"
  fi
  log "Destination: ${AZURE_STORAGE_ACCOUNT}/${AZURE_STORAGE_CONTAINER}"
  log "Parallel jobs: ${PARALLEL_JOBS}"
  log "============================================"

  # Initialize token (generate from App credentials or validate existing)
  refresh_github_token

  backup_all_repos          #  1. Repositories (mirror + LFS)
  backup_all_wikis          #  2. Wikis
  backup_projects           #  3. GitHub Projects v2
  backup_all_artifacts      #  4. Actions Artifacts
  backup_all_releases       #  5. Releases & Assets
  backup_all_packages       #  6. GitHub Packages
  backup_all_issues         #  7. Issues & PRs
  backup_discussions        #  8. Discussions
  backup_all_workflow_logs  #  9. Workflow Logs
  backup_actions_config     # 10. Actions Variables & Environments
  backup_security_alerts    # 11. Security Alerts
  backup_teams              # 12. Teams & Memberships
  backup_webhooks           # 13. Webhooks
  backup_protection_rules   # 14. Branch Protections & Rulesets
  backup_custom_properties  # 15. Custom Properties
  generate_manifest         # Manifest

  # Cleanup temp files
  rm -rf "${BACKUP_ROOT}"

  log "============================================"
  log "Backup complete! (warnings: ${BACKUP_WARNINGS})"
  log "============================================"
}

main "$@"
