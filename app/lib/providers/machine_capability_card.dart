import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../services/control_plane_client.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'projects.dart';

/// One remote machine's Capability Card, covering every project it has seen.
///
/// Asked without a project filter on purpose: the add-machine dialog matches
/// the lead's repo against ALL of a machine's projects to pre-select one, so
/// naming a project here would beg the question the card is being read to
/// answer.
///
/// Null is the single degradation for every way this can come up empty — an
/// unreachable machine, or a bridge predating the verb, which answers
/// `UNKNOWN_VERB`. None of those is an error to put in front of the user: they
/// cost the card line and the pre-selection, and the user picks by hand.
final machineCapabilityCardProvider = FutureProvider.autoDispose
    .family<CapabilityCard?, String>((ref, machineUuid) async {
      try {
        final client = await ref.watch(
          controlPlaneClientForProvider(machineUuid).future,
        );
        if (client == null) return null;
        return await client.capabilityCard();
      } catch (_) {
        return null;
      }
    });

/// The bridge-NORMALISED `origin` of a LOCAL project, or null when it has none.
///
/// Read over the loopback control plane rather than derived in Dart, so the key
/// compared here and the key a remote machine reports come out of the SAME
/// normaliser — a second implementation of a credential-stripping routine is
/// both dead weight and a place for the two sides to disagree silently.
///
/// Guarded against demo mode for the reason `detectedToolsForProvider` is: the
/// local arm spawns the real bridge host, which a sample project must not do.
final localProjectRemoteProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, projectId) async {
      if (ref.watch(demoModeProvider)) return null;
      final projects = ref.watch(projectsProvider);
      String? folder;
      String? label;
      for (final p in projects) {
        if (p.projectId != projectId) continue;
        folder = p.folder;
        label = p.displayName;
        break;
      }
      if (folder == null) return null;
      try {
        final host = await ref.watch(hostControllerProvider).ensureHost();
        final client = HostControlClient(
          port: host.controlPort,
          token: host.token,
        );
        try {
          final card = await client.capabilityCard(
            projects: [
              (projectId: projectId, projectPath: folder, label: label),
            ],
          );
          return card.projects[projectId]?.remote;
        } finally {
          client.close();
        }
      } catch (_) {
        return null;
      }
    });
