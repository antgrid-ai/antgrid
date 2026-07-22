import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../design/widgets/ab_button.dart';
import '../launcher/project_id.dart';
import '../models/ab_project.dart';
import '../providers/agent_transport.dart';
import '../providers/device_provisioning.dart';
import '../providers/projects.dart';

bool _isDesktopPlatform() =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Returns this device's stable host UUID for use in [AbProject.hostDeviceUuid].
///
/// Priority:
/// 1. The signed-in `DeviceRecord.deviceUuid` from the keychain (most precise —
///    ties the project to the provisioned relay identity).
/// 2. A persisted anonymous UUID in SharedPreferences (key `antgrid.local_host_uuid`),
///    lazily generated with UUIDv4 the first time. This covers local-only
///    (no sign-in) users and ensures `isLocalFor` keeps working across restarts.
Future<String> _resolveLocalHostUuid(WidgetRef ref) async {
  final record = await ref.read(keychainDeviceStoreProvider).read();
  if (record != null) return record.deviceUuid;

  // Fall back to a persisted anonymous UUID so the project is still
  // correctly identified as local even when the user isn't signed in.
  final prefs = SharedPreferencesAsync();
  final existing = await prefs.getString(kLocalHostUuidKey);
  if (existing != null) return existing;
  final fresh = const Uuid().v4();
  await prefs.setString(kLocalHostUuidKey, fresh);
  // Invalidate the cached provider so anything watching localDeviceUuidProvider
  // picks up the freshly-minted UUID immediately instead of staying on the
  // now-stale null until the next app restart.
  ref.invalidate(localDeviceUuidProvider);
  return fresh;
}

/// Shared entry point: prompt for a directory and upsert a project for it.
/// Used by [OpenFolderButton] (visible button) and the New Session composer.
/// Desktop-only — bails out silently on mobile/web.
///
/// Returns the upserted project's id, or `null` when the picker was cancelled
/// (or on mobile/web). Callers that need to act on the result — e.g. set it as
/// a session target — read this instead of re-deriving the pick from provider
/// side effects.
///
/// [select] controls whether the project is also focused ([selectProject]).
/// Pass false when picking a folder as a form input (the composer's project
/// chip): focusing it from the New Session landing flips AppShell's route to
/// WorkspaceShell mid-flow, unmounting the caller before it can act.
Future<String?> openFolderPicker(WidgetRef ref, {bool select = true}) async {
  if (!_isDesktopPlatform()) return null;
  final folder = await getDirectoryPath();
  if (folder == null) return null;
  return registerPickedFolder(ref, folder, select: select);
}

/// Upserts a project for an already-picked [folder] (bumping `lastOpenedAt`
/// for a known one) and returns its id. Focuses the project only when
/// [select] is true — see [openFolderPicker] for why callers opt out.
Future<String?> registerPickedFolder(
  WidgetRef ref,
  String folder, {
  bool select = true,
}) async {
  final id = await computeProjectId(folder);
  final projects = ref.read(projectsProvider);
  final existingMatches = projects.where((p) => p.projectId == id).toList();
  if (existingMatches.isNotEmpty) {
    existingMatches.first.lastOpenedAt = DateTime.now();
    await ref.read(projectsProvider.notifier).upsert(existingMatches.first);
    if (select) selectProject(ref, id);
    return id;
  }
  final hostUuid = await _resolveLocalHostUuid(ref);
  final project = AbProject(
    projectId: id,
    folder: folder,
    displayName: _basename(folder),
    hostDeviceUuid: hostUuid,
    hostMachineName: '',
    lastOpenedAt: DateTime.now(),
  );
  await ref.read(projectsProvider.notifier).upsert(project);
  if (select) selectProject(ref, id);
  return id;
}

/// Desktop-only "Open Folder" button. Thin wrapper over [openFolderPicker].
class OpenFolderButton extends ConsumerWidget {
  const OpenFolderButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_isDesktopPlatform()) return const SizedBox.shrink();
    return AbButton(label: 'Open Folder', onTap: () => openFolderPicker(ref));
  }
}

/// Last non-empty path segment. Avoids pulling in `package:path` for one call.
String _basename(String folder) {
  final parts = folder
      .split(Platform.pathSeparator)
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? folder : parts.last;
}
