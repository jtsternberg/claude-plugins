#!/bin/bash
#
# Interactive Permission Hook for Claude Code
#
# Shows macOS dialog with clickable buttons when Claude asks for permission.
# Includes folder path, session context, and option to type a reply.
#
# Part of: claude-plugins/plugins/interactive-notifications
#

LOG_FILE="$HOME/.claude/hooks/permission.log"

# Read JSON input from stdin
INPUT=$(cat)

# Log for debugging
echo "$(date): Received permission request" >> "$LOG_FILE"

# Parse JSON input using jq
if command -v jq &> /dev/null; then
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

    # Extract relevant info based on tool type
    case "$TOOL_NAME" in
        "Bash")
            DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // ""' | head -c 200)
            ;;
        "Write"|"Edit"|"Read")
            DETAIL=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
            ;;
        *)
            DETAIL=$(echo "$INPUT" | jq -r '.tool_input | tostring' 2>/dev/null | head -c 150)
            ;;
    esac
else
    TOOL_NAME="Unknown"
    CWD=""
    TRANSCRIPT_PATH=""
    DETAIL=""
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

# Try to get the last user message from transcript for context
LAST_MESSAGE=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    LAST_MESSAGE=$(tail -50 "$TRANSCRIPT_PATH" 2>/dev/null | \
        grep '"type":"human"' | \
        tail -1 | \
        jq -r '.message.content // "" | if type == "array" then .[0].text // "" else . end' 2>/dev/null | \
        head -c 100 | \
        tr '\n' ' ')
fi

# Build the dialog title with folder context
DIALOG_TITLE="Claude: $FOLDER_PATH"

# Build the message
MSG="Tool: $TOOL_NAME"

if [ -n "$DETAIL" ] && [ "$DETAIL" != "null" ]; then
    DETAIL_ESCAPED=$(echo "$DETAIL" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 200)
    MSG="$MSG

$DETAIL_ESCAPED"
fi

# Add last message context if available
if [ -n "$LAST_MESSAGE" ] && [ "$LAST_MESSAGE" != "null" ]; then
    LAST_MSG_ESCAPED=$(echo "$LAST_MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 80)
    MSG="$MSG

---
Task: $LAST_MSG_ESCAPED..."
fi

# Show dialog with Yes/No/Reply buttons (5 minute timeout = 300 seconds)
RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set theResult to display dialog \"$MSG\" with title \"$DIALOG_TITLE\" buttons {\"Reply\", \"No\", \"Yes\"} default button \"Yes\" giving up after 300
    if gave up of theResult then
        return \"TIMEOUT\"
    else
        return button returned of theResult
    end if
end tell
" 2>&1)

echo "$(date): User selected: $RESULT" >> "$LOG_FILE"

# Handle Reply - show text input dialog
if [[ "$RESULT" == "Reply" ]]; then
    REPLY_TEXT=$(osascript -e "
tell application \"System Events\"
    activate
    set userReply to display dialog \"Type your message to Claude:\" with title \"Reply to Claude\" default answer \"\" buttons {\"Cancel\", \"Send\"} default button \"Send\" giving up after 300
    if gave up of userReply then
        return \"TIMEOUT\"
    else if button returned of userReply is \"Cancel\" then
        return \"CANCELLED\"
    else
        return text returned of userReply
    end if
end tell
" 2>&1)

    echo "$(date): User reply: $REPLY_TEXT" >> "$LOG_FILE"

    if [[ "$REPLY_TEXT" == "TIMEOUT" ]] || [[ "$REPLY_TEXT" == "CANCELLED" ]] || [[ -z "$REPLY_TEXT" ]]; then
        # Fall back to terminal
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
    else
        # Escape the reply for JSON
        REPLY_ESCAPED=$(echo "$REPLY_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
        # Deny with user's message as context
        cat << EOF
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"User replied: $REPLY_ESCAPED"}}}
EOF
    fi
    exit 0
fi

# Map user choice to Claude Code decision
if [[ "$RESULT" == *"Yes"* ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
elif [[ "$RESULT" == *"No"* ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"User denied via dialog"}}}'
else
    # Timeout or error - fall back to terminal prompt
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
fi

exit 0
