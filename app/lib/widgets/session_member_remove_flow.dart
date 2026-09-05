import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_confirm_dialog.dart';
import '../models/session_entry.dart';
import '../providers/device_provisioning.dart';
import '../providers/open_target_session.dart';
import '../providers/providers.dart';
import '../providers/session_members.dart';
import '../services/sessions_service.dart';
import 'ab_status_helpers.dart' show sessionRefusalCopy;

/// Takes [peer]'s machine out of the session it joined (§5.4): the session it
/// runs is deleted on its own machine, and the lead's row records the release.
///
/// **Order is the correctness property.** The peer is deleted FIRST and the
/// lead released second. Releasing first drops the membership the carrier
/// derives its pin from, so the peer's connection is torn down while the delete
/// that needs it is still in flight — which surfaces as a peer that
/// mysteriously times out, not as a bug in this order.
///
/// A delete that is refused or unreachable still offers to release, on purpose:
/// the lead has to be able to stop treating a machine as a member even when
/// that machine is off, and `deleteRefused` is what makes the release say the
/// peer's session outlived the membership rather than pretend it is gone.
///
/// One confirmation, never the shared delete ladder: a peer session is always
/// `isolation: "shared"` (D10), so the ladder's branch and worktree questions
/// have no answer here, and a second dialog would only ask about the same
/// consequence this one already states.
///
/// Takes the [ProviderContainer], never a `WidgetRef`: the menu row that starts
/// this pops itself before calling, so the ref it was built with is already
/// dead by the first dialog.
Future<void> confirmAndRemoveMember(
  BuildContext context,
  ProviderContainer container, {
  required String leadRegistrationId,
  required String leadSessionId,
  required SessionMemberRef peer,
}) async {
  final machineName = container.read(memberMachineLabelProvider(peer));
  final projectName = peer.projectLabel ?? peer.projectId;

  final confirmed = await AbConfirmDialog.show(
    context: context,
    title: 'Remove $machineName?',
    body:
        'The session it is running in $projectName is deleted and it stops '
        'working on this one. This session keeps everything already done. '
        'This cannot be undone.',
    confirmLabel: 'Remove',
    destructive: true,
  );
  if (!confirmed) return;

  // A member ref names a machine and a project; the id every focus and service
  // lookup is keyed by is whichever of the two forms this device resolves it to.
  final peerRegistrationId = memberRegistrationId(
    peer,
    localMachineId: await container.read(localDeviceUuidProvider.future),
  );
  final peerService = await warmServiceFor(
    container,
    peerRegistrationId,
    (s) => s.sessionsService,
    timeout: const Duration(seconds: 20),
  );

  String? deleteProblem;
  if (peerService == null) {
    deleteProblem = 'Could not reach $machineName.';
  } else {
    try {
      // `force` because the question it guards was already asked above, and a
      // shared checkout has nothing else to preflight.
      await peerService.delete(peer.sessionId, force: true);
    } on SessionOperationException catch (error) {
      deleteProblem = sessionRefusalCopy(
        error.errorCode,
        error.message,
        'Its session could not be deleted.',
      );
    } catch (error) {
      deleteProblem = '$error';
    }
  }

  if (deleteProblem != null) {
    if (!context.mounted) return;
    final releaseAnyway = await AbConfirmDialog.show(
      context: context,
      title: 'Remove $machineName anyway?',
      body:
          '$deleteProblem Removing it here stops this session from working '
          'with it; the session on $machineName stays until you delete it '
          'there.',
      confirmLabel: 'Remove anyway',
      destructive: true,
    );
    if (!releaseAnyway) return;
  }

  // Everything is caught, and the release is offered again until it lands or
  // the user leaves it. The delete above has already taken the peer's session
  // away, so a lead that keeps the membership pins a project whose session no
  // longer exists and this flow is the only UI that can clear it — which makes
  // one failed attempt a dead end, not a setback. The catch-all is what covers
  // the likeliest failure of all here: `PendingReply` answers a lost reply with
  // a `TimeoutException`, and the machine at the far end of this flow is
  // frequently the one that is away.
  while (true) {
    // Re-warmed every pass: a release that timed out is evidence the project's
    // session may be re-resolving, and retrying against the instance that just
    // failed would only re-time-out on a binding that is already gone.
    final leadService = await warmServiceFor(
      container,
      leadRegistrationId,
      (s) => s.sessionsService,
    );
    String? problem;
    if (leadService == null) {
      problem = 'Could not reach this session.';
    } else {
      try {
        await leadService.memberRelease(
          sessionId: leadSessionId,
          member: peer,
          deleteRefused: deleteProblem != null,
          // The wire caps a reason at 200 chars and rejects the whole release
          // above it, so a long refusal message must lose its tail rather than
          // the release.
          reason: deleteProblem == null || deleteProblem.length <= 200
              ? deleteProblem
              : deleteProblem.substring(0, 200),
        );
      } on SessionOperationException catch (error) {
        problem = sessionRefusalCopy(
          error.errorCode,
          error.message,
          'Could not remove $machineName from this session.',
        );
      } catch (error) {
        problem = '$error';
      }
    }
    if (problem == null) break;
    if (!context.mounted) return;
    final retry = await AbConfirmDialog.show(
      context: context,
      title: 'Could not remove $machineName',
      body:
          '$problem\n\n'
          'This session still lists $machineName as a member until the '
          'removal goes through.',
      confirmLabel: 'Try again',
      cancelLabel: 'Leave it',
    );
    if (!retry) return;
  }

  // Back to the lead by address, not through [selectMemberTab]: the tab the
  // user was standing on has just been released, so there is no member ref left
  // to select.
  await openTargetAndFocusSession(
    container,
    registrationId: leadRegistrationId,
    sessionId: leadSessionId,
  );
}
