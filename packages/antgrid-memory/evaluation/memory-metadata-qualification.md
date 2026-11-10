# Memory metadata qualification

Checked on 2026-11-10 UTC on Windows x64 with Bun 1.3.14. This qualifies the
metadata transport and compiled memory service; live agent behavior for the new
metadata guidance remains unqualified.

The memory tools accept optional `title` (256 UTF-8 bytes) and `description`
(512 UTF-8 bytes), with a 16 KiB content limit. Guidance asks agents to supply
concise metadata. Corrections replace the supplied metadata, and omission clears
the corresponding prior field. No model-based summarizer is involved.

## Automated checks

The final memory package suite passed 67 tests and its typecheck, including
migration, metadata lifecycle, byte limits, and the production search ranking
evaluation. The affected Flutter suite passed 167 tests.
The single completed `flutter analyze --no-pub` gate reported no issues, and the
font-token check passed. The initial sandboxed analysis launcher could not start
Dart; it was stopped before the SDK-access retry, with no concurrent analyzer.

An isolated Flutter preview verified metadata and legacy records in desktop
lists, details, history and the 390-pixel correction form after hot restart.
The preview used synthetic requests and no user profile or bridge. Screenshots
are local build artifacts under `app/build/memory-metadata-*.png`. A pre-existing
correction action-bar overflow at 320 pixels remains outside this change; the
metadata list itself passed the 320-pixel widget check.

Review captures from that isolated preview: [desktop list and details](screenshots/memory-metadata-desktop.png)
and [correction editor](screenshots/memory-metadata-editor.png). Both use synthetic
records rather than a user's stored memories.

The focused bridge suite passed 109 tests across eight files:

```sh
bun run --filter antgrid-bridge test src/memory-mcp/client.test.ts src/memory-mcp/server.test.ts tests/memory-protocol.test.ts tests/api-server-memory-route.test.ts tests/memory-caller.test.ts tests/host-memory.test.ts tests/hook-memory-context.test.ts tests/chat-memory-guidance.test.ts
```

These checks cover the metadata and multibyte limits at the adapter and project/
machine payload boundaries, redaction before durable preparation, unchanged
payloads across a lost-response retry, metadata preservation within the 8 KiB
search response budget, caller isolation, and static hook guidance.
`bun run --filter antgrid-bridge typecheck` also passed.

The agent package passed 42 tests and its typecheck:

```sh
bun run --filter antgrid-agents test tests/memory-mcp.test.ts tests/opencode-memory-guidance.test.ts tests/assets.test.ts
bun run --filter antgrid-agents typecheck
```

The compiled bridge and compiled `bridge/scripts/memory-mcp-smoke.ts` harness
passed after the final core and search-ranking changes, using the production CLI
build invocation from the memory-packaging CI job. The isolated SQLite/FTS5
fixture verified:

- The independent memory MCP entry point and current server instructions.
- Exact 16 KiB Unicode content and metadata surviving service/MCP restart.
- An oversized body being rejected, metadata-only search finding the record,
  and direct reads retaining the complete body.
- Duplicate suppression, corrections with updated metadata, and a subsequent
  correction clearing omitted metadata.
- Forgetting the revision chain and refusing replay of an old duplicate save.

Only Windows packaging was exercised locally. The existing CI matrix covers
Linux and macOS; their results are not claimed here. An initial local build-helper
attempt using the programmatic multi-entry `Bun.build` API exited before the MCP
handshake; rebuilding with the repository's `bun build ... --compile` CLI command
passed without a product-code change.

## Live agent readiness

Version and authentication probes ran in isolated native homes with no credential
copying. The previous qualification homes contained no authentication files, and
this process had no inherited provider credentials. The probes reported:

| Agent | Executable version | Isolated authentication | Metadata qualification |
|---|---|---|---|
| Claude Code | 2.1.322 | Not authenticated; status exit 1 | Not run |
| Codex | 0.164.0 | Not authenticated; status exit 1 | Not run |
| OpenCode | 1.19.0 | No authentication file; zero configured credentials | Not run |

No live model turn was started, so automatic metadata saving, recall, correction,
tool-call counts, token usage, latency and charges have no new measurements.
Existing agent qualification is not evidence that the revised metadata guidance
has been demonstrated. The remaining live check is to run an ordinary finding,
cross-session recall, repeat, and correction sequence with authenticated isolated
runtimes, then inspect actual save arguments and persisted metadata.

During the later public benchmark preparation on 2026-11-10, authorized auth-only
copies made isolated native profiles available and a small Claude authentication
probe succeeded. The user then selected local retrieval evaluation only, so no
new metadata qualification or model-backed QA run followed. See
[the public QA status](memory-public-qa-evaluation.md) for that later probe and
[the public retrieval report](memory-public-retrieval-evaluation.md) for the
completed source-retrieval measurements. The earlier authentication observations
above describe their original probe conditions, not a current account limitation.
