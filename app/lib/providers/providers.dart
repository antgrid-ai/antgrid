import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../config/storage_scope.dart';
import '../models/ab_message.dart'
    show CommandInfo, NotificationPushMessage, TerminalNotificationMessage;
import '../models/qr_payload.dart';
import '../models/session_target.dart';
import '../models/terminal_models.dart';
import '../project/project_session.dart';
import '../project/project_session_registry.dart';
import '../services/license_token_minter.dart';
import '../services/pairing_service.dart';
import '../services/phone_identity.dart';
import '../services/storage_service.dart';
import 'analytics.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'entry_cleanup.dart';
import 'agent_transport.dart';
import 'provider_retry.dart';
import 'relay_connection.dart';
import 'seeded_stream.dart';
import 'recent_agents.dart';
import '../storage/recent_agents_store.dart';
import '../models/file_tree_models.dart';
import '../models/preview_models.dart';
import '../services/file_service.dart';
import '../services/preview_service.dart';
import '../services/terminal_service.dart';
import '../models/command_models.dart';
import '../services/command_service.dart';
import '../services/preferences_service.dart';
import '../util/device_id.dart';
import '../models/preferences_models.dart';
import '../services/search_service.dart';
import '../models/search_models.dart';
import '../models/handler_state.dart';
import '../services/config_service.dart';
import '../services/agent_session_service.dart';
import '../services/handler_service.dart';
import '../services/sessions_service.dart';
import '../services/upload_service.dart';
import 'client_id.dart';
import 'value_controller.dart';

/// Extract project name from compound agentDeviceId (uuid.projectId).
String projectNameFromId(String agentDeviceId) {
  final dotIndex = agentDeviceId.indexOf('.');
  if (dotIndex < 0) return agentDeviceId;
  return agentDeviceId.substring(dotIndex + 1);
}

final storageServiceProvider = Provider<StorageService>(
  (ref) => StorageService(),
);

final cryptoServiceProvider = Provider<CryptoService>((ref) => CryptoService());

final phoneIdentityProvider = Provider<PhoneIdentity>(
  (ref) => PhoneIdentity.secure(),
);

/// Builds a `LicenseTokenMinter` from the current keychain `DeviceRecord`.
/// Returns `null` when the user hasn't been provisioned yet (signed out, or
/// signed in but `DeviceProvisioning.ensureProvisioned` hasn't run). The
/// provider is rebuilt by invalidating it after provisioning succeeds.
final licenseTokenMinterProvider = FutureProvider<LicenseTokenMinter?>((
  ref,
) async {
  final store = ref.watch(keychainDeviceStoreProvider);
  final record = await store.read();
  if (record == null) return null;
  return LicenseTokenMinter(
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    clientId: record.clientId,
    clientSecret: record.clientSecret,
  );
});

/// The app's per-launch relay epoch — a single global monotonic counter in
/// SharedPreferences (`antgrid.relay_epoch`), computed once as
/// `max(stored + 1, unixSeconds)` and persisted (design §6.3). The wall-clock
/// floor makes a storage wipe / reinstall a non-event: a fresh install still
/// out-epochs any zombie connection whose counter came from a sane past.
final relayEpochProvider = FutureProvider<int>((ref) async {
  final key = scopedStorageKey('antgrid.relay_epoch');
  // SharedPreferencesAsync, not the legacy getInstance() — this repo's prefs
  // convention (see device_provisioning.dart) and the only API the in-memory
  // test platform backs.
  final prefs = SharedPreferencesAsync();
  var stored = 0;
  try {
    stored = await prefs.getInt(key) ?? 0;
  } catch (_) {
    // Unreadable storage falls back to the wall-clock floor below — never fail
    // closed, an epoch is only a monotonic tiebreaker (keep in lockstep with
    // bridge/src/relay-epoch.ts).
  }
  final unixSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final epoch = math.max(stored + 1, unixSeconds);
  try {
    await prefs.setInt(key, epoch);
  } catch (_) {
    // Persist failure only risks a non-monotonic epoch after a same-second
    // relaunch; the relay rejects an equal/lower epoch, so worst case is one
    // reconnect retry — not a correctness hazard.
  }
  return epoch;
});

