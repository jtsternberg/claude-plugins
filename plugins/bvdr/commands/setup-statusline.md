---
description: Interactive statusline configuration wizard for Claude Code. Asks about folder display, colors, git info, context bar, and last message display, then generates a custom statusline script.
---

# Statusline Setup Wizard

This skill walks you through configuring a custom Claude Code statusline with interactive questions.

## What Gets Configured

- **Folder display**: Show/hide, full path vs last folder(s)
- **Git branch info**: Uncommitted files, sync status
- **Context bar**: Token usage visualization
- **Color theme**: Choose accent color
- **Last message**: Second line showing your last prompt

## Example Output

```
📁myproject | 🔀main (2 files uncommitted, synced) | [███░░░░░░░] 15% of 200k tokens used
💬 Can you check if the edd license plugin is enabled...
```

---

## Configuration Flow

When this skill is invoked, use the AskUserQuestion tool to gather preferences. Ask all questions in a SINGLE AskUserQuestion call with multiple questions.

### Questions to Ask

Use AskUserQuestion with these 4 questions:

```json
{
  "questions": [
    {
      "question": "How should the folder name be displayed?",
      "header": "Folder",
      "options": [
        {"label": "Last folder only (Recommended)", "description": "Shows just 'myproject' - clean and minimal"},
        {"label": "Last 2 folders", "description": "Shows 'Sites/myproject' - more context"},
        {"label": "Full path", "description": "Shows '/Users/you/Sites/myproject' - complete path"},
        {"label": "Don't show folder", "description": "Hide folder from statusline"}
      ],
      "multiSelect": false
    },
    {
      "question": "What accent color would you like for the statusline?",
      "header": "Color",
      "options": [
        {"label": "Blue (Recommended)", "description": "Clean, professional look"},
        {"label": "Orange", "description": "Warm, energetic feel"},
        {"label": "Green", "description": "Natural, calming tone"},
        {"label": "Gray", "description": "Minimal, monochrome style"}
      ],
      "multiSelect": false
    },
    {
      "question": "Show git branch with status info?",
      "header": "Git",
      "options": [
        {"label": "Yes with full status (Recommended)", "description": "Branch + uncommitted count + sync status"},
        {"label": "Branch name only", "description": "Just the branch name, no extra info"},
        {"label": "No git info", "description": "Hide git information completely"}
      ],
      "multiSelect": false
    },
    {
      "question": "Show your last message on a second line?",
      "header": "Last msg",
      "options": [
        {"label": "Yes (Recommended)", "description": "Shows 💬 with your last prompt - helps identify conversations"},
        {"label": "No", "description": "Single line statusline only"}
      ],
      "multiSelect": false
    }
  ]
}
```

---

## After Gathering Preferences

Once the user answers, generate a statusline script based on their choices.

### Script Location

Determine where to save the script:
1. Check if `~/.claude-work/` exists (alternative Claude Code config) → use `~/.claude-work/statusline-command.sh`
2. Otherwise use `~/.claude/statusline-command.sh`

### Color Mapping

Map the user's color choice to ANSI codes:
- **Blue**: `\033[38;5;74m`
- **Orange**: `\033[38;5;173m`
- **Green**: `\033[38;5;71m`
- **Gray**: `\033[38;5;245m`

Additional colors used:
- Reset: `\033[0m`
- Gray text: `\033[38;5;245m`
- Empty bar: `\033[38;5;238m`

### Script Template

Generate a bash script with these components based on user choices:

```bash
#!/bin/bash

# Color codes
C_RESET='\033[0m'
C_GRAY='\033[38;5;245m'
C_BAR_EMPTY='\033[38;5;238m'
C_ACCENT='<CHOSEN_COLOR>'

input=$(cat)

# Extract directory
cwd=$(echo "$input" | jq -r '.cwd // empty')
```

**Folder logic based on choice:**
- Last folder only: `dir=$(basename "$cwd" 2>/dev/null || echo "?")`
- Last 2 folders: `dir=$(echo "$cwd" | rev | cut -d'/' -f1-2 | rev)`
- Full path: `dir="$cwd"`
- Don't show: skip folder entirely

**Git section** (if enabled):
- Full status: Include branch, uncommitted count, and sync status
- Branch only: Just show branch name
- No git: Skip entirely

**Context bar**: Always include - shows token usage with visual bar

**Last message section** (if enabled):
- Read from transcript_path in JSONL format
- Extract last user message (text content only)
- Skip unhelpful messages like "[Request interrupted"
- Truncate to match first line width

### Update Settings

After creating the script:

1. Make it executable: `chmod +x <script_path>`

2. Determine settings file location:
   - If `~/.claude-work/` exists → `~/.claude-work/settings.json`
   - Otherwise → `~/.claude/settings.json`

3. Update or create settings.json with:
```json
{
  "statusLine": {
    "type": "command",
    "command": "<full_path_to_script>"
  }
}
```

**Important**: Preserve existing settings when updating - only modify the `statusLine` key.

---

## Completion Message

After setup, tell the user:

