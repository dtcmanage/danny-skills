# Voice Reference Load Order

The canonical pre-write load sequence for any skill that produces written content on Danny's behalf. Load all three in this order before drafting a single sentence; a piece written without them sounds generic and gets discarded.

This file is the single source for what to load and what each layer governs. Skill-local logic still owns the genre-specific fallback when the third file (the genre style profile) is missing — see each consuming skill's SKILL.md for that handling.

## The three layers (read in order)

1. **Voice principles — the email base.**
   `D:\Claude\_Claude-Workspace\00_Resources\voice-principles.md`
   Genre-independent floor extracted from Danny's *email*: word choice, banned phrases, tone. Its word-choice and tone rules carry over to long-form, but it does not govern long-form on its own.

2. **Business writing voice — the governing reference for long-form.**
   `D:\Claude\_Claude-Workspace\00_Resources\voice-principles-business.md`
   Distilled from Danny's actual business documents. Governs everything long-form: the two registers (personal vs institutional), structure, sentence rhythm, how he handles numbers and bad news, punctuation, and how the voice flexes by document type. **Where it and the email file differ — em dashes and the word "leverage" being the clearest cases — this file wins for business writing.**

3. **Genre style profile — the per-genre layer.**
   `D:\Claude\_Claude-Workspace\00_Resources\style-<genre>.md`
   `<genre>` is the kebab-case slug (e.g. `style-investor-letter.md`). Captures how Danny actually writes that genre: structure, rhythm, numbers handling, recurring devices, topics to skip. Read it if it exists. If it doesn't, the consuming skill decides whether to build one (the style-study procedure lives in `dt-writing-draft`) or to proceed with weaker structural and rhythm judgments and tell Danny so.

## Why this matters

These references are what make output sound like Danny rather than like a model. Loading them is a standing rule, not a suggestion. The hierarchy (3 > 2 > 1 for long-form business writing) resolves the punctuation and word-choice tensions between the email base and the business profile.
