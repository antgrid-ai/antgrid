# Commands reference

On-demand commands. The everyday ones (setup, launchers, the test/analyze
gates) live in the root `CLAUDE.md`; this file holds the rest so they cost no
context until you need them.

## Occasional dev commands

```bash
# Grant Pro to an OAuth-created user (dev only, idempotent). `npm run setup`
# only seeds dev@antgrid.local; real OAuth sign-ins need this.
bun run scripts/dev-grant.ts <email>

cd web && bun run migrate        # prisma migrate deploy
cd web && bun run generate:key   # Ed25519 signing seed
```

## Worktrees

Only when asked — see the note at the top of the root `CLAUDE.md`.

`scripts/worktree.ts` provisions the gitignored artifacts a bare `git worktree
add` leaves missing (`node_modules`, prisma client, per-service `.env`, Flutter
`.dart_tool`) — use it, not raw git, so the worktree is test-ready. `.env` is
copied from main (run `npm run setup` there first).

```bash
npm run worktree -- <name>   # create .claude/worktrees/<name> + provision
npm run worktree             # provision the CURRENT worktree
# flags: --branch <b> --from <ref> --no-flutter --no-db --seed (--seed ⊥ --no-db)
```

## Read-only helpers (agent quality-of-life)

Both are read-only and replace common multi-command probes; prefer them over
hand-rolling `git rev-parse`/`merge-base`/`ls .env` or per-file `git grep`.

```bash
npm run wt                   # where am I + is this worktree provisioned? (--json)
                             # reports worktree-vs-main, branch, ±commits vs main,
                             # and presence of the provision artifacts worktree.ts copies
npm run sym -- <Symbol>      # locate a symbol across ALL workspaces, defs split from
                             # usages (git grep -w; code only, .md/docs excluded).
                             # flags: --defs  --ts | --dart | --all  --json
```

## Bridge CLI

```bash
cd bridge && bun run dev init    # Generate default antgrid.yaml
```

**Phone management:** `antgrid phones list|remove` (`bridge/src/cli/phones.ts`).
Trust is machine-level (one `<ANTGRID_DIR>/agents/paired-phones.json` —
`resolveAbDir()` in `antgrid-dir.ts`, `~/.antgrid` by default, `~/.antgrid-dev`
for a local dev build; no `<projectId>` segment — see `paired-phones.ts`).

`remove` is **NOT** a revocation: an account-trusted phone re-creates its row on
the next hello, so removal only clears the local record (label, `lastSeenAt`,
push token). Cutting a phone off means turning the machine's remote-access
switch off (all phones) or signing that device out of the account.

The CLI resolves `ANTGRID_DIR` from its own shell env, so it only sees a dev
host's store if that env matches how the host was launched.
