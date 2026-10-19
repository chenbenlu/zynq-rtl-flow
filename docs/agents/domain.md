# Domain Docs

How engineering skills consume this repo's domain documentation.

## Before exploring, read

- **`CONTEXT.md`** at the repo root — or **`CONTEXT-MAP.md`** if it exists, which
  points at one `CONTEXT.md` per context; read each one relevant to the topic.
- **`docs/adr/`** — the ADRs that touch the area you are about to work in. In a
  multi-context repo, also `src/<context>/docs/adr/` for context-scoped decisions.

This repo is single-context: one `CONTEXT.md` and one `docs/adr/` at the root.

If any of these files is missing, proceed silently: neither flag its absence nor
suggest creating it upfront. The `/domain-modeling` skill (reached via
`/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily, when
terms or decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor proposal, a
hypothesis, a test name), use the term as `CONTEXT.md` defines it, not a synonym
the glossary avoids.

A concept missing from the glossary is a signal: either you are inventing
language the project does not use (reconsider), or there is a real gap (note it
for `/domain-modeling`).

## Flag ADR conflicts

When your output contradicts an existing ADR, say so explicitly:

> _Contradicts ADR-0007 (rename the repository to zynq-rtl-flow) — but worth reopening because…_