/// A [PairingService] bound to the single relay socket of the machine
/// [machineDeviceId] (bare `deviceUuid`). v3: pairing is machine-level — one
/// grant per (machine, phone-key) lifetime over the one socket. The compound
/// project id is reduced to its base machine inside the service.
final pairingServiceForProvider = Provider.family<PairingService, String>((
  ref,
  machineDeviceId,
) {
  final relay = ref
      .read(relayConnectionManagerProvider)
      .connectionFor(machineDeviceId)
      .relay;
  return PairingService(
    relay: relay,
    phoneIdentity: ref.read(phoneIdentityProvider),
    recentAgentsStore: ref.read(recentAgentsStoreProvider),
    deviceStore: ref.read(keychainDeviceStoreProvider),
    registrationId: machineDeviceId,
    epochProvider: () => ref.read(relayEpochProvider.future),
    analytics: ref.read(analyticsServiceProvider),
    tokenProvider: () async {
      // Returns `null` only when the user is not provisioned (signed-out or
      // pre-sign-in): autoOpen can then degrade gracefully into the
      // "phone hasn't authed" path. Once a minter exists, any failure to
      // produce a token is propagated — autoOpen has no pairCode fallback,
      // so swallowing here would only convert one error (transient mint
      // failure) into another, less informative one (UNKNOWN_PHONE rejection
      // from the agent).
      final minter = await ref.read(licenseTokenMinterProvider.future);
      if (minter == null) return null;
      final cached = minter.getToken();
      if (cached != null) return cached;
      return minter.mint();
    },
  );
});

/// Per-project TerminalService façade.
final terminalServiceProvider = Provider<TerminalService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.terminalService;
});

final terminalStateProvider = StreamProvider<TerminalState>((ref) {
  final service = focusedSessionOrNull(ref)?.terminalService;
  if (service == null) return const Stream<TerminalState>.empty();
  // Push the stable per-install client id into the service so sendResize can
  // stamp it. The setter is idempotent; the id resolves at startup well before
  // any user resize. Source via focusedSessionOrNull (non-throwing) above, so
  // this watch never lands on the throwing terminalServiceProvider façade.
  final clientId = ref.watch(clientIdProvider).value;
  if (clientId != null) service.setClientId(clientId);
  // seededStream (not a `yield currentState; yield* stream` seed): stateStream is
  // a broadcast stream with no replay, so the naive seed drops any state emitted
  // in the gap between snapshot and subscription — e.g. the agent:status /
  // terminal:started that creates the agent tab for a just-started session,
  // stranding this on "waiting for agent" until a project switch re-subscribes.
  return seededStream(() => service.currentState, service.stateStream);
});

/// Agent desktop-notification signals (OSC 9 / OSC 777) merged across
/// ALL warm projects — not just the focused one — so a background project's
/// agent can still raise a toast / OS notification. Rebuilds (and re-subscribes)
/// when the warm set changes or a session resolves; the warm-set is small
/// (kWarmCap), so the per-rebuild resubscribe is cheap.
final terminalNotificationsProvider =
    StreamProvider<TerminalNotificationMessage>((ref) {
      final openProjects = ref.watch(projectSessionRegistryProvider);
      final controller = StreamController<TerminalNotificationMessage>();
      final subs = <StreamSubscription<TerminalNotificationMessage>>[];
      for (final id in openProjects) {
        final session = ref.watch(projectSessionProvider(id)).value;
        if (session == null) continue;
        subs.add(
          session.terminalService.notificationStream.listen(controller.add),
        );
      }
      ref.onDispose(() {
        for (final s in subs) {
          s.cancel();
        }
        controller.close();
      });
      return controller.stream;
    });

