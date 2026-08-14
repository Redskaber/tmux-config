#!/usr/bin/env bash
# @file: lib/store.sh
# @author: redskaber
# @desc: Persistence layer — CRUD for snapshots on disk, plus a queryable
#        index cache (index.json) and atomic writes.
# @arch: Domain Layer (persistence) — depends on lib/core.sh.
# @deps: bash 4.4+, jq
# @sourcing: requires core.sh sourced first.

[[ -n "${_TX_STORE_LOADED:-}" ]] && return 0
_TX_STORE_LOADED=1

# ============================================================
# === Init                                                 ===
# ============================================================

store_init() {
  core_ensure_store_dirs
  local idx groups
  idx="$(core_index_file)"
  groups="$(core_groups_file)"
  # Recreate index.json if missing OR corrupt (self-healing).
  if [[ ! -f "$idx" ]] || ! jq -e '.snapshots' "$idx" >/dev/null 2>&1; then
    printf '%s\n' "$(store_empty_index_json)" > "$idx"
  fi
  if [[ ! -f "$groups" ]] || ! jq -e '.groups' "$groups" >/dev/null 2>&1; then
    printf '%s\n' "$(store_empty_groups_json)" > "$groups"
  fi
}

store_empty_index_json() {
  jq -n --arg schema "$TX_SCHEMA_INDEX" --arg at "$(core_now_iso)" \
    '{schema:$schema, updated_at:$at, snapshots:[]}'
}

store_empty_groups_json() {
  jq -n --arg schema "$TX_SCHEMA_GROUPS" --arg at "$(core_now_iso)" \
    '{schema:$schema, updated_at:$at, groups:[]}'
}

# ============================================================
# === Atomic write                                         ===
# ============================================================

# _atomic_write <path> <content> — write via temp file + rename; clean up on failure.
_atomic_write() {
  local path="$1" content="$2"
  local dir; dir="$(dirname "$path")"
  local tmp; tmp="$(mktemp -p "$dir" .tmp.XXXXXX)"
  # Ensure temp file is removed if printf or mv fails (set -e would exit without cleanup).
  if ! printf '%s' "$content" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

# ============================================================
# === Save                                                 ===
# ============================================================

# store_save <captured_json> <name> <group> <tags_csv> <description> [force=0]
# Echoes the snapshot id on success.
store_save() {
  local captured="$1" name="$2" group="$3" tags_csv="$4" desc="$5" force="${6:-0}"

  store_init

  core_validate_name "$name" || return 1
  if [[ -n "$group" ]]; then
    core_validate_name "$group" || return 1
  fi
  # validate tags
  local t
  if [[ -n "$tags_csv" ]]; then
    IFS=',' read -ra _tarr <<< "$tags_csv"
    for t in "${_tarr[@]}"; do
      t="${t// /}"
      [[ -n "$t" ]] && { core_validate_tag "$t" || { core_error "invalid tag: $t"; return 1; }; }
    done
  fi

  # Resolve group default
  [[ -z "$group" ]] && group="$TX_GROUP_DEFAULT"

  # Name uniqueness
  local existing_id=""
  existing_id="$(store_lookup_name "$name")"
  if [[ -n "$existing_id" ]]; then
    if (( force )); then
      core_warn "overwriting existing snapshot '$name' (id=$existing_id)"
    else
      core_die "a snapshot named '$name' already exists (id=$existing_id). Use --force to overwrite." 4
    fi
  fi

  # Determine id: reuse if overwriting, else new.
  local id
  if [[ -n "$existing_id" && "$force" == "1" ]]; then
    id="$existing_id"
  else
    id="$(core_gen_id)"
    # guarantee uniqueness of id
    while [[ -f "$(core_snapshots_dir)/${id}.json" ]]; do id="$(core_gen_id)"; done
  fi

  # Compute stats (flatten windows/panes across sessions)
  local stats
  stats="$(echo "$captured" | jq -c '{
    sessions: (.sessions | length),
    windows: ([.sessions[].windows[]] | length),
    panes: ([.sessions[].windows[].panes[]] | length)
  }')"

  # Tags → JSON array (dedup). Use -Rn + --arg so empty input still yields [].
  # (printf '%s' "" gives 0 bytes → jq -R reads no lines → empty output;
  #  --argjson "" then fails. -Rn avoids reading stdin entirely.)
  local tags_json
  tags_json="$(jq -Rn --arg s "$tags_csv" '
    ($s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0)) | unique)
  ')"

  # Merge user meta into the captured snapshot.
  local saved
  saved="$(echo "$captured" | jq \
    --arg id "$id" \
    --arg name "$name" \
    --arg group "$group" \
    --argjson tags "$tags_json" \
    --arg desc "$desc" \
    --arg created "$(core_now_iso)" \
    --argjson stats "$stats" \
    '.meta += {
        id:$id, name:$name, group:$group, tags:$tags,
        description:$desc, created_at:$created
      }
      | .stats = $stats')"

  # Write file atomically.
  _atomic_write "$(core_snapshots_dir)/${id}.json" "$saved"

  # Update index.
  store_index_upsert "$saved"
  # Ensure group registered.
  store_group_ensure "$group"

  printf '%s\n' "$id"
}

