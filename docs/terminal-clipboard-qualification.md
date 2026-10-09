# Terminal clipboard qualification

Status: implemented; platform qualification incomplete.

The [accepted specification](terminal-clipboard-sharing.md) defines the completion gates. Automated tests use recording or failing clipboard adapters and synthetic helper output. They do not replace the developer's clipboard.

## Automated evidence

| Gate | Evidence |
| --- | --- |
| Streaming scanner, ownership, schemas, host-reader seams | `cd bridge && bun run test src/terminal-clipboard` |
| Subscription compatibility and attachment authorization | `cd bridge && bun run test tests/terminal-frame-delivery.test.ts tests/terminal-frame-protocol.test.ts` |
| Real PTY over authenticated Iroh, two viewers, conflicts, raw-log and replay audit | `cd evals && bun run test:evals:terminal-clipboard` |
| Device write ordering, failures, stale context and deduplication | `cd app && flutter test -j 2 test/terminal_clipboard_test.dart` |
| Stable selection under streaming frames | `cd app && flutter test -j 2 test/widgets/terminal_frame_mode_widget_test.dart` |
| Component gates | Bridge typecheck/tests; Flutter suite and serial analysis; font-token and scoped duplicate checks |

Recorded on Windows on 2026-10-09:

- Focused bridge gate: 123 tests passed across clipboard modules, frame delivery/cancellation, frame protocol, and checkout classification. Scanner regressions include C1 introducers, ignored controls, numeric command aliases, and malformed nested strings. Native-helper tests use synthetic stdout, never the OS clipboard.
- Real-PTY/Iroh gate: passed, including two authenticated viewers, conflict revocation, result acknowledgement, unsubscribe/resubscribe without replay, and exclusion of text/base64 from raw PTY logging.
- Bridge and eval typechecks: passed after correcting the new test fixtures' literal types.
- App clipboard and metadata-only diagnostic tests passed; clipboard coverage includes a delayed grant expiring from request time and a queued write discarded after expiry.
- Targeted selection/controller suite: 150 tests passed, including actual mouse drag and touch handles while frames arrive, Unicode, independent surfaces, failed writes, and stale completion.
- Review regression gates: 37 clipboard module tests and 126 history/frame widget tests passed. Escape-cancelled OSC/DCS/APC/PM output recovers across chunk boundaries without exposing clipboard payloads. The visible history Copy action is covered by touch-only tests at phone width, failed-write retry, and a newer selection surviving an older write completion. The real-PTY/Iroh gate and serial Flutter analysis also passed after these fixes.
- Font-token check: passed through Git Bash. The npm wrapper resolves `bash` to an unavailable WSL shell on this machine.
- Scoped duplicate check: passed with no clones in the new clipboard implementation.
- The broad bridge run reported 6102 passed, 18 skipped and 7 failed. It overlapped module/test edits; the clipboard failures and schema-discovery test passed in the subsequent stable focused run. The scheduler DST timing test passed in isolation. `scheduler-agent.test.ts` still fails in teardown with Windows `EBUSY` removing its temporary project, after its assertions pass. The broad gate is therefore not claimed green.
- Windows Driver launch, hot reload, screenshots, Select text, and Return to live were verified with no application runtime errors. Native plugin CMake emitted a symlink warning but the launch succeeded. The task-owned app/host processes were stopped after verification; the existing app was left running.
- A local 100-frame controller benchmark measured 5.255 ms for the authoritative engine, 9.635 ms with the live presentation surface, and 3.547 ms while frozen. This is a small synthetic observation, not a cross-platform performance qualification.

The full Flutter run completed with 5,140 passing, five skipped, and three failing tests. The failures were the contract test's imported-schema discovery and two newly added run-replacement assertions compiled before the final widget update. A fresh-process run of all 69 frame-widget and checkout-contract tests passed. Both pointer tests also passed after adding engine-replacement coverage with a shared frame notifier. Final serial `flutter analyze --no-pub` passed with no issues. Passing synthetic tests does not qualify an OS clipboard backend or an agent's copy command.

## Installed agents

Recorded on Windows on 2026-10-09 through each installed executable's `--version` command:

| Agent | Installed version | Guest copy qualification |
| --- | --- | --- |
| Claude Code | 2.1.295 | Not run |
| Codex CLI | 0.162.0 | Not run |
| OpenCode | 1.18.35 | Not run |

These are installed versions, not claims about the newest available release. No SSH environment spoofing or clipboard utility shims were used. Native-host copying alone is not evidence of OSC delivery. For each agent, qualification must record direct/tmux output, host clipboard availability, native-only fallback, guest pointer selection, and attachment after startup.

## Platform matrix

| Platform | Required acceptance | Status |
| --- | --- | --- |
| Windows | Mouse selection; native text/non-text reads; hidden helper; real guest copy commands | Incomplete |
| macOS | Cmd+C; native text/non-text reads; direct/tmux agent behavior | Not run; hardware unavailable in this workspace |
| Linux X11 | Selection and xclip/xsel text/backend fallback | Not run; display unavailable in this workspace |
| Linux Wayland | Selection and wl-paste text/backend fallback | Not run; display unavailable in this workspace |
| Android | Touch handles during streaming; rotation; copy into another app; paste back; background/reconnect | Not run; real device unavailable in this workspace |
| iOS | Touch handles during streaming; rotation; copy into another app; paste back; background/reconnect | Not run; real device unavailable in this workspace |

All platforms also need accessibility labels, text scaling, success/failure feedback, alternate screens, and duplicate-surface checks. Feature qualification remains incomplete until the declared gates pass.