/// Plugin/hook-sourced agent notifications (notification:push) merged across all
/// warm projects — same fan-out as terminalNotificationsProvider but for the
/// intent-aware plugin path. Rebuilds when the warm set changes.
final agentPushNotificationsProvider = StreamProvider<NotificationPushMessage>((
  ref,
) {
  final openProjects = ref.watch(projectSessionRegistryProvider);
  final controller = StreamController<NotificationPushMessage>();
  final subs = <StreamSubscription<NotificationPushMessage>>[];
  for (final id in openProjects) {
    final session = ref.watch(projectSessionProvider(id)).value;
    if (session == null) continue;
    subs.add(
      session.terminalService.pushNotificationStream.listen(controller.add),
    );
  }
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
    controller.close();
  });
  return controller.stream;
});

/// Handler "needs you" escalations (handler:escalation) merged across all warm
/// projects — same fan-out as [agentPushNotificationsProvider]. Drives the
/// lifecycle-aware in-app toast / OS notification for escalations across every
/// warm project (not just the focused one).
///
/// escalationStream is broadcast with no replay, and this provider re-runs
/// (cancel + resubscribe) whenever the warm set or any session resolves — so an
/// escalation that landed before the (re)subscription would otherwise be lost.
/// Each subscribe therefore also seeds the project's currently-pending
/// escalations; the consumer de-dupes by escalationId, so re-seeding the same id
/// across rebuilds is harmless.
final handlerEscalationsProvider = StreamProvider<HandlerEscalation>((ref) {
  final openProjects = ref.watch(projectSessionRegistryProvider);
  final controller = StreamController<HandlerEscalation>();
  final subs = <StreamSubscription<HandlerEscalation>>[];
  for (final id in openProjects) {
    final session = ref.watch(projectSessionProvider(id)).value;
    if (session == null) continue;
    final handler = session.handlerService;
    subs.add(handler.escalationStream.listen(controller.add));
    for (final esc in handler.currentState.escalations) {
      controller.add(esc);
    }
  }
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
    controller.close();
  });
  return controller.stream;
});

final agentTerminalProvider = Provider<TerminalTab?>((ref) {
  final state = ref.watch(terminalStateProvider).value;
  if (state == null) return null;
  try {
    return state.tabs.values.firstWhere(
      (tab) => tab.isAgent && tab.sessionState == TerminalSessionState.running,
    );
  } on StateError {
    return null;
  }
});

/// Per-project CommandService façade.
final commandServiceProvider = Provider<CommandService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.commandService;
});

/// Per-project ConfigService façade.
final configServiceProvider = Provider<ConfigService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.configService;
});

/// Per-project HandlerService façade.
final handlerServiceProvider = Provider<HandlerService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.handlerService;
});

final handlerStateProvider = StreamProvider<HandlerState>((ref) {
  final service = focusedSessionOrNull(ref)?.handlerService;
  if (service == null) return const Stream<HandlerState>.empty();
  return seededStream(() => service.currentState, service.stateStream);
});

/// Per-project SessionsService façade.
final sessionsServiceProvider = Provider<SessionsService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.sessionsService;
});

/// Transient error thrown by the per-project service façades while the
/// underlying [projectSessionProvider] future is still resolving (transport
/// connect + session construction is async). StreamProvider consumers that
/// `ref.watch` the façade will re-evaluate when the session resolves and the
/// façade returns the real service. NOT a legacy/relay trip-wire — this is
/// the expected first-frame state after openFolder.
class _ProjectSessionLoading implements Exception {
  final String projectId;
  _ProjectSessionLoading(this.projectId);

  @override
  String toString() => 'ProjectSession "$projectId" is still initializing.';
}

