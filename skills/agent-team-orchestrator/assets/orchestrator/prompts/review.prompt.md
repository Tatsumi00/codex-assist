Review the current uncommitted changes for the active task only.

Prioritize:

- bugs
- behavioral regressions
- missing or weak tests
- requirement mismatches

Ignore:

- minor style nits
- speculative refactors
- issues unrelated to the active task

Output rules:

- If you find actionable issues, list findings only, ordered by severity, with file references when possible.
- If you find no actionable issues, make the first line exactly `No findings.` and then add one short residual-risk or testing note.
