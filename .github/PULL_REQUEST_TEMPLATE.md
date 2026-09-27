<!--
Thanks for this. Two rules — CONTRIBUTING.md has the reasoning:
https://github.com/antgrid-ai/antgrid/blob/development/CONTRIBUTING.md

1. Docs, site, typos and tests can come straight here. Anything else in
   bridge/, app/, packages/, evals/ or scripts/ wants an issue first.
2. relay/, web/ and packages/antgrid-wire are closed to outside patches —
   a licensing constraint, not a judgement on the change. Open an issue.

Delete this comment and fill in the rest.
-->

## What changed

<!-- The change itself, in a sentence or two. -->

## Why

<!-- The problem it solves. Link the issue if there is one, e.g. "fixes #123". -->

## How it was verified

<!--
What you ran or clicked to convince yourself it works, and on which platform.
Name the tests you ran for the workspaces you touched. If you couldn't run
something (no Postgres, no macOS, no device), say so — that's useful, not
disqualifying.
-->

## Screenshots

<!-- Required for anything that changes the UI. Before and after if you have both. Delete this section otherwise. -->

## Checklist

- [ ] This PR targets `development`, not `main`
- [ ] One logical change — unrelated fixes go in their own PR
- [ ] Tests pass for the workspaces this touches
- [ ] Docs updated if this changes behaviour someone relies on
