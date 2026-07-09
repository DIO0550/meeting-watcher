#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_FILE="$REPO_ROOT/meeting-watcher/meeting-watcher.xcodeproj/project.pbxproj"
FORBIDDEN_TARGETS=("meeting-watcher" "meeting-watcherTests")
FORBIDDEN_SOURCE_DIRS=(
  "$REPO_ROOT/meeting-watcher/meeting-watcher"
  "$REPO_ROOT/meeting-watcher/meeting-watcherTests"
)

failures=0

report_failure() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

check_forbidden_imports() {
  local dir matches pattern
  pattern="^[[:space:]]*(@[^[:space:]]+[[:space:]]+)*import[[:space:]]+MeetingSignal([[:space:]]|$)"
  for dir in "${FORBIDDEN_SOURCE_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    matches="$(find "$dir" -type f -name "*.swift" -exec grep -HnE "$pattern" {} + || true)"
    if [[ -n "$matches" ]]; then
      printf "%s\n" "$matches"
      report_failure "MeetingSignal import is forbidden in watcher-side sources: $dir"
    fi
  done
}

object_block() {
  local id="$1"
  awk -v id="$id" '
    $1 == id && /=[[:space:]]*\{/ { in_block=1 }
    in_block { print }
    in_block && /};/ { exit }
  ' "$PROJECT_FILE"
}

native_target_id() {
  local name="$1"
  awk -v name="$name" '
    !in_block && /^[[:space:]]*[A-Z0-9]{24}[[:space:]]+\/\*/ {
      if ($0 ~ /};/) { next }
      id=$1
      block=$0
      in_block=1
      next
    }
    in_block {
      block = block "\n" $0
      if ($0 ~ /^[[:space:]]*};/) {
        quoted = "name = \"" name "\";"
        bare = "name = " name ";"
        if (block ~ /isa = PBXNativeTarget;/ && (index(block, quoted) || index(block, bare))) {
          print id
          exit
        }
        block=""
        id=""
        in_block=0
      }
    }
  ' "$PROJECT_FILE"
}

ids_in_named_list() {
  local list_name="$1"
  awk -v list="$list_name" '
    index($0, list " = (") { in_list=1; next }
    in_list && /^[[:space:]]*\);/ { exit }
    in_list {
      line=$0
      while (match(line, /[A-Z0-9]{24}/)) {
        print substr(line, RSTART, RLENGTH)
        line=substr(line, RSTART + RLENGTH)
      }
    }
  '
}

framework_phase_links_meeting_signal() {
  local phase_id="$1"
  local build_file_id file_ref_id file_ref_block
  for build_file_id in $(object_block "$phase_id" | ids_in_named_list files); do
    file_ref_id="$(object_block "$build_file_id" | sed -nE 's/.*fileRef = ([A-Z0-9]{24}).*/\1/p' | head -1)"
    [[ -n "$file_ref_id" ]] || continue
    file_ref_block="$(object_block "$file_ref_id")"
    if printf '%s\n' "$file_ref_block" | grep -Eq 'path = "?MeetingSignal[.]framework"?;'; then
      return 0
    fi
  done
  return 1
}

target_dependency_resolves_to_meeting_signal() {
  local dep_id="$1"
  local dep_block target_id proxy_id remote_id remote_info
  dep_block="$(object_block "$dep_id")"
  target_id="$(printf '%s\n' "$dep_block" | sed -nE 's/.*target = ([A-Z0-9]{24}).*/\1/p' | head -1)"
  if [[ -n "$target_id" ]] && object_block "$target_id" | grep -Eq 'name = "?MeetingSignal"?;'; then
    return 0
  fi

  proxy_id="$(printf '%s\n' "$dep_block" | sed -nE 's/.*targetProxy = ([A-Z0-9]{24}).*/\1/p' | head -1)"
  [[ -n "$proxy_id" ]] || return 1
  remote_id="$(object_block "$proxy_id" | sed -nE 's/.*remoteGlobalIDString = ([A-Z0-9]{24}).*/\1/p' | head -1)"
  remote_info="$(object_block "$proxy_id" | sed -nE 's/.*remoteInfo = "?([^";]+)"?;.*/\1/p' | head -1)"
  [[ "$remote_info" == "MeetingSignal" ]] && return 0
  [[ -n "$remote_id" ]] && object_block "$remote_id" | grep -q 'name = MeetingSignal;'
}

check_project_dependencies() {
  if [[ ! -f "$PROJECT_FILE" ]]; then
    report_failure "project file not found: $PROJECT_FILE"
    return
  fi

  local target target_id target_block phase_id dep_id
  for target in "${FORBIDDEN_TARGETS[@]}"; do
    target_id="$(native_target_id "$target")"
    if [[ -z "$target_id" ]]; then
      report_failure "target not found: $target"
      continue
    fi

    target_block="$(object_block "$target_id")"
    for phase_id in $(printf '%s\n' "$target_block" | ids_in_named_list buildPhases); do
      if object_block "$phase_id" | grep -q 'isa = PBXFrameworksBuildPhase;' && framework_phase_links_meeting_signal "$phase_id"; then
        report_failure "target $target must not link MeetingSignal.framework"
      fi
    done

    for dep_id in $(printf '%s\n' "$target_block" | ids_in_named_list dependencies); do
      if target_dependency_resolves_to_meeting_signal "$dep_id"; then
        report_failure "target $target must not depend on MeetingSignal"
      fi
    done
  done
}

check_forbidden_imports
check_project_dependencies
exit "$failures"
