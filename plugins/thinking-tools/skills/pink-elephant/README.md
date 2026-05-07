# Pink Elephant

Rewrite negative prohibitions ("don't X", "never X", "avoid X") into positive directives that tell agents what *to* do.

> "Don't think about a pink elephant."
> — Now you're thinking about a pink elephant.

## Why This Matters

Telling an LLM what *not* to do is unreliable. Naming the forbidden behavior raises its salience as a continuation, and language models have well-documented weaknesses handling negation. Stating the affirmative goal is more direct and more reliable.

Both major model providers say so explicitly:

- **OpenAI**: *"Instead of just saying what not to do, say what to do instead."* ([Best practices for prompt engineering](https://help.openai.com/en/articles/6654000-best-practices-for-prompt-engineering-with-the-openai-api))
- **Anthropic**: *"Tell Claude what to do instead of what not to do."* And: *"Positive examples tend to be more effective than negative examples or instructions."* ([Claude prompting best practices](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering))
- **Microsoft / Azure OpenAI** safety guidance pairs "what the assistant must not do" with "what to do when it can't comply" — the pattern to use when a prohibition is genuinely load-bearing. ([Azure system-message guidance](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/system-message))
- **Google** (Lee Boonstra prompt-engineering guide): "focusing on positive instructions … can be more effective."

## When It Triggers

- You say "pink elephant" or critique a prompt for being too focused on what not to do
- A document is stacked with "DO NOT" / "NEVER" / "AVOID"
- An agent keeps doing the thing it was just told not to do
- You're reviewing prompts, skills, CLAUDE.md, hooks, or guardrails

## Two Failure Modes

Negative instructions fail in two opposite ways:

1. **Fixation** — the classic pink elephant. The prohibition raises salience and the model produces the forbidden behavior anyway. "No preamble" yields a preamble; "don't apologize" yields apologies.
2. **Over-literal suppression** — newer/more compliant models (e.g. Claude Opus 4.x) obey the prohibition *too* faithfully and suppress useful behavior alongside the forbidden behavior. "Don't nitpick" silences findings the user wanted.

Same fix for both: state the affirmative goal with scope.

## What It Does

1. Identifies the prohibition
2. Names the affirmative behavior you actually want
3. Keeps load-bearing negatives (safety/security) but pairs each with an affirmative fallback (the Azure pattern)
4. Flags stacked prohibitions for consolidation

See `SKILL.md` for the full reframe protocol with examples.

## Research Backing

Why LLMs handle negation poorly is well-documented:

- Kassner & Schütze, *Negated and Misprimed Probes for Pretrained Language Models* (ACL 2020) — pretrained LMs don't distinguish negated from non-negated cloze prompts. [paper](https://aclanthology.org/2020.acl-main.698/)
- Truong et al., *Language Models are Not Naysayers* (\*SEM 2023) — GPT-Neo, GPT-3, and InstructGPT show "insensitivity to the presence of negation." [paper](https://aclanthology.org/2023.starsem-1.10/)
- García-Ferrero et al., *This is not a Dataset* (EMNLP 2023) — LLMs rely on superficial cues; negation generalization remains hard. [paper](https://arxiv.org/abs/2310.15941)
- So et al., *Thunder-NUBench* (Findings of EACL 2026) — negation is "an ongoing challenge" for LLMs. [paper](https://aclanthology.org/2026.findings-eacl.250/)
- *Do not think about pink elephant!* (arXiv 2404.15154) — names the salience mechanism: negative prompts act as a "strong prior" that "encourages the generation" of the unwanted object.
- *The Pink Elephant Problem: Why "Don't Do That" Fails with LLMs* (16x Eval, Aug 2025) — practitioner post using the same framing. [post](https://eval.16x.engineer/blog/the-pink-elephant-negative-instructions-llms-effectiveness-analysis)

Full citation list and counter-evidence (when prohibitions remain legitimate, where fine-tuning helps) in `references.md`.

## Install

```bash
amskills install pink-elephant
```