/// The focused project's [ProjectSession] once it has finished constructing,
/// else null (no project focused, or the session is still resolving after a
/// project switch).
///
/// Safe to `ref.watch` — unlike the per-project service façades
/// ([fileServiceProvider], [terminalServiceProvider], …), which THROW
/// [_ProjectSessionLoading] while the session resolves. A throwing synchronous
/// `Provider` that has listeners is re-run by Riverpod's own scheduler whenever
/// a dependency changes (e.g. on every project switch); that scheduled re-run
/// throws outside any `build()`, surfacing as an unhandled exception. So every
/// derived provider sources its service from THIS (a non-throwing
/// [FutureProvider] read) rather than `ref.watch`ing a façade. Watching this
/// re-evaluates the caller when the session resolves or focus changes.
ProjectSession? focusedSessionOrNull(Ref ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) return null;
  return ref.watch(projectSessionProvider(id)).value;
}

/// Reads a per-project service façade ([fileServiceProvider],
/// [terminalServiceProvider], …) for use at widget build time, returning null
/// while the focused project's [ProjectSession] is still constructing (or no
/// project is focused). Widgets that need the service object in `build()` gate
/// on this and render a loading placeholder when it returns null.
///
/// It `watch`es only the non-throwing readiness signals (focus + session) and
/// `read`s the façade once — never `watch`ing the throwing façade itself, which
/// would register a listener that turns Riverpod's next scheduler-driven re-run
/// into an unhandled exception. Watching the readiness signals still rebuilds
/// the widget when the session resolves.
T? serviceWhenReady<T>(WidgetRef ref, ProviderListenable<T> provider) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) return null;
  if (!ref.watch(projectSessionProvider(id)).hasValue) return null;
  return ref.read(provider);
}

final commandStateProvider = StreamProvider<CommandState>((ref) {
  final service = focusedSessionOrNull(ref)?.commandService;
  if (service == null) return const Stream<CommandState>.empty();
  return seededStream(() => service.currentState, service.stateStream);
});

final commandsProvider = Provider<List<CommandInfo>>((ref) {
  final terminalState = ref.watch(terminalStateProvider);
  return terminalState.value?.commands ?? [];
});

final preferencesServiceProvider = Provider<PreferencesService>((ref) {
  final service = PreferencesService();
  ref.onDispose(() => service.dispose());
  return service;
});

final projectPreferencesProvider = StreamProvider<ProjectPreferences>((ref) {
  final prefsService = ref.read(preferencesServiceProvider);
  final projectId = ref.watch(selectedRegistrationIdProvider);

  if (projectId == null) {
    return const Stream<ProjectPreferences>.empty();
  }

  // Source the FileService from the (non-throwing) session, not the façade:
  // re-evaluates once the async ProjectSession resolves, and never registers a
  // listener on the throwing façade (see [focusedSessionOrNull]).
  final fileService = focusedSessionOrNull(ref)?.fileService;
  if (fileService == null) {
    return const Stream<ProjectPreferences>.empty();
  }

  return prefsService.stream.transform(
    StreamTransformer<ProjectPreferences, ProjectPreferences>.fromBind((
      stream,
    ) async* {
      if (prefsService.projectId != projectId) {
        final prefs = await prefsService.load(projectId);
        fileService.applyPreferences(prefs);
        yield prefs;
      } else {
        yield prefsService.current;
      }
      yield* stream;
    }),
  );
});

/// Per-project FileService façade.
final fileServiceProvider = Provider<FileService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.fileService;
});

/// Per-project UploadService façade. Throwing façade — read via
/// [serviceWhenReady], never `ref.watch`.
final uploadServiceProvider = Provider<UploadService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.uploadService;
});

/// Module-level state for the preferences→FileService binding.
///
/// These globals are intentionally singletons — they mirror the singleton
/// nature of the Riverpod providers they serve. A side-effect is that
/// multiple [ProviderContainer]s in the same Dart isolate (e.g. in tests)
/// can interfere with each other if containers are not disposed between
/// tests. The [ref.onDispose] cleanup in [_maybeBindPreferencesSync] resets
/// all three flags, so as long as each test disposes its container the
/// residual risk is acceptable.
FileService? _prefsBoundService;
StreamSubscription<dynamic>? _prefsBoundSub;
bool _disposerRegistered = false;

