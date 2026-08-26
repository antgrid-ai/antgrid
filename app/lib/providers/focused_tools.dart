import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../util/device_id.dart';
import 'agent_catalog.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'new_session_picker.dart';

/// The `agent:tools` advert for the machine hosting the FOCUSED project.
///
/// The New Session providers next door answer the same questions for whatever
/// target the PICKER points at; an already-open session needs the machine it is
/// actually running on, which is a different machine as soon as the picker is
/// touched.
///
/// The registry-wide `agents[]` half of the same advert is deliberately NOT
/// here: it is machine-independent, so it belongs in the merged
/// [agentCatalogProvider] rather than in a per-focus snapshot. The app-shell
/// reaper is the single writer that feeds it.
class FocusedTools {
  const FocusedTools({this.labels = const {}, this.chatCapable});

  /// Registry key -> advertised display label. Empty before the advert lands,
  /// and against a bridge predating the field.
  final Map<String, String?> labels;

  /// Chat-capable registry keys, or null when no entry carried `chatCapable`.
  /// Null and "advertised, capable of nothing" must stay distinguishable so
  /// callers fall back to the persisted catalog instead of disabling Chat for
  /// every agent on an older bridge.
  final Set<String>? chatCapable;
}

/// Mirrors the local-vs-remote sourcing of [newSessionDetectedToolsProvider]:
/// the loopback host's `tools:list` for a local project, the machine's
/// control-plane advert for a remote one. Any failure resolves to an empty
/// advert, which reads as "no wire signal" rather than "nothing is capable".
final focusedMachineToolsProvider = FutureProvider<FocusedTools>((ref) async {
  final target = ref.watch(selectedTargetProvider);
  if (target == null) return const FocusedTools();

  // The EARLIEST host spawn in the app: `enterDemoMode` points
  // [selectedTargetProvider] at the sample project, which is a `LocalProject`,
  // and the session mark and mode control watch this from the workspace the
  // demo opens on — so the real bridge started before the user had touched
  // anything. Empty is the value this provider already resolves to when the
  // host cannot answer, and both consumers fall back to
  // `sessionAgentDisplayLabel` for it, so the demo reads the same as it did.
  if (ref.watch(demoModeProvider)) return const FocusedTools();

  if (target.isLocal) {
    try {
      final host = await ref.watch(hostControllerProvider).ensureHost();
      final client = HostControlClient(
        port: host.controlPort,
        token: host.token,
      );
      try {
        final listed = await client.toolsList();
        return FocusedTools(
          labels: {for (final t in listed.tools) t.tool: t.label},
          chatCapable: chatCapableSetOrNull(
            listed.tools.map((t) => (t.tool, t.chatCapable)),
          ),
        );
      } finally {
        client.close();
      }
    } catch (_) {
      return const FocusedTools();
    }
  }

  final state = ref
      .watch(controlPlaneStateProvider(baseDeviceUuid(target.registrationId)))
      .value;
  if (state == null) return const FocusedTools();
  return FocusedTools(
    labels: {for (final t in state.tools) t.tool: t.label},
    chatCapable: chatCapableSetOrNull(
      state.tools.map((t) => (t.tool, t.chatCapable)),
    ),
  );
});

/// Whether [tool] can run as a chat session on the focused project's machine,
/// or null when neither that machine nor the persisted catalog has said — the
/// same three-state resolution the create-time picker uses, so one agent cannot
/// read as chat-capable in one place and not the other.
///
/// A toolless session (a custom launch command) is `false`, not unknown: there
/// is no registry entry to carry a driver.
///
/// Derived as a plain value rather than read off [focusedMachineToolsProvider]
/// directly because that future re-emits a fresh [FocusedTools] on every
/// control-plane push; watchers of this only rebuild when the answer flips.
final focusedToolChatCapableProvider = Provider.family<bool?, String?>((
  ref,
  tool,
) {
  if (tool == null || tool.isEmpty) return false;
  final wire = ref.watch(focusedMachineToolsProvider).value?.chatCapable;
  return agentSupportsChatResolved(
    KnownAgent(tool),
    wireChatCapable: wire,
    descriptor: ref.watch(agentCatalogProvider)[tool],
  );
});
