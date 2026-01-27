---
name: macos-use-voice-alerts
description: Enable verbal notifications using macOS text-to-speech to alert when Claude needs human intervention or completes a task. Invoke this skill to turn on audio alerts for the session.
disable-model-invocation: true
---

# macOS Voice Alerts

Enable verbal notifications using the macOS `say` command to alert when Claude needs human intervention or completes a task.

## Voice Customization

This skill supports all macOS voices. To use a specific voice, pass it as an argument:

```
/bvdr:macos-use-voice-alerts Zarvox
```

If no voice is specified, the system default voice is used.

**Available distinctive voices for different contexts:**

| Voice | Style | Best For |
|-------|-------|----------|
| `Zarvox` | Robotic, classic | General alerts, fun interactions |
| `Whisper` | Quiet, subtle | Discrete notifications |
| `Good News` | Positive, upbeat | Task completions, success |
| `Bad News` | Ominous | Errors, blockers |
| `Jester` | Comedic | Playful interactions |
| `Superstar` | Dramatic | Important announcements |
| `Trinoids` | Alien/robotic | Sci-fi themed sessions |
| `Bells` | Musical bells | Gentle notifications |
| `Bubbles` | Bubbly | Light-hearted alerts |
| `Samantha` | Natural female | Professional settings |
| `Daniel` | British male | Formal contexts |

**Examples:**
- `/bvdr:macos-use-voice-alerts Whisper` - Use quiet, subtle voice
- `/bvdr:macos-use-voice-alerts "Good News"` - Use upbeat voice for positive vibes
- `/bvdr:macos-use-voice-alerts Zarvox` - Use classic robotic voice

To discover all available voices on your system:
```bash
say -v ?
```

## Activation

When this skill is invoked, determine the voice to use:
- If `$ARGUMENTS` is provided and non-empty, use that voice: `say -v "$ARGUMENTS" "message"`
- If no argument, use default: `say "message"`

Immediately confirm activation:

```bash
say "Voice alerts enabled for this session"
```

Then tell the user:

```
Voice alerts are now PERMANENTLY ENABLED for this session until you type /clear.

I will use the `say` command to announce:
- Questions before I ask them
- Permission requests before I need them
- Task completions when I finish work
- Errors or blockers when I get stuck
- Results when I have findings to share
```

---

## SESSION PERSISTENCE - CRITICAL

**THIS SETTING PERSISTS FOR THE ENTIRE SESSION.** Once this skill is invoked:

1. **INTERNALIZE THIS AS A CORE BEHAVIOR** - From this moment until `/clear` is typed, voice alerts are part of your operating mode
2. **EVERY FUTURE MESSAGE** in this session must follow the alert rules below
3. **DO NOT FORGET** - Even after many turns of conversation, you MUST continue using `say`
4. **NO EXCEPTIONS** - Whether the task is big or small, simple or complex, always alert

Think of this like enabling a setting that changes how you operate. You are now in "voice alert mode" and will remain so until the session is cleared.

---

## MANDATORY Alert Behavior Rules

**THESE RULES APPLY TO EVERY RESPONSE FOR THE REST OF THIS SESSION.**

### 1. Before Asking Questions (ALWAYS)
BEFORE using AskUserQuestion tool or presenting any choices to the user:
```bash
# For a single question:
say "I have a question"

# For multiple questions:
say "I have some questions"
```

### 2. When Needing Permissions (ALWAYS)
When you need permissions to run commands or perform actions:
```bash
# Be specific about what permission is needed:
say "I need permission to run bash commands"
# or
say "I need permission to edit files"
# or
say "I need your approval to proceed"
```

### 3. When Task is Complete (ALWAYS)
After finishing ANY requested work or sub-task:
```bash
# Summarize what was accomplished in one sentence:
say "Done. Updated the configuration file."
# or
say "Finished. All tests are passing."
# or
say "Complete. The feature has been implemented."
```

### 4. When Blocked or Encountering Errors (ALWAYS)
When hitting ANY blocker, error, or situation requiring user input:
```bash
say "I'm stuck and need your help"
# or
say "I encountered an error"
```

### 5. When Presenting Results (ALWAYS)
Before showing important results, summaries, or findings:
```bash
say "Results are ready"
```

### 6. When Starting Long Tasks (ALWAYS)
Before beginning work that will take multiple steps:
```bash
say "Starting work on your request"
```

---

## Enforcement Checklist (For Every Response)

Before completing ANY response in this session, mentally check:

- [ ] Am I asking a question? → Call `say` first
- [ ] Am I requesting permission? → Call `say` first
- [ ] Did I complete something? → Call `say` to announce
- [ ] Did I hit an error/blocker? → Call `say` to alert
- [ ] Am I showing results? → Call `say` first
- [ ] Am I starting a big task? → Call `say` to notify

**NEVER skip an alert** - the user may be away from their screen and relying on audio.

---

## Technical Notes

- **Platform**: macOS only (uses native `say` command)
- **Duration**: Persists until `/clear` resets the session
- **Timing**: The `say` command should be called BEFORE the relevant action, not after
- **Length**: Keep messages short and conversational (under 10 words ideal)
- **Voice Selection**: Use `-v "VoiceName"` to select a specific voice