void _maybeBindPreferencesSync(Ref ref, FileService service) {
  if (identical(_prefsBoundService, service)) return;
  _prefsBoundSub?.cancel();
  _prefsBoundService = service;
  final prefsService = ref.read(preferencesServiceProvider);
  Set<String>? lastExpanded;
  String? lastSelectedFile;
  bool? lastShowChanged;
  _prefsBoundSub = service.stateStream.listen((state) {
    if (prefsService.projectId == null) return;
    final selectedFile = state.files.selectedFilePath;
    if (identical(state.expandedPaths, lastExpanded) &&
        selectedFile == lastSelectedFile &&
        state.showChangedOnly == lastShowChanged) {
      return;
    }
    lastExpanded = state.expandedPaths;
    lastSelectedFile = selectedFile;
    lastShowChanged = state.showChangedOnly;
    prefsService.update(
      prefsService.current.copyWith(
        expandedPaths: state.expandedPaths,
        selectedFilePath: selectedFile,
        clearSelectedFilePath: selectedFile == null,
        showChangedOnly: state.showChangedOnly,
      ),
    );
  });
  if (!_disposerRegistered) {
    _disposerRegistered = true;
    ref.onDispose(() {
      _prefsBoundSub?.cancel();
      _prefsBoundSub = null;
      _prefsBoundService = null;
      _disposerRegistered = false;
    });
  }
}

final fileTreeStateProvider = StreamProvider<FileTreeState>((ref) {
  final service = focusedSessionOrNull(ref)?.fileService;
  if (service == null) return const Stream<FileTreeState>.empty();
  // Anchor the prefs⇄file-tree binding here: this provider is the stable
  // long-lived watcher of the focused FileService (kept alive by the workspace
  // shell), and it sources the service safely. Previously the binding hung off
  // fileServiceProvider, but nothing may `watch` that throwing façade anymore.
  _maybeBindPreferencesSync(ref, service);
  return seededStream(() => service.currentState, service.stateStream);
  // retry: a tree-load error must surface to the screen's error state, not spin
  // in Riverpod 3's default retry loop (which would leave the UI on "loading").
  // See provider_retry.dart.
}, retry: noProviderRetry);

/// Per-project SearchService façade.
final searchServiceProvider = Provider<SearchService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.searchService;
});

final searchStateProvider = StreamProvider<SearchState>((ref) {
  final service = ref.watch(searchServiceProvider);
  return seededStream(() => service.currentState, service.stateStream);
});

/// Per-project PreviewService façade.
final previewServiceProvider = Provider<PreviewService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.previewService;
});

final previewStateProvider = StreamProvider<PreviewState>((ref) {
  final service = ref.watch(previewServiceProvider);
  return seededStream(() => service.currentState, service.stateStream);
});

/// Per-project structured-agent service façade.
final agentSessionServiceProvider = Provider<AgentSessionService>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) {
    throw StateError(
      'No project focused. Open a folder or pair an agent first.',
    );
  }
  final session = ref.watch(projectSessionProvider(id)).value;
  if (session == null) throw _ProjectSessionLoading(id);
  return session.agentSessionService;
});

/// Per-session structured-agent state. Keyed by chat session id so one project
/// can hold several concurrent chat sessions (see AgentSessionService).
final agentSessionStateProvider = StreamProvider.family<AgentSessionState, String>((
  ref,
  sessionId,
) {
  // Source via focusedSessionOrNull (non-throwing) — NOT ref.watch of the
  // throwing agentSessionServiceProvider façade, which would register a listener
  // that turns Riverpod's next scheduler-driven re-run into an unhandled
  // exception on project switch (see focusedSessionOrNull).
  final service = focusedSessionOrNull(ref)?.agentSessionService;
  if (service == null) return const Stream<AgentSessionState>.empty();
  return seededStream(
    () => service.stateFor(sessionId),
    service.stateStreamFor(sessionId),
  );
});

