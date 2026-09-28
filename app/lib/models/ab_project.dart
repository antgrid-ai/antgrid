/// Persistence model for a folder the user has opened in Antgrid.
///
/// Two orthogonal concerns are tracked here:
///
/// - **Who hosts the agent** — [hostDeviceUuid] is the physical device whose
///   keychain minted the agent's identity. The app compares this against its
///   own device UUID to decide whether to spawn an in-process agent (local) or
///   connect via the relay (remote viewer). See [isLocalFor].
///
/// Legacy JSON (pre-v2) used a `AbMode` enum (`local` / `mobileEnabled`)
/// and an `agentDeviceId` field. [fromJson] migrates those transparently on
/// first read. Drop the migration path after v2.0 ships.
class AbProject {
  final String projectId;
  final String folder;
  String displayName;

  /// The physical device whose keychain minted this project's local agent
  /// identity. `null` only for pre-v2 projects, where the field didn't exist
  /// yet; those are treated as "local to whoever is asking" (see [isLocalFor]).
  ///
  /// The value can go STALE while the folder stays local: this device's own
  /// identity moves when sign-in provisioning replaces an anonymous uuid, and a
  /// row left on the old one fails [isLocalFor] for good. Two paths repair it —
  /// `ensureCurrentUserDeviceRecord` remaps every row carrying the outgoing
  /// uuid as it replaces it, and `registerPickedFolder` re-stamps a row
  /// whenever the user picks that folder again.
  String? hostDeviceUuid;
  String hostMachineName;
  DateTime lastOpenedAt;

  /// Cross-machine repository identity, folded by the HOST from the origin
  /// remote and carried on `project:resolve`. Persisted rather than re-read per
  /// launch because it is what joins this folder to its account-scoped tasks,
  /// and that list arrives over HTTPS: needing a live host to know the key
  /// would make the drawer's task node vanish whenever the bridge is down.
  ///
  /// Null for a folder with no origin remote, and for one not opened since this
  /// field landed. Both mean "nothing to join to" — never "no tasks" — so a
  /// caller must not synthesize one: a wrong key silently re-buckets the folder
  /// onto another repository's work.
  String? repoKey;

  AbProject({
    required this.projectId,
    required this.folder,
    required this.displayName,
    required this.hostDeviceUuid,
    required this.hostMachineName,
    required this.lastOpenedAt,
    this.repoKey,
  });

  /// Returns true iff this project is hosted on the device identified by
  /// [localDeviceUuid].
  ///
  /// Pre-v2 Antgrid had no remote-host concept, so every persisted project was
  /// local-to-this-device. We can't know the device UUID retroactively, but
  /// we DO know the project was opened on the current install. Treating
  /// `hostDeviceUuid == null` as local-here preserves that invariant during
  /// the migration window without misrouting any genuinely-remote project
  /// (which never persisted a null hostDeviceUuid in the new schema).
  bool isLocalFor(String localDeviceUuid) =>
      hostDeviceUuid == null || hostDeviceUuid == localDeviceUuid;

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'folder': folder,
    'displayName': displayName,
    if (hostDeviceUuid != null) 'hostDeviceUuid': hostDeviceUuid,
    'hostMachineName': hostMachineName,
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
    if (repoKey != null) 'repoKey': repoKey,
  };

  static AbProject fromJson(Map<String, dynamic> j) {
    // Legacy migration: pre-v2 JSON used 'mode' / 'agentDeviceId' instead of
    // the current fields. The pre-v2 `agentDeviceId` was the *agent's*
    // identity (per-project or per-host), NOT this device's UUID — there's
    // no honest way to reconstruct hostDeviceUuid from it, so we leave it
    // null and let `isLocalFor` treat the project as local-to-this-device
    // until the next upsert backfills the real value.
    if (!j.containsKey('hostDeviceUuid')) {
      return AbProject(
        projectId: j['projectId'] as String,
        folder: j['folder'] as String,
        displayName: j['displayName'] as String,
        hostDeviceUuid: null,
        hostMachineName: '',
        lastOpenedAt: DateTime.parse(j['lastOpenedAt'] as String),
        // Read here too: a pre-v2 row keeps a null hostDeviceUuid across every
        // re-upsert (toJson omits the key), so it takes this branch forever —
        // and dropping repoKey here would lose the learned key on every restart.
        repoKey: j['repoKey'] as String?,
      );
    }
    return AbProject(
      projectId: j['projectId'] as String,
      folder: j['folder'] as String,
      displayName: j['displayName'] as String,
      hostDeviceUuid: j['hostDeviceUuid'] as String?,
      hostMachineName: j['hostMachineName'] as String? ?? '',
      lastOpenedAt: DateTime.parse(j['lastOpenedAt'] as String),
      repoKey: j['repoKey'] as String?,
    );
  }
}