```
Statusline configured successfully!

📍 Script: <script_path>
⚙️ Settings: <settings_path>

Your statusline will show:
- <list enabled features based on choices>

Restart Claude Code to see your new statusline.

To reconfigure later, run: /setup-statusline
```

---

## Full Script Reference

Here's the complete script with all features enabled for reference:

```bash
#!/bin/bash

# Color codes
C_RESET='\033[0m'
C_GRAY='\033[38;5;245m'
C_BAR_EMPTY='\033[38;5;238m'
C_ACCENT='\033[38;5;74m'  # blue

input=$(cat)

# Extract directory
cwd=$(echo "$input" | jq -r '.cwd // empty')
dir=$(basename "$cwd" 2>/dev/null || echo "?")

# Get git branch and status
branch=""
git_status=""
if [[ -n "$cwd" && -d "$cwd" ]]; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    if [[ -n "$branch" ]]; then
        file_count=$(git -C "$cwd" --no-optional-locks status --porcelain -uall 2>/dev/null | wc -l | tr -d ' ')

        sync_status=""
        upstream=$(git -C "$cwd" rev-parse --abbrev-ref @{upstream} 2>/dev/null)
        if [[ -n "$upstream" ]]; then
            counts=$(git -C "$cwd" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
            ahead=$(echo "$counts" | cut -f1)
            behind=$(echo "$counts" | cut -f2)
            if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
                sync_status="synced"
            elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
                sync_status="${ahead} ahead"
            elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
                sync_status="${behind} behind"
            else
                sync_status="${ahead} ahead, ${behind} behind"
            fi
        else
            sync_status="no upstream"
        fi

        if [[ "$file_count" -eq 0 ]]; then
            git_status="(${sync_status})"
        elif [[ "$file_count" -eq 1 ]]; then
            git_status="(1 file uncommitted, ${sync_status})"
        else
            git_status="(${file_count} files uncommitted, ${sync_status})"
        fi
    fi
fi

# Get transcript path and context info
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
max_context=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
max_k=$((max_context / 1000))

# Calculate context from transcript
bar_width=10
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    context_length=$(jq -s '
        map(select(.message.usage and .isSidechain != true and .isApiErrorMessage != true)) |
        last |
        if . then
            (.message.usage.input_tokens // 0) +
            (.message.usage.cache_read_input_tokens // 0) +
            (.message.usage.cache_creation_input_tokens // 0)
        else 0 end
    ' < "$transcript_path")

    if [[ "$context_length" -gt 0 ]]; then
        pct=$((context_length * 100 / max_context))
        pct_prefix=""
    else
        pct=$((20000 * 100 / max_context))
        pct_prefix="~"
    fi
    [[ $pct -gt 100 ]] && pct=100
else
    pct=$((20000 * 100 / max_context))
    pct_prefix="~"
fi

# Build context bar
bar=""
for ((i=0; i<bar_width; i++)); do
    bar_start=$((i * 10))
    progress=$((pct - bar_start))
    if [[ $progress -ge 8 ]]; then
        bar+="${C_ACCENT}█${C_RESET}"
    elif [[ $progress -ge 3 ]]; then
        bar+="${C_ACCENT}▄${C_RESET}"
    else
        bar+="${C_BAR_EMPTY}░${C_RESET}"
    fi
done

ctx="${bar} ${C_GRAY}${pct_prefix}${pct}% of ${max_k}k tokens used"

# Build output
output="${C_ACCENT}📁${dir}${C_GRAY}"
[[ -n "$branch" ]] && output+=" | 🔀${branch} ${git_status}"
output+=" | ${ctx}${C_RESET}"

printf '%b\n' "$output"

# Last message (second line)
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    plain_output="📁${dir}"
    [[ -n "$branch" ]] && plain_output+=" | 🔀${branch} ${git_status}"
    plain_output+=" | xxxxxxxxxx ${pct}% of ${max_k}k tokens used"
    max_len=${#plain_output}

    last_user_msg=$(jq -rs '
        def is_unhelpful:
            startswith("[Request interrupted") or
            startswith("[Request cancelled") or
            . == "";

        [.[] | select(.type == "user") |
         select(.message.content | type == "string" or
                (type == "array" and any(.[]; .type == "text")))] |
        reverse |
        map(.message.content |
            if type == "string" then .
            else [.[] | select(.type == "text") | .text] | join(" ") end |
            gsub("\n"; " ") | gsub("  +"; " ")) |
        map(select(is_unhelpful | not)) |
        first // ""
    ' < "$transcript_path" 2>/dev/null)

    if [[ -n "$last_user_msg" ]]; then
        if [[ ${#last_user_msg} -gt $max_len ]]; then
            echo "💬 ${last_user_msg:0:$((max_len - 3))}..."
        else
            echo "💬 ${last_user_msg}"
        fi
    fi
fi
```

---

## Notes

- **Platform**: Works on macOS and Linux (requires `jq` installed)
- **Dependencies**: `jq` for JSON parsing, `git` for branch info
- **Persistence**: Settings survive restarts, edit settings.json to change
