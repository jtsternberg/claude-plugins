#!/bin/bash
#
# Interactive Idle Hook for Claude Code
#
# Shows macOS dialog when Claude has been idle (waiting for input).
# Allows user to reply or acknowledge from anywhere on the Mac.
#
# Part of: claude-plugins/plugins/interactive-notifications
#

LOG_FILE="$HOME/.claude/hooks/notification.log"

# Read JSON input from stdin
INPUT=$(cat)

# Log for debugging
echo "$(date): Received idle notification" >> "$LOG_FILE"

# Parse JSON input using jq
if command -v jq &> /dev/null; then
    MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude is waiting for your input"')
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
    NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // ""')
else
    MESSAGE="Claude is waiting for your input"
    CWD=""
    NOTIFICATION_TYPE=""
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

# Build dialog title
DIALOG_TITLE="Claude Idle: $FOLDER_PATH"

# Escape message for AppleScript
MSG_ESCAPED=$(echo "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 300)

# Show dialog with Reply/OK buttons (5 minute timeout)
RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set theResult to display dialog \"$MSG_ESCAPED\" with title \"$DIALOG_TITLE\" buttons {\"Reply\", \"OK\"} default button \"OK\" giving up after 300
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

    if [[ "$REPLY_TEXT" != "TIMEOUT" ]] && [[ "$REPLY_TEXT" != "CANCELLED" ]] && [[ -n "$REPLY_TEXT" ]]; then
        # Return the reply as additional context
        REPLY_ESCAPED=$(echo "$REPLY_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
        cat << EOF
{"hookSpecificOutput":{"hookEventName":"Notification","additionalContext":"User replied via notification: $REPLY_ESCAPED"}}
EOF
        exit 0
    fi
fi

# OK or timeout - just acknowledge
exit 0
