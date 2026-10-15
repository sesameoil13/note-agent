# Domain Docs

## Read before exploration

- Read root GLOSSARY.md before exploring domain behavior or naming domain concepts.
- Read relevant docs/adr/ decisions before proposing or changing behavior in their area.
- If GLOSSARY-MAP.md is introduced later, follow it to the relevant context glossary and ADRs.

If a referenced domain file does not exist, proceed silently. Domain-modeling creates documents when terms or decisions become resolved.

## Layout

This repository has a single context: root GLOSSARY.md and docs/adr/. Do not introduce per-package glossaries unless the project develops genuinely distinct contexts.

## Vocabulary and decisions

Use canonical glossary terms in issue titles, specifications, hypotheses and test names. Avoid synonyms the glossary excludes.
If a needed concept is missing, resolve its meaning through domain-modeling before adding a term.
When a proposal contradicts an ADR, identify the ADR and explain the tradeoff before changing the decision; do not silently override it.
