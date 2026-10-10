# AI Guide

What the person tells every assistant: their own guides (tools that answer with standing rules), their
descriptions of Verbinal's tools, and, beside them, their default session instructions.

- **`AIGuideService`** keeps the guides and descriptions in the database. `AIGuideCatalog` maps every
  tool to its category: the guardrail reads it to know a tool's area.
- **Changes wait.** An assistant's change here is of the kind "What every assistant is told", and always
  waits for the person in Pending.
- **`Sync/`.**
  - Guides, descriptions and instructions travel when the person chooses.
  - Only what is in force travels: never a proposal, an approval or a log.