# ============================================================
# === Load                                                 ===
# ============================================================

# store_load_by_id <id> → echo full snapshot JSON (empty if missing).
store_load_by_id() {
  local id="$1"
  local f="$(core_snapshots_dir)/${id}.json"
  [[ -f "$f" ]] || { echo ""; return 1; }
  cat "$f"
}

# store_load <name_or_id> → echo full snapshot JSON.
store_load() {
  local key="$1"
  local id
  id="$(store_resolve "$key")" || return 1
  store_load_by_id "$id"
}

# ============================================================
# === Resolve name/id                                      ===
# ============================================================

# store_resolve <name_or_id> → echo id (exit 1 if not found).
store_resolve() {
  local key="$1"
  [[ -z "$key" ]] && return 1
  # If it looks like an id and the file exists, use directly.
  if [[ "$key" =~ ^[0-9a-f]{8}$ ]] && [[ -f "$(core_snapshots_dir)/${key}.json" ]]; then
    printf '%s\n' "$key"
    return 0
  fi
  # Otherwise look up by name in the index.
  store_lookup_name "$key"
}

# store_lookup_name <name> → echo id (empty if not found).
store_lookup_name() {
  local name="$1"
  store_init
  jq -r --arg n "$name" '.snapshots[] | select(.name==$n) | .id' "$(core_index_file)" 2>/dev/null | head -1
}

# ============================================================
# === Index                                                ===
# ============================================================

# store_index_upsert <snapshot_json> — add/replace an entry in index.json.
store_index_upsert() {
  local snap="$1"
  store_init
  local entry
  entry="$(echo "$snap" | jq -c '{
    id:.meta.id, name:.meta.name, group:.meta.group, tags:.meta.tags,
    description:.meta.description, created_at:.meta.created_at, stats:.stats
  }')"
  local idx; idx="$(core_index_file)"
  local updated
  updated="$(jq --argjson e "$entry" --arg at "$(core_now_iso)" '
    .snapshots = ([.snapshots[] | select(.id != $e.id)] + [$e])
    | .updated_at = $at
  ' "$idx")"
  _atomic_write "$idx" "$updated"
}

# store_index_remove <id>
store_index_remove() {
  local id="$1"
  store_init
  local idx; idx="$(core_index_file)"
  local updated
  updated="$(jq --arg id "$id" --arg at "$(core_now_iso)" '
    .snapshots = ([.snapshots[] | select(.id != $id)])
    | .updated_at = $at
  ' "$idx")"
  _atomic_write "$idx" "$updated"
}