final deviceIdentityProvider =
    AsyncNotifierProvider<DeviceIdentityNotifier, DeviceIdentity>(
      DeviceIdentityNotifier.new,
    );

class DeviceIdentityNotifier extends AsyncNotifier<DeviceIdentity> {
  @override
  Future<DeviceIdentity> build() async {
    final storage = ref.read(storageServiceProvider);
    final existing = await storage.loadIdentity();
    if (existing != null) return existing;

    // Generate new identity on first launch
    final crypto = ref.read(cryptoServiceProvider);
    final (ed25519Priv, ed25519Pub) = await crypto.generateEd25519KeyPair();
    final (x25519Priv, x25519Pub) = await crypto.generateX25519KeyPair();

    final identity = DeviceIdentity(
      deviceId: const Uuid().v4(),
      name: 'Antgrid App',
      ed25519PrivateKey: ed25519Priv,
      ed25519PublicKey: ed25519Pub,
      x25519PrivateKey: x25519Priv,
      x25519PublicKey: x25519Pub,
    );

    await storage.saveIdentity(identity);
    return identity;
  }
}

final connectionStateProvider = StreamProvider<AppState>((ref) {
  // Follow the selected remote connection's own socket (was the single
  // `_shared` relay). Guard on the target TYPE, not the id string: a selected
  // LOCAL project has no relay socket, and `connectionFor(localId)` would
  // materialize a stray RelayService — so emit nothing for local targets.
  final target = ref.watch(selectedTargetProvider);
  if (target == null || target.isLocal) {
    return const Stream<AppState>.empty();
  }
  final relay = ref
      .read(relayConnectionManagerProvider)
      .connectionFor(baseDeviceUuid(target.registrationId))
      .relay;
  // Prepend the current state so the UI has a value immediately.
  return seededStream(() => relay.currentState, relay.stateStream);
});

/// Whether the active agent is reachable through the relay.
///
/// - `connecting` — WebSocket / auth handshake / pair-request still in flight.
/// - `online` — paired with the agent over the relay.
/// - `offline` — authenticated to the relay but the agent isn't available
///   (the most common case is `PAIR_TIMEOUT` from the relay because no agent
///   with that deviceId is currently registered).
enum AgentReachability { connecting, online, offline }

final agentReachabilityProvider = Provider<AgentReachability>((ref) {
  final asyncState = ref.watch(connectionStateProvider);
  final state = asyncState.value;
  if (state == null) return AgentReachability.connecting;
  switch (state.connectionState) {
    case RelayConnectionState.paired:
      return AgentReachability.online;
    case RelayConnectionState.authenticated:
      // PAIR_TIMEOUT = the agent never showed up. Other authenticated-with-
      // no-error states are still "connecting" (pair-request hasn't fired
      // or is in flight).
      if (state.errorCode == 'PAIR_TIMEOUT') return AgentReachability.offline;
      return AgentReachability.connecting;
    case RelayConnectionState.disconnected:
    case RelayConnectionState.connecting:
    case RelayConnectionState.authenticating:
    case RelayConnectionState.pairing:
      return AgentReachability.connecting;
  }
});

/// True iff the currently focused id corresponds to a relay-paired remote
/// agent (as opposed to a locally-opened folder).
final focusedIsRelayProvider = Provider<bool>((ref) {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) return false;
  final agents = ref.watch(pairedAgentProvider).value ?? const [];
  return agents.any((a) => a.agentDeviceId == id);
});

/// Callback to switch to agent panel. Set by WorkspaceShell.
final switchToAgentProvider =
    NotifierProvider<ValueController<VoidCallback?>, VoidCallback?>(
      () => ValueController(null),
    );

final pairedAgentProvider =
    AsyncNotifierProvider<PairedAgentNotifier, List<PairedAgent>>(
      PairedAgentNotifier.new,
    );

