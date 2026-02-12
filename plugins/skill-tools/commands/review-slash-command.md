---
description: Review a slash command for opportunities to split into subagents
argument-hint: <command-name>
allowed-tools: Read, Glob, Grep
---

You are reviewing a slash command to identify opportunities to break it down into specialized subagents.

For context on how to structure commands and subagents, refer to:
- @.claude/commands/create-slash-command.md - Best practices for slash command structure
- @.claude/commands/create-subagent.md - Subagent creation guidelines

# Command/Agent Pattern Philosophy

Based on Anthropic's research on building effective agents (https://www.anthropic.com/engineering/building-effective-agents):

## Start Simple, Add Complexity Only When Needed

**CRITICAL**: Before recommending subagents, ask: **Does this command even need them?**
- Can the task be solved with an optimized single LLM call?
- Will the added latency and cost justify the quality improvement?
- Are there clear success criteria showing subagents would help?

Only recommend subagents when simpler solutions demonstrably fall short.

## Workflow vs Agent Patterns

Distinguish between two types of agentic systems:

### Workflows (Predefined Paths)
Commands orchestrate LLMs through predefined code paths:
- **Prompt Chaining**: Sequential steps where each LLM call processes the previous output
- **Routing**: Classify input and direct to specialized tasks
- **Parallelization**: Run tasks simultaneously (sectioning or voting)
- **Orchestrator-Workers**: Central command dynamically delegates to workers
- **Evaluator-Optimizer**: One agent generates, another critiques in a loop

**When to use**: Predictable tasks with clear decomposition

### Agents (Dynamic Decision-Making)
LLMs dynamically direct their own process using tools in loops:
- **Autonomous Agents**: Operate independently with tool access and environment feedback

**When to use**: Open-ended problems requiring flexible decision-making

## Generator/Reasoner Pattern (Evaluator-Optimizer)

One powerful workflow pattern: **agents generate comprehensive output**, **commands filter and reason** over it.

Key principles:
- **Agent as generator**: Subagent performs comprehensive analysis/search with broad scope
- **Command as reasoner**: Command reviews agent output, filters noise, produces refined result
- **Quality over speed**: Trades latency/tokens for significantly better quality
- **Reduced false positives**: Reasoning layer filters out noise and irrelevant details

Benefits:
- Better signal-to-noise ratio in final output
- Agent output remains visible for full analysis when needed
- More reliable results through filtering/reasoning step

# Task

Analyze the slash command file `.claude/commands/$1.md` and:

1. **Read and understand the command**: Parse its frontmatter, description, and full prompt content

2. **Assess necessity** (Simplicity First):
   - Could this be solved with an optimized single LLM call?
   - What are the clear success criteria for this command?
   - What specific problems (verbosity, false positives, complexity) justify adding subagents?
   - What are the cost/latency tradeoffs?

3. **Identify complexity indicators**:
   - Tasks that generate too much output or false positives (→ needs filtering)
   - Multiple distinct analysis or search phases (→ possible chaining/parallelization)
   - Classification followed by specialized handling (→ routing pattern)
   - Tasks where comprehensive data gathering needs filtering (→ generator/reasoner)
   - Iterative refinement needs (→ evaluator-optimizer pattern)
   - Different tool usage patterns (→ possible separation of concerns)
   - Conditional logic that branches into separate workflows
   - Unpredictable subtasks requiring dynamic planning (→ orchestrator-workers)

4. **Recognize applicable patterns**:
   - **Prompt Chaining**: Can task be decomposed into sequential steps?
   - **Routing**: Does input need classification before specialized handling?
   - **Parallelization**: Can independent subtasks run simultaneously? Need voting/consensus?
   - **Orchestrator-Workers**: Are subtasks unpredictable and need dynamic delegation?
   - **Evaluator-Optimizer**: Would iterative refinement improve quality?
   - **Autonomous Agent**: Is this truly open-ended with unpredictable tool usage?

