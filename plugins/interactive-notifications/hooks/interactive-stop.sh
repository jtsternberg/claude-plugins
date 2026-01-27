#!/bin/bash
#
# Interactive Stop Hook for Claude Code
#
# Shows macOS dialog when Claude finishes responding.
# Allows user to reply with follow-up or acknowledge completion.
#
# Part of: claude-plugins/plugins/interactive-notifications
#

LOG_FILE="$HOME/.claude/hooks/notification.log"

# Read JSON input from stdin
INPUT=$(cat)

# Log for debugging
echo "$(date): Received stop notification" >> "$LOG_FILE"

# Parse JSON input using jq
if command -v jq &> /dev/null; then
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
    STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
else
    CWD=""
    STOP_HOOK_ACTIVE="false"
    TRANSCRIPT_PATH=""
fi

# Don't show dialog if we're already in a stop hook loop
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Get last 3 folders from path
if [ -n "$CWD" ]; then
    FOLDER_PATH=$(echo "$CWD" | awk -F'/' '{
        n = NF
        if (n >= 3) print "../" $(n-2) "/" $(n-1) "/" $n
        else if (n == 2) print "../" $(n-1) "/" $n
        else print $n
    }')
else
    FOLDER_PATH="Unknown"
fi

# Try to get Claude's last message summary from transcript
LAST_CLAUDE_MSG=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    LAST_CLAUDE_MSG=$(tail -20 "$TRANSCRIPT_PATH" 2>/dev/null | \
        grep '"type":"assistant"' | \
        tail -1 | \
        jq -r '.message.content // "" | if type == "array" then .[0].text // "" else . end' 2>/dev/null | \
        head -c 150 | \
        tr '\n' ' ')
fi

# Build dialog
DIALOG_TITLE="Claude Done: $FOLDER_PATH"
MSG="Claude has finished responding."

if [ -n "$LAST_CLAUDE_MSG" ] && [ "$LAST_CLAUDE_MSG" != "null" ]; then
    LAST_MSG_ESCAPED=$(echo "$LAST_CLAUDE_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 120)
    MSG="$MSG

Last message: $LAST_MSG_ESCAPED..."
fi

# Show dialog with Reply/OK buttons (5 minute timeout)
RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set theResult to display dialog \"$MSG\" with title \"$DIALOG_TITLE\" buttons {\"Continue\", \"OK\"} default button \"OK\" giving up after 300
    if gave up of theResult then
        return \"TIMEOUT\"
    else
        return button returned of theResult
    end if
end tell
" 2>&1)

echo "$(date): User selected: $RESULT" >> "$LOG_FILE"

# Handle Continue - show text input for follow-up
if [[ "$RESULT" == "Continue" ]]; then
    REPLY_TEXT=$(osascript -e "
tell application \"System Events\"
    activate
    set userReply to display dialog \"What should Claude do next?\" with title \"Continue with Claude\" default answer \"\" buttons {\"Cancel\", \"Send\"} default button \"Send\" giving up after 300
    if gave up of userReply then
        return \"TIMEOUT\"
    else if button returned of userReply is \"Cancel\" then
        return \"CANCELLED\"
    else
        return text returned of userReply
    end if
end tell
" 2>&1)

    echo "$(date): User continue request: $REPLY_TEXT" >> "$LOG_FILE"

    if [[ "$REPLY_TEXT" != "TIMEOUT" ]] && [[ "$REPLY_TEXT" != "CANCELLED" ]] && [[ -n "$REPLY_TEXT" ]]; then
        # Block stopping and provide follow-up instruction
        REPLY_ESCAPED=$(echo "$REPLY_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
        cat << EOF
{"decision":"block","reason":"User wants to continue: $REPLY_ESCAPED"}
EOF
        exit 0
    fi
fi

# OK or timeout - allow stop
exit 0
