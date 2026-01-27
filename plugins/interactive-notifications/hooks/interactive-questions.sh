#!/bin/bash
#
# Interactive Questions Hook for Claude Code
#
# Intercepts AskUserQuestion tool calls and shows macOS dialogs
# with clickable options instead of requiring terminal input.
#
# Part of: claude-plugins/plugins/interactive-notifications
#

LOG_FILE="$HOME/.claude/hooks/questions.log"

# Read JSON input from stdin
INPUT=$(cat)

# Log for debugging
echo "$(date): Received question request" >> "$LOG_FILE"
echo "$INPUT" >> "$LOG_FILE"

# Parse JSON input using jq
if ! command -v jq &> /dev/null; then
    # No jq, fall back to terminal
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Only handle AskUserQuestion
if [ "$TOOL_NAME" != "AskUserQuestion" ]; then
    exit 0
fi

# Get folder path for context
FOLDER_PATH=$(echo "$CWD" | awk -F'/' '{
    n = NF
    if (n >= 3) print "../" $(n-2) "/" $(n-1) "/" $n
    else if (n == 2) print "../" $(n-1) "/" $n
    else print $n
}')

# Extract questions array
QUESTIONS=$(echo "$INPUT" | jq -r '.tool_input.questions // []')
NUM_QUESTIONS=$(echo "$QUESTIONS" | jq 'length')

if [ "$NUM_QUESTIONS" -eq 0 ]; then
    exit 0
fi

# Build responses array
RESPONSES="{"

# Process each question
for ((i=0; i<NUM_QUESTIONS; i++)); do
    QUESTION=$(echo "$QUESTIONS" | jq -r ".[$i]")
    HEADER=$(echo "$QUESTION" | jq -r '.header // "Question"')
    QUESTION_TEXT=$(echo "$QUESTION" | jq -r '.question // ""' | sed 's/"/\\"/g')
    MULTI_SELECT=$(echo "$QUESTION" | jq -r '.multiSelect // false')

    # Get options
    OPTIONS=$(echo "$QUESTION" | jq -r '.options // []')
    NUM_OPTIONS=$(echo "$OPTIONS" | jq 'length')

    if [ "$NUM_OPTIONS" -eq 0 ]; then
        continue
    fi

    # Build button list (max 3 buttons in AppleScript dialog, use list for more)
    if [ "$NUM_OPTIONS" -le 3 ]; then
        # Use buttons for 2-3 options
        BUTTON_LIST=""
        for ((j=NUM_OPTIONS-1; j>=0; j--)); do
            LABEL=$(echo "$OPTIONS" | jq -r ".[$j].label // \"Option $((j+1))\"" | sed 's/"/\\"/g' | head -c 30)
            if [ -n "$BUTTON_LIST" ]; then
                BUTTON_LIST="$BUTTON_LIST, "
            fi
            BUTTON_LIST="$BUTTON_LIST\"$LABEL\""
        done

        # Get first option's label for default
        DEFAULT_LABEL=$(echo "$OPTIONS" | jq -r '.[0].label // "Option 1"' | sed 's/"/\\"/g' | head -c 30)

        # Show dialog with buttons (5 minute timeout)
        RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set theResult to display dialog \"$QUESTION_TEXT\" with title \"Claude [$FOLDER_PATH]: $HEADER\" buttons {$BUTTON_LIST} default button \"$DEFAULT_LABEL\" giving up after 300
    if gave up of theResult then
        return \"TIMEOUT\"
    else
        return button returned of theResult
    end if
end tell
" 2>&1)

    else
        # Use list for 4+ options
        LIST_ITEMS=""
        for ((j=0; j<NUM_OPTIONS; j++)); do
            LABEL=$(echo "$OPTIONS" | jq -r ".[$j].label // \"Option $((j+1))\"" | sed 's/"/\\"/g')
            DESC=$(echo "$OPTIONS" | jq -r ".[$j].description // \"\"" | sed 's/"/\\"/g' | head -c 50)
            ITEM="$LABEL"
            if [ -n "$DESC" ]; then
                ITEM="$LABEL - $DESC"
            fi
            if [ -n "$LIST_ITEMS" ]; then
                LIST_ITEMS="$LIST_ITEMS, "
            fi
            LIST_ITEMS="$LIST_ITEMS\"$ITEM\""
        done

        # Add "Other" option for custom input
        LIST_ITEMS="$LIST_ITEMS, \"Other (type custom answer)\""

        # Show list dialog (5 minute timeout via cancel)
        if [ "$MULTI_SELECT" = "true" ]; then
            RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set chosenItems to choose from list {$LIST_ITEMS} with title \"Claude [$FOLDER_PATH]: $HEADER\" with prompt \"$QUESTION_TEXT\" with multiple selections allowed
    if chosenItems is false then
        return \"CANCELLED\"
    else
        set AppleScript's text item delimiters to \"|\"
        return chosenItems as text
    end if
end tell
" 2>&1)
        else
            RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set chosenItem to choose from list {$LIST_ITEMS} with title \"Claude [$FOLDER_PATH]: $HEADER\" with prompt \"$QUESTION_TEXT\"
    if chosenItem is false then
        return \"CANCELLED\"
    else
        return item 1 of chosenItem
    end if
end tell
" 2>&1)
        fi
    fi

    echo "$(date): Q$i selected: $RESULT" >> "$LOG_FILE"

    # Handle "Other" selection - prompt for custom input
    if [[ "$RESULT" == *"Other"* ]]; then
        RESULT=$(osascript -e "
tell application \"System Events\"
    activate
    set customAnswer to display dialog \"Enter your custom answer:\" with title \"Claude: Custom Input\" default answer \"\" giving up after 300
    if gave up of customAnswer then
        return \"\"
    else
        return text returned of customAnswer
    end if
end tell
" 2>&1)
    fi

    # Handle timeout/cancel - fall back to terminal
    if [[ "$RESULT" == "TIMEOUT" ]] || [[ "$RESULT" == "CANCELLED" ]] || [[ -z "$RESULT" ]]; then
        echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'
        exit 0
    fi

    # Clean up result (remove description part if present)
    RESULT=$(echo "$RESULT" | sed 's/ - .*//')

    # Add to responses (using question index as key)
    if [ $i -gt 0 ]; then
        RESPONSES="$RESPONSES,"
    fi
    RESPONSES="$RESPONSES\"$i\":\"$RESULT\""
done

RESPONSES="$RESPONSES}"

echo "$(date): Final responses: $RESPONSES" >> "$LOG_FILE"

# Return the answer by denying the tool and providing the selection as context
# Claude will see this and understand the user's choice
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "User answered via dialog: $RESPONSES"
  }
}
EOF

exit 0
