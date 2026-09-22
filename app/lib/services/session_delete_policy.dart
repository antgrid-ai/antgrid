// The two symbols the drawer's data-plane delete and the Recent list's
// control-plane delete must agree on. Imports nothing, so either side can
// depend on it without pulling the other in.

/// What came back from one delete attempt.
///
/// [deleted] is the bridge's own yes. [outcomeUnknown] means the request was
/// dispatched but no application answer came back, so execution must not be
/// guessed or automatically repeated. A refusal raises separately because it
/// is the confirm ladder's input.
enum SessionDeleteAck { deleted, outcomeUnknown }

/// Transport backstop for a delete reply. **Not a deadline.**
///
/// The bridge's removal work has no bound of its own — `runGit` in
/// `bridge/src/worktrees/project-resolver.ts` takes no timeout, and measured
/// deletes have run 12.5s and 14.2s — so no value here can mean "it failed".
/// Its only job is to release the pending entry (and its timer) when the
/// transport is dead, which is why it is far larger than any plausible delete
/// rather than tuned to one.
///
/// The terminal success signal is the session leaving the list, never this
/// timer expiring.
const kSessionDeleteAckTimeout = Duration(minutes: 2);