/// The currently active agent from the paired list, if any.
final activeAgentProvider = Provider<PairedAgent?>((ref) {
  final activeId = ref.watch(selectedRegistrationIdProvider);
  if (activeId == null) return null;
  final agents = ref.watch(pairedAgentProvider).value ?? const [];
  try {
    return agents.firstWhere((a) => a.agentDeviceId == activeId);
  } on StateError {
    return null;
  }
});

class PairedAgentNotifier extends AsyncNotifier<List<PairedAgent>> {
  // Connect + v2 handshake (and their retry/repair machinery) are owned by
  // RelayConnection now; this notifier only owns the paired-agent list and the
  // focus target. Reading the transport provider for an id is what opens its
  // dedicated socket and runs the handshake.

  @override
  Future<List<PairedAgent>> build() async {
    final storage = ref.read(storageServiceProvider);
    return storage.loadPairedAgents();
  }

  Future<List<PairedAgent>> _pairedAgentsSnapshot() async {
    final loaded = state.value;
    if (loaded != null) return List<PairedAgent>.from(loaded);
    try {
      return List<PairedAgent>.from(await future);
    } catch (_) {
      return ref.read(storageServiceProvider).loadPairedAgents();
    }
  }

  Future<void> pair(QrPayload qr) async {
    final user = await ref.read(currentUserProvider.future);
    if (requiresProForMobile(user?.tier)) {
      throw PairException(
        'Pro subscription required — upgrade to connect mobile',
      );
    }
    final agents = await _pairedAgentsSnapshot();

    try {
      final identity = await _identityForRelay();
      final pairing = ref.read(pairingServiceForProvider(qr.agentDeviceId));
      // QR-driven first-pair flow → grant. The E2E session (keys) is established
      // lazily by the machine's MachineSession once its transport is read.
      final ra = await pairing.pairWithAgent(qr, identity);
      final agent = PairedAgent(
        relayUrl: ra.relayUrl,
        agentDeviceId: ra.agentDeviceId,
        agentName: ra.agentLabel,
      );

      // Replace if already exists (re-pair), otherwise append
      final idx = agents.indexWhere(
        (a) => a.agentDeviceId == agent.agentDeviceId,
      );
      if (idx >= 0) {
        agents[idx] = agent;
      } else {
        agents.add(agent);
      }

      // Persist
      final storage = ref.read(storageServiceProvider);
      await storage.savePairedAgents(agents);

      // Focus the new agent; reading its transport provider (driven by the
      // workspace boot path) opens the dedicated socket and runs the handshake.
      ref
          .read(selectedTargetProvider.notifier)
          .set(RemoteTarget.legacy(agent.agentDeviceId));

      state = AsyncData(agents);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> selectAgent(String agentDeviceId) async {
    final agents = state.value ?? [];
    final agent = agents
        .where((a) => a.agentDeviceId == agentDeviceId)
        .firstOrNull;
    if (agent == null) return;

    // Focus the agent. Each id owns a dedicated socket, so connect + handshake
    // happen when the transport provider for this id is read (workspace boot);
    // there is no shared relay to disconnect on switch.
    ref
        .read(selectedTargetProvider.notifier)
        .set(RemoteTarget.legacy(agentDeviceId));
  }

  Future<void> forgetMachine(String agentDeviceIdOrUuid) async {
    final machineUuid = baseDeviceUuid(agentDeviceIdOrUuid);
    final activeId = ref.read(selectedRegistrationIdProvider);
    if (activeId != null && baseDeviceUuid(activeId) == machineUuid) {
      ref.read(selectedTargetProvider.notifier).set(null);
    }

    final agents = await _pairedAgentsSnapshot();
    final recentStore = ref.read(recentAgentsStoreProvider);
    final recentAgents = recentStore.list();
    final forgottenIds = <String>{
      for (final a in agents)
        if (baseDeviceUuid(a.agentDeviceId) == machineUuid) a.agentDeviceId,
      for (final r in recentAgents)
        if (baseDeviceUuid(r.agentDeviceId) == machineUuid) r.agentDeviceId,
    };

    final mgr = ref.read(relayConnectionManagerProvider);
    final registry = ref.read(projectSessionRegistryProvider.notifier);
    for (final id in forgottenIds) {
      mgr.peek(id)?.unpair();
      mgr.release(id);
      // `AndSettle` (awaited) before purge: eviction's `onEvict` writes the
      // status cache that `purgeEntryState` then deletes — ordering matters.
      await registry.forceEvictAndSettle(id);
      // Clear the forgotten agent's per-entry footprint (cached session list,
      // recent ports, status cache). Without this the old session list
      // resurrects when the machine is re-paired under the same id.
      await purgeEntryState(ref, id);
    }

    final remainingAgents = agents
        .where((a) => baseDeviceUuid(a.agentDeviceId) != machineUuid)
        .toList(growable: false);
    await ref.read(storageServiceProvider).savePairedAgents(remainingAgents);

    for (final r in recentAgents) {
      if (baseDeviceUuid(r.agentDeviceId) == machineUuid) {
        await recentStore.remove(r.agentDeviceId);
      }
    }

    await ref.read(phoneIdentityProvider).deleteKeypair(machineUuid);
    state = AsyncData(remainingAgents);
  }

  /// Re-arms the agent's connection after an app resume. Reading its transport
  /// provider opens + handshakes the dedicated socket (a no-op if it is already
  /// live, since `RelayConnection.open` is idempotent).
  Future<void> ensureListenersRunning(PairedAgent agent) async {
    await ref.read(agentTransportForProvider(agent.agentDeviceId).future);
  }

  /// User-initiated escape from the workspace boot screen — clears the
  /// active registration id (so `app_shell` routes back to the project list)
  /// and tears down the in-flight relay
  /// connection so we don't keep retrying in the background.
  void cancelActiveAgent() {
    final activeId = ref.read(selectedRegistrationIdProvider);
    ref.read(selectedTargetProvider.notifier).set(null);
    // Drop the machine socket + warm session for the cancelled agent so
    // re-selecting this id from the home screen rebuilds a fresh connection
    // rather than reusing the half-closed one. The connection is machine-level
    // (bare uuid) — reduce the compound focus id to its base.
    if (activeId != null) {
      final mgr = ref.read(relayConnectionManagerProvider);
      final machineUuid = baseDeviceUuid(activeId);
      mgr.peek(machineUuid)?.unpair();
      mgr.release(machineUuid);
      ref.read(projectSessionRegistryProvider.notifier).forceEvict(activeId);
    }
  }

  /// User-initiated retry from the "Agent offline" panel.
  ///
  /// Loads the `RecentAgent` for the active agent and runs the reconnect
  /// flow (fresh nonce, signed pair-approval verification) over the agent's
  /// dedicated socket. Idempotent when the session is already healthy.
  Future<void> retryAgentConnection() async {
    final agent = ref.read(activeAgentProvider);
    if (agent == null) return;
    final ra = _findRecentAgent(agent.agentDeviceId);
    if (ra == null) return;
    debugPrint('[relay] retry → reconnect(target=${agent.agentDeviceId})');
    final identity = await _identityForRelay();
    final pairing = ref.read(pairingServiceForProvider(agent.agentDeviceId));
    await pairing.reconnect(ra, identity);
  }

  RecentAgent? _findRecentAgent(String agentDeviceId) {
    final store = ref.read(recentAgentsStoreProvider);
    for (final r in store.list()) {
      if (r.agentDeviceId == agentDeviceId) return r;
    }
    return null;
  }

  /// The phone now identifies to the relay using its locally-generated random
  /// device id; the agent's signed pair-approval is what authorizes the
  /// session, so we no longer need to overlay an api-issued device id.
  Future<DeviceIdentity> _identityForRelay() {
    return ref.read(deviceIdentityProvider.future);
  }
}
