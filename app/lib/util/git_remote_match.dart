/// Which of a machine's projects is the same repository as the one a session
/// already runs in — the discovery key for reaching the same repo on another
/// machine (`docs/session-messaging.md` §5.1).
///
/// Both sides are the bridge's NORMALISED remote (`RepoCard.remote`), never a
/// raw URL: normalisation is where credentials are stripped and where the ssh
/// and https spellings of one repo converge, and it is deliberately done once,
/// on the machine that owns the repo (`normalizeRemoteUrl` in
/// `bridge/src/capability-card.ts`). Nothing here re-implements it — an app-side
/// copy of a credential-stripping function is a second place for that strip to
/// go wrong, and there is no caller holding a raw URL: the lead's key comes from
/// the loopback Capability Card and the candidates' from the peer machine's.
///
/// A matching key and nothing else. It says two checkouts came from the same
/// origin, never that either machine may act on the other.
library;

/// The project id in [candidateRemotes] whose repository is [leadRemote]'s, or
/// null when there is no usable answer.
///
/// [candidateRemotes] maps project id to that project's normalised remote, and
/// its ITERATION ORDER is the answer's tiebreak — pass it in the order the
/// dropdown renders, so two clones of one repo on the same machine pre-select
/// the row the user would have reached first rather than an arbitrary one.
///
/// Null whenever the lead has no remote (a repo with no `origin`, a filesystem
/// remote, or a machine that could not answer), which is the same outcome as no
/// match: the dialog leaves the project unselected and the user picks. A
/// pre-selection is always overridable, so a wrong guess costs a click — but a
/// guess made from a null key would match every other project with no remote,
/// which is why the empty case is refused here rather than at the call site.
String? preselectProjectByRemote({
  required String? leadRemote,
  required Map<String, String?> candidateRemotes,
}) {
  if (leadRemote == null || leadRemote.isEmpty) return null;
  for (final entry in candidateRemotes.entries) {
    final remote = entry.value;
    if (remote == null || remote.isEmpty) continue;
    if (remote == leadRemote) return entry.key;
  }
  return null;
}