5. **Suggest subagent opportunities** (if justified):
   - **Pattern type**: Which pattern(s) from above apply?
   - **Workflow vs Agent**: Is this predefined paths or dynamic decision-making?
   - **Generator subagents**: What agents could perform comprehensive analysis/search?
   - **Command as reasoner**: How should the command filter and refine agent output?
   - Name potential subagents with clear, descriptive names
   - Define each subagent's specific responsibility
   - Explain what tools each subagent would need (emphasize ACI design)
   - Show how the main command would coordinate subagent(s)

6. **Provide refactoring recommendations**:
   - Pattern-based structure showing the workflow/agent design
   - Which parts become subagents vs stay in command
   - Identify any reusable subagents that could serve multiple commands
   - Highlight where the pattern adds demonstrable value
   - Document expected improvements (quality, reliability, maintainability)

# Output Format

Provide a structured review with:

## Current Command Analysis
- Command purpose and scope
- Current complexity level (simple/moderate/complex)
- Key steps and phases identified
- Existing problems (verbosity, false positives, reliability issues, etc.)

## Simplicity Assessment
**First, answer**: Does this command need subagents at all?
- **Could single LLM call work?**: Evaluate if optimization alone would suffice
- **Success criteria**: What measurable outcomes define success?
- **Cost/latency tradeoff**: Is added complexity worth the improvement?
- **Recommendation**: Keep simple OR proceed with subagent split (with justification)

## Pattern Recognition
If subagents are justified, identify applicable patterns:
- **Primary pattern**: Which pattern best fits (Prompt Chaining, Routing, Parallelization, Orchestrator-Workers, Evaluator-Optimizer, Autonomous Agent)?
- **Workflow vs Agent**: Predefined paths or dynamic decision-making?
- **Pattern rationale**: Why this pattern is appropriate
- **Expected benefits**: What specific improvements this pattern provides

## Subagent Opportunities
For each suggested subagent:
- **Name**: `<descriptive-subagent-name>`
- **Pattern role**: How it fits in the identified pattern (generator, worker, evaluator, etc.)
- **Purpose**: What specific task/analysis it performs
- **Output**: What data/results it produces
- **Tools needed**: List with emphasis on Agent-Computer Interface design
- **When to use**: Conditions for invoking this subagent

## Command Coordination
How the main command orchestrates the pattern:
- **Input handling**: How command processes initial request
- **Subagent invocation**: How/when it delegates to subagent(s)
- **Result processing**: How it handles subagent output (filtering, reasoning, synthesis)
- **Final output**: What refined result it produces
- **Error handling**: How failures are managed

## Refactoring Recommendation
- **Architecture**: High-level structure showing the pattern flow
- **Component breakdown**: Which parts become subagents vs stay in command
- **Coordination flow**: Step-by-step workflow
- **Quality improvements**: Specific expected improvements (with metrics if possible)
- **Tradeoffs**: Token cost, latency, complexity vs quality/reliability gains
- **Reusability**: Could these subagents serve other commands?
- **Edge cases**: Any special considerations

## Priority Assessment
- **Priority level**: None/Low/Medium/High
- **Justification**: Why this priority (based on problems solved vs costs)
- **Success metrics**: How to measure if the refactoring improved outcomes

# Notes

## Critical Principles

- **Simplicity bias**: Default to keeping commands simple. Subagents must demonstrably improve outcomes.
- **Measure first**: Base recommendations on actual problems (too slow, too many false positives, unreliable results).
- **Avoid over-engineering**: Simple commands should stay simple.
- **Pattern-driven**: Use established patterns rather than inventing new architectures.

## Tool Design Emphasis

When recommending subagents, emphasize Agent-Computer Interface (ACI) design:
- Clear, comprehensive tool documentation with examples
- Mistake-proof parameter design (absolute paths, unambiguous names)
- Natural formats that don't require complex escaping or overhead
- Remember: Tool design is as important as prompt design

## Reusability and Testing

- Consider if suggested subagents could be useful for other commands
- Recommend testing approach for validating improvements
- Suggest success metrics to measure if subagents actually help
- Reference @.claude/commands/create-subagent.md for implementation best practices

## Philosophy

The goal isn't to make commands more sophisticated—it's to make them **more effective**. Sometimes that means keeping them simple. Only recommend complexity when it solves real, measurable problems.
