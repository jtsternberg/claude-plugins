---
description: Create a new Claude subagent with best practices and proper configuration
argument-hint: <subagent-name> <description-of-purpose>
---

I'll help you create a new Claude subagent. Based on the Claude Code slash commands documentation at https://docs.claude.com/en/docs/claude-code/sub-agents, I'll create a properly structured subagent file.

## Subagent Creation Best Practices

Based on Anthropic's research on building effective agents (https://www.anthropic.com/engineering/building-effective-agents), follow these principles:

### Core Design Principles

1. **Simplicity First**: Start with the simplest solution possible. Only add complexity when it demonstrably improves outcomes. Many tasks can be solved with optimized single LLM calls before needing a full subagent.

2. **Single Purpose**: Create focused subagents with one clear responsibility. Agents work best for well-defined tasks where success criteria are measurable.

3. **Transparency**: Design subagents to explicitly show their planning steps and reasoning. This makes them more debugable and trustworthy.

### System Prompt Guidelines

4. **Detailed Instructions**: Write comprehensive instructions like you would for a junior developer:
   - Primary purpose and expertise area
   - How to approach tasks step-by-step
   - Clear constraints and guidelines
   - Expected output format
   - Example usage and edge cases
   - When to ask for human input

5. **Context Isolation**: Remember that subagents start fresh each time. Include all necessary context in the system prompt - they don't inherit conversation history.

### Tool Design (Critical)

6. **Agent-Computer Interface (ACI)**: Invest as much effort in tool design as you would in human-computer interfaces:
   - Give the model enough tokens to "think" before committing to actions
   - Keep tool formats close to natural text formats seen on the internet
   - Minimize formatting overhead (avoid requiring accurate line counts, string escaping, etc.)
   - Write clear tool descriptions with examples, edge cases, and boundaries
   - Test extensively with many example inputs

7. **Poka-Yoke Your Tools**: Design tools to be mistake-proof:
   - Use clear, unambiguous parameter names
   - Require absolute paths instead of relative ones
   - Make it structurally difficult to use tools incorrectly
   - Include validation and clear error messages

8. **Tool Permissions**: Only grant tools the subagent truly needs. More tools = more complexity and potential for errors.

### Testing and Iteration

9. **Measure and Iterate**: Test in sandboxed environments with clear success metrics. Iterate on both the system prompt AND tool definitions based on actual usage.

10. **Ground Truth Feedback**: Design subagents to get concrete feedback at each step (tool results, test outputs, environment state) to assess progress.

### When to Use Subagents

Use subagents for:
- Tasks requiring conversation AND action
- Well-defined problems with clear success criteria
- Situations where feedback loops add value
- Tasks that benefit from specialized focus

Don't use subagents for:
- Simple tasks solvable with optimized single prompts
- Tasks without clear success criteria
- Situations where the cost/latency tradeoff isn't justified

## Configuration Structure

Create the subagent file at `.claude/agents/<subagent-name>.md` with:

```markdown
---
description: Brief description of what this subagent does
tools:
  - ToolName1
  - ToolName2
model: claude-sonnet-4-5  # Optional: specify model if needed
---

# System Prompt

[Detailed instructions for the subagent's behavior, including:]
- Its primary purpose and expertise area
- How it should approach tasks
- Any constraints or guidelines
- Expected output format
- Examples of good behavior (if applicable)
```

## Common Subagent Patterns

Choose the right pattern for your use case:

### Workflow-Based Subagents (Predefined Paths)
- **Prompt Chain Worker**: Handles one step in a multi-step process (e.g., translate after generating copy)
- **Router**: Classifies input and directs to specialized handlers
- **Parallel Processor**: Handles sectioned tasks or voting/consensus approaches
- **Evaluator**: Provides feedback and critiques for iterative improvement
- **Optimizer**: Takes feedback and refines outputs

### Autonomous Subagents (Dynamic Decision-Making)
- **Code Reviewer**: Reviews code with flexible analysis based on context
- **Test Writer**: Creates comprehensive test suites with adaptive coverage
- **Debugger**: Investigates and fixes bugs through iterative exploration
- **Research Assistant**: Gathers and synthesizes information from multiple sources
- **Documentation Writer**: Creates clear, comprehensive documentation
- **Security Auditor**: Identifies vulnerabilities through systematic analysis

**Key Distinction**: Workflows follow predefined paths. Agents dynamically direct their own process using tools in loops. Choose workflows for predictability, agents for flexibility.

## Task

Based on the user's request: `{{ARGUMENTS}}`

Follow this process:

1. **Clarify Requirements**:
   - What specific problem does this subagent solve?
   - What are the clear success criteria?
   - Is a subagent needed, or would a simpler solution work?
   - Should this be a workflow (predefined steps) or agent (autonomous)?

2. **Design the Agent-Computer Interface**:
   - What tools are truly necessary? (Read, Write, Edit, Bash, Grep, Glob, etc.)
   - How can tool parameters be designed to prevent mistakes?
   - What examples and edge cases should be documented?
   - Consider: Can paths be absolute? Can formats be simplified?

3. **Craft the System Prompt**:
   - Write for a junior developer who needs clear guidance
   - Include purpose, approach, constraints, and output format
   - Specify when to ask for human input or verification
   - Add examples of good behavior for complex cases
   - Remember: The subagent won't have conversation context

4. **Create the Subagent File** in `.claude/agents/`:
   - Use descriptive, lowercase-with-hyphens naming
   - Include comprehensive tool descriptions
   - Specify model if needed (default: claude-sonnet-4-5)

5. **Plan for Testing**:
   - Explain how to invoke the subagent
   - Suggest test cases to validate behavior
   - Identify metrics for measuring success

## Key Considerations

### Implementation
- **Versioning**: Project-level subagents (`.claude/agents/`) should be version controlled
- **Naming**: Use descriptive, lowercase-with-hyphens names (e.g., `code-reviewer`, `test-generator`)
- **Invocation**: Users can invoke with "Use the <name> subagent" or let Claude auto-delegate based on task

### Quality Assurance
- **Iterate on Tool Definitions**: Spend as much time optimizing tools as the main prompt. Test with many examples.
- **Monitor Failure Modes**: Track where the subagent makes mistakes and adjust tool design or prompts accordingly
- **Sandbox Testing**: Test autonomous agents in safe environments before production use
- **Human Checkpoints**: Design agents to pause for human review at critical decision points

### Cost/Performance Tradeoffs
- **Latency**: Subagents add overhead through multiple LLM calls
- **Cost**: More tool calls = higher costs. Ensure the value justifies the expense
- **Reliability**: Autonomous agents can compound errors. Add appropriate guardrails

### Success Indicators
Your subagent is well-designed when:
- It has clear, measurable success criteria
- Tool documentation is comprehensive and mistake-proof
- The system prompt provides complete context and guidance
- Testing shows consistent, reliable behavior
- It solves a problem that simpler approaches couldn't

Create a well-structured, production-ready subagent that follows these principles. Remember: **Build the right system for your needs, not the most sophisticated one.**
