#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_FILE="$REPO_ROOT/meeting-watcher/meeting-watcher.xcodeproj/project.pbxproj"
FORBIDDEN_TARGETS=("MeetingWatcher" "MeetingWatcherTests")
FORBIDDEN_SOURCE_DIRS=(
  "$REPO_ROOT/meeting-watcher/MeetingWatcher"
  "$REPO_ROOT/meeting-watcher/MeetingWatcherTests"
)

failures=0

report_failure() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

swift_files_importing_meeting_signal() {
  perl -0777 -e '
    sub sanitized_swift_source {
      my ($source) = @_;
      my $result = "";
      my $length = length($source);
      my $index = 0;
      my $block_comment_depth = 0;

      while ($index < $length) {
        my $pair = substr($source, $index, 2);

        if ($block_comment_depth > 0) {
          if ($pair eq "/*") {
            $block_comment_depth += 1;
            $result .= "  ";
            $index += 2;
          } elsif ($pair eq "*/") {
            $block_comment_depth -= 1;
            $result .= "  ";
            $index += 2;
          } else {
            my $character = substr($source, $index, 1);
            $result .= $character eq "\n" ? "\n" : " ";
            $index += 1;
          }
          next;
        }

        if ($pair eq "//") {
          while ($index < $length && substr($source, $index, 1) ne "\n") {
            $result .= " ";
            $index += 1;
          }
          next;
        }

        if ($pair eq "/*") {
          $block_comment_depth = 1;
          $result .= "  ";
          $index += 2;
          next;
        }

        my $remaining = substr($source, $index);
        if ($remaining =~ /\A(\#*)(""")/ || $remaining =~ /\A(\#*)(")/) {
          my $hashes = $1;
          my $quotes = $2;
          my $opening_length = length($hashes) + length($quotes);
          my $closing = $quotes . $hashes;
          $result .= " " x $opening_length;
          $index += $opening_length;

          while ($index < $length) {
            my $character = substr($source, $index, 1);
            if (substr($source, $index, length($closing)) eq $closing) {
              my $is_escaped = 0;
              if ($hashes eq "") {
                my $backslash_count = 0;
                my $lookbehind = $index - 1;
                while ($lookbehind >= 0 && substr($source, $lookbehind, 1) eq "\\") {
                  $backslash_count += 1;
                  $lookbehind -= 1;
                }
                $is_escaped = $backslash_count % 2;
              }
              if (!$is_escaped) {
                $result .= " " x length($closing);
                $index += length($closing);
                last;
              }
            }
            $result .= $character eq "\n" ? "\n" : " ";
            $index += 1;
          }
          next;
        }

        $result .= substr($source, $index, 1);
        $index += 1;
      }

      return $result;
    }

    while (<>) {
      my $source = sanitized_swift_source($_);
      if ($source =~ /(?:\A|[;\n])[[:space:]]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:[[:space:]]*\([^;\n]*\))?[[:space:]]*)*(?:(?:public|internal|package|private|fileprivate)[[:space:]]+)?import[[:space:]]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?MeetingSignal(?:\b|\.)/) {
        print "$ARGV\n";
      }
    }
  ' "$@"
}

check_forbidden_imports() {
  local dir matches file
  local swift_files=()
  for dir in "${FORBIDDEN_SOURCE_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    swift_files=()
    while IFS= read -r -d "" file; do
      swift_files+=("$file")
    done < <(find "$dir" -type f -name "*.swift" -print0)

    matches=""
    if [[ ${#swift_files[@]} -gt 0 ]]; then
      matches="$(swift_files_importing_meeting_signal "${swift_files[@]}")"
    fi
    if [[ -n "$matches" ]]; then
      printf "%s\n" "$matches"
      report_failure "MeetingSignal import is forbidden in MeetingWatcher sources: $dir"
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
  [[ -n "$remote_id" ]] && object_block "$remote_id" | grep -Eq 'name = "?MeetingSignal"?;'
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
