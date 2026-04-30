# References

## Provider guidance (verbatim)

- **OpenAI**, *Best practices for prompt engineering with the OpenAI API* (Help Center): "Instead of just saying what not to do, say what to do instead." Example: rather than "DO NOT ASK USERNAME OR PASSWORD," instruct the model to refrain from asking PII and refer the user to a help article.
  https://help.openai.com/en/articles/6654000-best-practices-for-prompt-engineering-with-the-openai-api

- **Anthropic**, Claude prompting best practices: "Tell Claude what to do instead of what not to do." Example: instead of "Do not use markdown," ask for "smoothly flowing prose paragraphs." Also: "Positive examples … tend to be more effective than negative examples or instructions."
  https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering

- **Microsoft / Azure OpenAI**, safety system message guidance: pairs "what the assistant must not do" with "what to do when it can't comply." Useful pattern for retaining necessary prohibitions while still giving the model an affirmative behavior.
  https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/system-message

- **Google / Lee Boonstra prompt-engineering guide**: "focusing on positive instructions … can be more effective." (Google-affiliated, not the canonical Gemini/Vertex docs.)

## Why negative instructions are unreliable (research)

- Kassner & Schütze, *Negated and Misprimed Probes for Pretrained Language Models: Birds Can Talk, But Cannot Fly*, ACL 2020. Pretrained LMs do not distinguish negated from non-negated cloze prompts. https://aclanthology.org/2020.acl-main.698/
- Truong, Baldwin, Verspoor, Cohn, *Language Models are Not Naysayers*, *SEM 2023. GPT-Neo, GPT-3, and InstructGPT show "insensitivity to the presence of negation" and "failure to reason under negation." https://aclanthology.org/2023.starsem-1.10/
- García-Ferrero et al., *This is not a Dataset: A Large Negation Benchmark to Challenge LLMs*, EMNLP 2023. LLMs rely on superficial cues; negation generalization remains hard. https://arxiv.org/abs/2310.15941
- So et al., *Thunder-NUBench*, Findings of EACL 2026. Negation is "an ongoing challenge" for LLMs. https://aclanthology.org/2026.findings-eacl.250/
- *Commonsense Knowledge with Negation* (2026 preprint). GPT-4o and Claude Sonnet 4 fail to validate commonsense triples with negation; Sonnet 4 only 0.56 F1 in few-shot. Fine-tuning helps but doesn't eliminate the gap.

## The salience mechanism (image-gen, but mechanism transfers)

- *Do not think about pink elephant!*, arXiv 2404.15154. Negative prompts act as a "strong prior" that "encourages the generation" of the unwanted object. Names the mechanism the skill warns about.

## Practitioner writing

- *The Pink Elephant Problem: Why "Don't Do That" Fails with LLMs* (16x Eval, Aug 2025). Practitioner post using the exact pink-elephant framing for text LLMs; cites Anthropic's "tell Claude what to do" guidance. https://eval.16x.engineer/blog/the-pink-elephant-negative-instructions-llms-effectiveness-analysis

## Counter-evidence / limits

- Anthropic's own guidance on Claude Opus 4.x notes the model is more literal. Strong negatives like "don't nitpick" or "only report high-severity issues" can be followed *too* faithfully, suppressing useful findings. This is a distinct failure mode from fixation: the model obeys the prohibition exactly, on too broad a scope.
- Microsoft's safety-system-message pattern shows prohibitions remain legitimate for hard constraints when paired with affirmative fallbacks.
- Fine-tuning narrows (but doesn't close) the negation gap, per the 2026 commonsense paper.