# store_index_rebuild — scan all snapshot files, rebuild index.json.
store_index_rebuild() {
  core_ensure_store_dirs
  local idx; idx="$(core_index_file)"
  local dir; dir="$(core_snapshots_dir)"
  local entries=()
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local e
    e="$(jq -c '{
      id:.meta.id, name:.meta.name, group:.meta.group, tags:.meta.tags,
      description:.meta.description, created_at:.meta.created_at, stats:.stats
    }' "$f" 2>/dev/null)" || continue
    entries+=("$e")
  done < <(find "$dir" -maxdepth 1 -name '*.json' -type f | sort)

  # Build the array in ONE jq invocation (O(n) instead of O(n²) fork-per-entry).
  local arr
  if (( ${#entries[@]} == 0 )); then
    arr='[]'
  else
    arr="$(printf '%s\n' "${entries[@]}" | jq -cs '.')"
  fi
  local updated
  updated="$(jq -n --arg schema "$TX_SCHEMA_INDEX" --arg at "$(core_now_iso)" --argjson arr "$arr" \
    '{schema:$schema, updated_at:$at, snapshots:($arr | sort_by(.created_at) | reverse)}')"
  _atomic_write "$idx" "$updated"
  core_info "index rebuilt: ${#entries[@]} snapshot(s)"
}

# store_index_ensure — rebuild if index missing or stale (file count mismatch).
store_index_ensure() {
  store_init
  local idx; idx="$(core_index_file)"
  local dir; dir="$(core_snapshots_dir)"
  local file_count idx_count
  file_count="$(find "$dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  idx_count="$(jq '.snapshots | length' "$idx" 2>/dev/null || echo 0)"
  if [[ -z "$idx_count" || "$file_count" != "$idx_count" ]]; then
    core_debug "index stale ($file_count files vs $idx_count indexed) — rebuilding"
    store_index_rebuild
  fi
}

# ============================================================
# === List / Query                                         ===
# ============================================================

# store_list [group] [tag] [name_pattern] → echo JSON array of index entries.
# ALWAYS sorted newest-first by created_at (the natural human expectation:
# `tx last`, the picker, and `tx ls` all want most-recent first).
store_list() {
  local group="${1:-}" tag="${2:-}" pattern="${3:-}"
  store_index_ensure
  local idx; idx="$(core_index_file)"
  local q='.snapshots'
  local args=()
  # NOTE: jq variables ($g/$t/$p) MUST be escaped (\$) so bash does not try to
  # expand them (set -u would otherwise abort with "unbound variable").
  if [[ -n "$group" ]]; then q="$q | map(select(.group==\$g))"; args+=(--arg g "$group"); fi
  if [[ -n "$tag" ]];   then q="$q | map(select(.tags | index(\$t)))"; args+=(--arg t "$tag"); fi
  if [[ -n "$pattern" ]]; then q="$q | map(select(.name | test(\$p; \"i\")))"; args+=(--arg p "$pattern"); fi
  # Sort newest-first regardless of insertion order in the index.
  q="$q | sort_by(.created_at) | reverse"
  jq -c "${args[@]}" "$q" "$idx"
}

# ============================================================
# === Remove                                               ===
# ============================================================

# store_remove <id> — delete file + index entry. Returns 0/1.
store_remove() {
  local id="$1"
  local f="$(core_snapshots_dir)/${id}.json"
  if [[ ! -f "$f" ]]; then
    core_error "no snapshot with id=$id"
    return 1
  fi
  rm -f "$f"
  store_index_remove "$id"
  return 0
}

# ============================================================
# === Update meta (rename / retag / regroup / describe)    ===
# ============================================================

# store_update <id> <field> <value>
# field ∈ {name, group, description}; for tags use store_update_tags.
store_update() {
  local id="$1" field="$2" value="$3"
  local f="$(core_snapshots_dir)/${id}.json"
  [[ -f "$f" ]] || { core_error "no snapshot with id=$id"; return 1; }
  case "$field" in
    name|group) core_validate_name "$value" || return 1 ;;
    description) ;;  # free-form, no validation
    *) core_error "unsupported field: $field"; return 1 ;;
  esac
  local updated
  updated="$(jq --arg v "$value" --arg f "$field" '.meta[$f]=$v' "$f")"
  _atomic_write "$f" "$updated"
  store_index_rebuild
}

# store_update_tags <id> <add_csv> <remove_csv>
store_update_tags() {
  local id="$1" add_csv="$2" remove_csv="$3"
  local f="$(core_snapshots_dir)/${id}.json"
  [[ -f "$f" ]] || { core_error "no snapshot with id=$id"; return 1; }
  local add_json remove_json
  # -Rn + --arg: robust against empty strings (see store_save for rationale).
  add_json="$(jq -Rn --arg s "$add_csv" '($s|split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))|unique)')"
  remove_json="$(jq -Rn --arg s "$remove_csv" '($s|split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))|unique)')"
  local updated
  updated="$(jq --argjson add "$add_json" --argjson rem "$remove_json" '
    .meta.tags = ((.meta.tags + $add) - $rem | unique)
  ' "$f")"
  _atomic_write "$f" "$updated"
  store_index_rebuild
}

# ============================================================
# === Group registry                                       ===
# ============================================================

store_group_ensure() {
  local name="$1"
  [[ -z "$name" ]] && return 0
  local gf; gf="$(core_groups_file)"
  store_init
  local exists
  exists="$(jq -r --arg n "$name" '.groups[] | select(.name==$n) | .name' "$gf" 2>/dev/null)"
  [[ -n "$exists" ]] && return 0
  local updated
  updated="$(jq --arg n "$name" --arg at "$(core_now_iso)" \
    '.groups += [{name:$n, description:"", created_at:$at}]' "$gf")"
  _atomic_write "$gf" "$updated"
}

store_group_list() {
  store_init
  local gf; gf="$(core_groups_file)"
  jq -c '.groups | sort_by(.name)' "$gf"
}

store_group_remove() {
  local name="$1"
  local gf; gf="$(core_groups_file)"
  store_init
  local updated
  updated="$(jq --arg n "$name" '.groups = ([.groups[] | select(.name != $n)])' "$gf")"
  _atomic_write "$gf" "$updated"
}

store_group_rename() {
  local old="$1" new="$2"
  local gf; gf="$(core_groups_file)"
  store_init
  local updated
  updated="$(jq --arg o "$old" --arg n "$new" '.groups = (.groups | map(if .name==$o then .name=$n else . end))' "$gf")"
  _atomic_write "$gf" "$updated"
  # Reassign snapshots in the group.
  local idx; idx="$(core_index_file)"
  local ids
  ids="$(jq -r --arg o "$old" '.snapshots[] | select(.group==$o) | .id' "$idx")"
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && store_update "$id" group "$new" >/dev/null
  done <<< "$ids"
}
