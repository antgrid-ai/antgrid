import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../demo/demo_identity.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../launcher/host_control_client.dart';
import '../util/ab_log.dart';
import '../util/external_open_target.dart';
import '../utils/platform_utils.dart';
import 'device_provisioning.dart';
import 'projects.dart';
import 'remote_access.dart';

/// Which external apps this machine can open a checkout in.
///
/// Probed once per run rather than per menu open: installing an editor
/// mid-session is rare enough that a stale list costs less than a registry /
/// `NSWorkspace` / GIO hit every time the kebab is clicked.
final externalOpenTargetsProvider = FutureProvider<List<ExternalOpenTarget>>((
  ref,
) async {
  if (isMobilePlatform) return const [];
  return detectExternalOpenTargets();
});

/// True iff [entryId] names a project whose checkout lives on THIS device —
/// the only case the loopback control plane can answer about.
///
/// An ALLOWLIST, not a remote-blocklist: an id this device holds no local
/// project for is a remote machine's (`<machineUuid>.<projectId>`), a machine
/// itself, or something that has been removed, and every one of those must lose
/// the working-directory affordances. Asking the local store the same way
/// `projectDisplayNameProvider` does — rather than asking whether some machine
/// list happens to mention the id — is what keeps a compound remote id from
/// reading as local: it can never equal a bare local `projectId`.
///
/// The demo owns no checkout at all, and answering for it would spawn the
/// bridge host from inside a sample project that promises nothing is connected.
final entryIsLocalCheckoutProvider = FutureProvider.family<bool, String>((
  ref,
  entryId,
) async {
  if (isDemoEntryId(entryId)) return false;
  final projects = ref.watch(projectsProvider);
  final String? localUuid;
  try {
    localUuid = await ref.watch(localDeviceUuidProvider.future);
  } catch (_) {
    return false;
  }
  // Null on mobile/web, and until the desktop uuid is minted. Local-vs-remote
  // is undecidable then, and the safe answer is the one that offers nothing.
  if (localUuid == null) return false;
  for (final project in projects) {
    if (project.projectId == entryId) return project.isLocalFor(localUuid);
  }
  return false;
});

/// Open a session's working directory in [target].
///
/// LOCAL projects only. The path is resolved over the loopback control plane —
/// a remote machine's checkout path is neither knowable here nor useful (the
/// window would open on a machine the user is not sitting at), so callers must
/// not offer this for a relay-backed project.
Future<void> openCheckoutIn(
  BuildContext context,
  ProviderContainer container, {
  required String projectId,
  required String checkoutId,
  required ExternalOpenTarget target,
}) async {
  final path = await _resolveCheckoutPath(
    context,
    container,
    projectId: projectId,
    checkoutId: checkoutId,
  );
  if (path == null) return;
  bool opened;
  try {
    opened = await launchUrl(
      target.uriFor(path),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    showAbSnackBar(context, 'Could not open ${target.appName}.');
  }
}

/// Copy a session's working directory to the clipboard. Local projects only,
/// for the same reason as [openCheckoutIn].
Future<void> copyCheckoutPath(
  BuildContext context,
  ProviderContainer container, {
  required String projectId,
  required String checkoutId,
}) async {
  final path = await _resolveCheckoutPath(
    context,
    container,
    projectId: projectId,
    checkoutId: checkoutId,
  );
  if (path == null) return;
  // A clipboard the platform refuses to write (a Linux session with no
  // clipboard owner) would otherwise throw past every caller into a debugPrint,
  // leaving the user with no snackbar at all and a stale clipboard they believe
  // they just replaced.
  try {
    await Clipboard.setData(ClipboardData(text: path));
  } catch (_) {
    if (context.mounted) showAbSnackBar(context, 'Could not copy the path.');
    return;
  }
  if (context.mounted) showAbSnackBar(context, 'Path copied');
}

/// Ask the host where this checkout lives. Returns null after reporting the
/// failure, so callers can treat null as "already handled".
Future<String?> _resolveCheckoutPath(
  BuildContext context,
  ProviderContainer container, {
  required String projectId,
  required String checkoutId,
}) async {
  // The local-only contract above, enforced rather than documented: the read
  // below goes to the LOOPBACK host, so a remote project asks THIS machine
  // about a checkout it has never seen — and the ask spawns a host to answer
  // it. The menus that offer these rows gate on the same provider; a menu that
  // stops gating (or a new caller) must not be able to reach the host.
  bool local;
  try {
    local = await container.read(
      entryIsLocalCheckoutProvider(projectId).future,
    );
  } catch (_) {
    local = false;
  }
  if (!local) {
    AbLog.warn(
      'open_checkout',
      'refused: not a local checkout',
      fields: {'projectId': projectId},
    );
    return null;
  }
  try {
    final client = await container.read(hostControlClientProvider.future);
    return await client.checkoutPath(
      projectId: projectId,
      checkoutId: checkoutId,
    );
  } on HostControlException catch (error) {
    if (context.mounted) showAbSnackBar(context, _messageFor(error));
    return null;
  } catch (_) {
    if (context.mounted) {
      showAbSnackBar(context, 'Could not reach the local host.');
    }
    return null;
  }
}

/// User-facing text for a refusal from the host.
///
/// The codes are matched exhaustively rather than falling through to
/// `error.message`, because `HostControlClient._post` reports a dead socket or
/// a timeout as a `HostControlException` too — a default of `error.message`
/// puts `control POST failed: TimeoutException after 0:00:05.000000` in a
/// snackbar and leaves the plain-language wording below unreachable.
String _messageFor(HostControlException error) => switch (error.code) {
  // The one failure a user can act on: the worktree was removed, or the drive
  // holding it is gone.
  'CHECKOUT_MISSING' => 'This session\'s working directory no longer exists.',
  // The host has no path on record. Reached by asking about a project it never
  // opened — which for a local project means its catalog entry was dropped.
  'UNKNOWN_PROJECT' ||
  'UNKNOWN_CHECKOUT' ||
  'INVALID_PROJECT' => 'Antgrid could not locate this session\'s folder.',
  _ => 'Could not reach the local host.',
};
