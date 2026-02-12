---
description: "Create a new Claude command with proper structure and documentation"
argument-hint: "<command-name> <description>"
---

I'll help you create a new Claude command. Based on the Claude Code slash commands documentation at https://docs.anthropic.com/en/docs/claude-code/slash-commands, I'll create a properly structured command file.

Command details needed:
- **Command name**: $1 (first argument)
- **Description**: Remaining arguments will be used to infer the command's purpose

I'll create the command in `.claude/commands/` with:

1. **Proper frontmatter** including:
   - `description`: Brief explanation of what the command does
   - `argument-hint`: Description of expected arguments (if any)
   - Optional: `allowed-tools` (specify permitted tools for security)
   - Optional: `model` (select specific AI model)
   - Optional: `disable-model-invocation` (prevent automatic tool calling)

2. **Clear command prompt** that:
   - Explains the task clearly
   - Uses argument placeholders:
     - `$ARGUMENTS`: Captures all arguments passed to the command
     - `$1`, `$2`, etc.: Access individual arguments by position
   - Leverages @ prefix for file references (e.g., @src/file.js includes file contents)
   - Uses ! prefix for bash command execution where appropriate
   - Follows best practices for Claude interactions

3. **File structure**:
   - Saved as `.claude/commands/<command-name>.md`
   - Uses markdown format with YAML frontmatter
   - Includes documentation references where helpful

4. **Best practices**:
   - Use clear, concise descriptions
   - Specify `allowed-tools` for security when commands need specific tool access
   - Organize related commands in subdirectories for better structure
   - Provide helpful `argument-hint` to guide users on expected input

The command will be immediately available for use with `/<command-name>` and will appear in the help listing.

Example of a well-structured command:
```markdown
---
allowed-tools: Bash(git add:*), Bash(git commit:*)
argument-hint: [commit message]
description: Create a git commit
---
Create a git commit with message: $ARGUMENTS
```

Would you like me to create this command now? Please provide:
1. The command name (single word, lowercase with hyphens)
2. A brief description of what it should do
3. Any specific arguments, file references, or tool requirements

You can also reference specific files using @ syntax if the command should operate on particular files or directories.