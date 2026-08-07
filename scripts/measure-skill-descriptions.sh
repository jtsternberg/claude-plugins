#!/usr/bin/env bash

# Measure the frontmatter description budget used by marketplace skills.
# Requires only Bash, awk, find, sort, tr, and wc (available on macOS and Linux).

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
plugins=()
skills=()
description_chars=()
descriptions=()

parse_description() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function unescape_double_quoted(value, result, i, character, next_character) {
      value = substr(value, 2, length(value) - 2)
      result = ""

      for (i = 1; i <= length(value); i++) {
        character = substr(value, i, 1)
        if (character != "\\" || i == length(value)) {
          result = result character
          continue
        }

        next_character = substr(value, i + 1, 1)
        if (next_character == "n") {
          result = result "\n"
        } else if (next_character == "r") {
          result = result "\r"
        } else if (next_character == "t") {
          result = result "\t"
        } else {
          result = result next_character
        }
        i++
      }

      return result
    }

    $0 == "---" {
      if (!in_frontmatter) {
        in_frontmatter = 1
        next
      }
      exit
    }

    !in_frontmatter {
      next
    }

    collecting {
      if ($0 ~ /^[[:space:]]/) {
        value = $0
        sub(/^[[:space:]]+/, "", value)

        if (style == "|") {
          if (description != "") {
            description = description "\n"
          }
          description = description value
        } else if (value == "") {
          if (description != "") {
            description = description "\n"
          }
          folded_break = 1
        } else {
          if (description != "" && !folded_break) {
            description = description " "
          }
          description = description value
          folded_break = 0
        }
        next
      }

      collecting = 0
    }

    /^description:[[:space:]]*/ {
      value = $0
      sub(/^description:[[:space:]]*/, "", value)
      value = trim(value)

      if (value ~ /^[>|][+-]?$/) {
        style = substr(value, 1, 1)
        collecting = 1
        folded_break = 0
        next
      }

      if (value ~ /^".*"$/) {
        description = unescape_double_quoted(value)
      } else if (value ~ /^'\''.*'\''$/) {
        description = substr(value, 2, length(value) - 2)
        gsub(/'\'''\''/, "'\''", description)
      } else {
        description = value
      }
    }

    END {
      print description
    }
  ' "$1"
}

skill_count=0
grand_total=0

while IFS= read -r skill_file; do
  relative_path=${skill_file#"$repo_root/plugins/"}
  plugin=${relative_path%%/*}
  skill=${relative_path#*/skills/}
  skill=${skill%/SKILL.md}
  description=$(parse_description "$skill_file")

  if [ -z "$description" ]; then
    printf 'Missing frontmatter description: %s\n' "$skill_file" >&2
    exit 1
  fi

  char_count=$(printf '%s' "$description" | wc -m | tr -d '[:space:]')
  display_description=$(printf '%s' "$description" | tr '\n\t' '  ')
  plugins+=("$plugin")
  skills+=("$skill")
  description_chars+=("$char_count")
  descriptions+=("$display_description")
  skill_count=$((skill_count + 1))
  grand_total=$((grand_total + char_count))
done < <(find "$repo_root/plugins" -path '*/skills/*/SKILL.md' -type f -print | sort)

if [ "$skill_count" -ne 60 ]; then
  printf 'Expected 60 skill descriptions; parsed %s.\n' "$skill_count" >&2
  exit 1
fi

budget_percent=$(awk -v total="$grand_total" 'BEGIN { printf "%.2f", (total / 8000) * 100 }')

emit_records() {
  local index

  for ((index = 0; index < ${#plugins[@]}; index++)); do
    printf '%s\t%s\t%s\t%s\n' \
      "${plugins[index]}" \
      "${skills[index]}" \
      "${description_chars[index]}" \
      "${descriptions[index]}"
  done
}

printf 'Skills parsed: %s\n' "$skill_count"
printf 'Skill descriptions, sorted by char count (descending)\n'
printf 'plugin\tskill\tdescription chars\tdescription\n'
emit_records | sort -t "$(printf '\t')" -k3,3nr -k1,1 -k2,2

printf '\nPer-plugin subtotals\n'
printf 'plugin\tskills\tdescription chars\n'
for plugin_dir in "$repo_root"/plugins/*; do
  [ -d "$plugin_dir" ] || continue
  plugin=${plugin_dir##*/}
  plugin_stats=$(emit_records | awk -F '\t' -v wanted="$plugin" '
    $1 == wanted {
      skills++
      total += $3
    }
    END {
      printf "%d\t%d", skills + 0, total + 0
    }
  ')
  printf '%s\t%s\n' "$plugin" "$plugin_stats"
done | sort -t "$(printf '\t')" -k1,1

printf '\nGrand total: %s chars (%.2f%% of the 8,000-char budget)\n' "$grand_total" "$budget_percent"

printf '\nDescriptions over 500 chars\n'
printf 'plugin\tskill\tdescription chars\n'
emit_records | sort -t "$(printf '\t')" -k3,3nr -k1,1 -k2,2 |
  awk -F '\t' '$3 > 500 { printf "%s\t%s\t%s\n", $1, $2, $3; found = 1 } END { if (!found) print "none" }'
