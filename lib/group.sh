#!/usr/bin/env bash
# @file: lib/group.sh
# @author: redskaber
# @desc: Group orchestration — command-level group lifecycle with validation,
#        member accounting, and safe reassignment semantics.
# @arch: Domain Layer — depends on lib/core.sh + lib/store.sh.
# @sourcing: requires core.sh + store.sh sourced first.

[[ -n "${_TX_GROUP_LOADED:-}" ]] && return 0
_TX_GROUP_LOADED=1

# group_create <name> [description]
group_create() {
  local name="$1" desc="${2:-}"
  core_validate_name "$name" || return 1
  (( ${#name} > 32 )) && { core_error "group name too long (max 32)"; return 1; }
  store_init
  local existing
  existing="$(store_group_lookup "$name")"
  if [[ -n "$existing" ]]; then
    core_warn "group already exists: $name"
    return 0
  fi
  # Insert with description (reuse store.sh's _atomic_write for consistency).
  local gf; gf="$(core_groups_file)"
  local updated
  updated="$(jq --arg n "$name" --arg d "$desc" --arg at "$(core_now_iso)" \
    '.groups += [{name:$n, description:$d, created_at:$at}]' "$gf")"
  _atomic_write "$gf" "$updated"
  core_ok "created group: $name"
}

store_group_lookup() {
  local name="$1"
  store_init
  jq -r --arg n "$name" '.groups[] | select(.name==$n) | .name' "$(core_groups_file)" 2>/dev/null | head -1
}

# group_list — echo JSON array: [{name, description, created_at, count}]
group_list() {
  store_init
  local gf; gf="$(core_groups_file)"
  local idx; idx="$(core_index_file)"
  jq -n --slurpfile g "$gf" --slurpfile i "$idx" '
    ($g[0].groups) as $gs
    | ($i[0].snapshots) as $snaps
    | $gs | map(. + {count: ([$snaps[] | select(.group==.name)] | length)})
    | sort_by(.name)
  '
}

# group_remove <name> [mode]  mode ∈ {reassign(default), delete}
#   reassign → move member snapshots to "default" group
#   delete   → delete member snapshots too
group_remove() {
  local name="$1" mode="${2:-reassign}"
  [[ "$name" == "$TX_GROUP_DEFAULT" || "$name" == "$TX_GROUP_AUTO" ]] && \
    { core_error "cannot remove reserved group: $name"; return 1; }

  local existing; existing="$(store_group_lookup "$name")"
  [[ -n "$existing" ]] || { core_error "no such group: $name"; return 1; }

  # Find members.
  local idx; idx="$(core_index_file)"
  local members
  members="$(jq -r --arg g "$name" '.snapshots[] | select(.group==$g) | .id' "$idx")"

  local count=0
  [[ -n "$members" ]] && count="$(printf '%s\n' "$members" | grep -c . || true)"

  if (( count > 0 )); then
    if [[ "$mode" == "delete" ]]; then
      core_warn "deleting $count snapshot(s) in group '$name'"
      local id
      while IFS= read -r id; do
        [[ -n "$id" ]] && store_remove "$id" >/dev/null || true
      done <<< "$members"
    else
      core_warn "reassigning $count snapshot(s) from '$name' to 'default'"
      local id
      while IFS= read -r id; do
        [[ -n "$id" ]] && store_update "$id" group "$TX_GROUP_DEFAULT" >/dev/null || true
      done <<< "$members"
    fi
  fi

  store_group_remove "$name"
  core_ok "removed group: $name"
}

# group_rename <old> <new>
group_rename() {
  local old="$1" new="$2"
  core_validate_name "$new" || return 1
  (( ${#new} > 32 )) && { core_error "group name too long (max 32)"; return 1; }
  local existing; existing="$(store_group_lookup "$old")"
  [[ -n "$existing" ]] || { core_error "no such group: $old"; return 1; }
  local target; target="$(store_group_lookup "$new")"
  [[ -z "$target" ]] || { core_error "group already exists: $new"; return 1; }
  store_group_rename "$old" "$new"
  core_ok "renamed group: $old → $new"
}

# group_show <name> — echo JSON with group info + member list.
group_show() {
  local name="$1"
  store_init
  local gf; gf="$(core_groups_file)"
  local idx; idx="$(core_index_file)"
  jq -n --arg n "$name" --slurpfile g "$gf" --slurpfile i "$idx" '
    ([$g[0].groups[] | select(.name==$n)] | .[0] // {name:$n, description:null, created_at:null}) as $info
    | {group:$info, members: ([$i[0].snapshots[] | select(.group==$n)])}
  '
}
