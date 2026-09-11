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
/// go wrong, and there is no caller holding a raw URL: the asking session's key
/// comes from the loopback Capability Card and the candidates' from the peer
/// machine's.
///
/// A matching key and nothing else. It says two checkouts came from the same
/// origin, never that either machine may act on the other.
library;

/// The project id in [candidateRemotes] whose repository is the one
/// [leadRemote] names — the asking session's own key — or null when there is no
/// usable answer.
///
/// [candidateRemotes] maps project id to that project's normalised remote, and
/// its ITERATION ORDER is the answer's tiebreak — pass it in the order the
/// caller would offer them, so two clones of one repo on one machine resolve to
/// the one a reader would have reached first rather than an arbitrary one.
///
/// Null whenever [leadRemote] is empty (a repo with no `origin`, a filesystem
/// remote, or a machine that could not answer), and a caller must read that as
/// no match rather than as a match on emptiness: a null key would otherwise
/// pair with every project that also has none. The empty case is refused here
/// rather than at each call site for exactly that reason.
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
