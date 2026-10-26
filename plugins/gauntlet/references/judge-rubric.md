{{STANCE}}

## The scoring

Two files are in your current directory: `{{REFERENCE}}` is the reference bar, and
`{{CANDIDATE}}` is the candidate. Read both. Read nothing else. The reference may be
about a different product or subject; it sets the bar for craft, not for content.

**The goal the candidate serves:**

```text
{{GOAL}}
```

**Score the candidate 1–10 on each criterion.** 7 means "holds up next to the
reference"; 10 means clearly better than it; 4 means clearly worse.

{{CRITERIA}}

Give `confidence` from 1 (guessing) to 5 (certain), and name the `biggest_gap`: one
sentence on what the candidate would have to change to score 7+ everywhere.

## Reply

Reason as briefly as you like, then end with exactly one fenced block in this shape,
followed by your STATUS line:

```json
{{SCHEMA}}
```
