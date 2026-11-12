import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show remoteCommandOutcomeUnknownMessage;

import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_toast.dart';
import '../services/sessions_service.dart';
import 'ab_status_helpers.dart' show sessionRefusalCopy;
import 'carbon_confirm.dart';

/// Performs one delete attempt. Raises [SessionOperationException] for a typed
/// refusal — that refusal is the confirm ladder's input, not a failure to
/// report.
typedef SessionDeleter =
    Future<SessionDeleteAck> Function({bool? force, bool? deleteBranch});

/// [outcomeUnknown] means dispatch happened without an application result. The
/// app neither claims failure nor repeats the mutation; it reports uncertainty
/// and waits for a fresh user action.
enum SessionDeleteResult { deleted, cancelled, failed, outcomeUnknown }

/// The confirmation dialogs the delete ladder asks, so a surface chooses its
/// own design system without forking the ladder's copy or branching.
abstract class SessionDeleteDialogs {
  const SessionDeleteDialogs();

  /// A yes/no question whose yes is "Delete".
  Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String body,
  });

  /// A destructive question with an optional unchecked checkbox. The option is
  /// false whenever the user cancelled or none was offered.
  Future<({bool confirmed, bool optionSelected})> confirmWithOption(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    String? optionLabel,
  });
}

class _AbSessionDeleteDialogs extends SessionDeleteDialogs {
  const _AbSessionDeleteDialogs();

  @override
  Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String body,
  }) => AbConfirmDialog.show(
    context: context,
    title: title,
    body: body,
    confirmLabel: 'Delete',
    destructive: true,
  );

  @override
  Future<({bool confirmed, bool optionSelected})> confirmWithOption(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    String? optionLabel,
  }) => AbConfirmDialog.showWithOption(
    context: context,
    title: title,
    body: body,
    confirmLabel: confirmLabel,
    destructive: true,
    optionLabel: optionLabel,
  );
}

class _CarbonSessionDeleteDialogs extends SessionDeleteDialogs {
  const _CarbonSessionDeleteDialogs();

  @override
  Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String body,
  }) => showCarbonConfirm(
    context,
    title: title,
    body: body,
    confirmLabel: 'Delete',
    danger: true,
  );

  @override
  Future<({bool confirmed, bool optionSelected})> confirmWithOption(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    String? optionLabel,
  }) async {
    // Outside the builder: the modal route rebuilds it on any size, inset or
    // theme change, and a choice held inside would silently reset.
    var optionSelected = false;
    final result = await showCarbonModal<({bool confirmed, bool optionSelected})>(
      context,
      builder: (modalContext) {
        // The whole modal rebuilds with the checkbox: its actions sit outside
        // the body, and the primary one has to pop the current choice.
        return StatefulBuilder(
          builder: (context, setState) {
            final t = CarbonTheme.of(context);
            void answer(bool confirmed) => Navigator.of(modalContext).pop((
              confirmed: confirmed,
              optionSelected: confirmed && optionSelected,
            ));
            return CarbonModal.confirmation(
              title: title,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    body,
                    style: t.typography.body.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                  if (optionLabel != null) ...[
                    const SizedBox(height: CarbonSpacing.spacing05),
                    CarbonCheckbox(
                      labelText: optionLabel,
                      value: optionSelected,
                      onChanged: (v) =>
                          setState(() => optionSelected = v ?? false),
                    ),
                  ],
                ],
              ),
              danger: true,
              secondary: CarbonModalAction(
                label: 'Cancel',
                onPressed: () => answer(false),
              ),
              primary: CarbonModalAction(
                label: confirmLabel,
                onPressed: () => answer(true),
              ),
            );
          },
        );
      },
    );
    return result ?? (confirmed: false, optionSelected: false);
  }
}

const SessionDeleteDialogs abSessionDeleteDialogs = _AbSessionDeleteDialogs();
const SessionDeleteDialogs carbonSessionDeleteDialogs =
    _CarbonSessionDeleteDialogs();

/// The delete confirmation ladder, shared by every surface that deletes a
/// session (the drawer kebab, the Recent list) so the same session can never be
/// described two ways depending on where it was deleted from.
///
/// Keyed on [checkoutKind] rather than an isolated/shared boolean: the bridge
/// routes destructive deletion on `checkoutKind === "managed-worktree"` and
/// falls every other kind through to the shared path, so the copy has to be
/// able to say three things — and a boolean could not be widened without
/// changing every call site.
///
/// [sharedBody] is the surface's own wording for a delete that removes nothing
/// but the session, since a live agent row and a cached Recent row are honest
/// about different consequences. It states consequences only: the ladder ends
/// every arm on the same irreversibility sentence so no surface can forget it.
///
/// [onInFlight] is called `true` immediately before each attempt and `false`
/// when that attempt settles. An outcome-unknown request must require a fresh
/// user action rather than remaining armed as though execution were confirmed.
///
/// [dialogs] picks the design system the questions are asked in; the ladder's
/// copy and branching are the same for every surface.
///
/// [context] governs the DIALOGS and TOASTS only, never the outcome. Once the
/// user has confirmed, the delete runs and its result is reported whether or not
/// the calling row survived the await — a row rebuilt away mid-dialog is the
/// normal case on the Recent list, and it must not silently swallow either the
/// request or its answer.
Future<SessionDeleteResult> confirmAndDeleteSession({
  required BuildContext context,
  required String sessionName,
  required String checkoutKind,
  required String sharedBody,
  required SessionDeleter delete,
  bool sharedWorkspace = false,
  void Function(bool inFlight)? onInFlight,
  SessionDeleteDialogs dialogs = abSessionDeleteDialogs,
}) async {
  final (String title, String consequence) = switch (checkoutKind) {
    'main' => ('Delete session?', sharedBody),
    // A member of a shared workspace is detached, not reclaimed: the bridge
    // keeps the directory and the branch for the sessions still in it, so the
    // arm below would promise a removal that cannot happen.
    'managed-worktree' when sharedWorkspace => (
      'Delete isolated session?',
      '$sharedBody Its working directory is shared with other sessions and is '
          'kept.',
    ),
    // Adds only what a managed checkout costs on top of the surface's wording —
    // whether a process dies is the surface's to claim, not this arm's.
    'managed-worktree' => (
      'Delete isolated session?',
      '$sharedBody It also removes its isolated working directory. Its branch is '
          'kept.',
    ),
    // A kind this build doesn't know: the session IS isolated, so the title must
    // say so, but nothing here can name what deleting it leaves behind — the
    // bridge only removes a checkout for the kinds it recognises. The shared
    // body names no mechanism, so it can neither over- nor under-promise.
    _ => ('Delete isolated session?', sharedBody),
  };

  final confirmed = await dialogs.confirm(
    context,
    title: title,
    body: '$consequence This cannot be undone.',
  );
  if (!confirmed) return SessionDeleteResult.cancelled;

  // Always attempted non-destructively first: the bridge checks both
  // uncommitted and unpushed work before removing anything.
  final String blockedBy;
  try {
    onInFlight?.call(true);
    final ack = await delete();
    onInFlight?.call(false);
    final result = _resultFor(ack);
    if (result == SessionDeleteResult.outcomeUnknown && context.mounted) {
      showAbToast(context, remoteCommandOutcomeUnknownMessage);
    }
    return result;
  } on SessionOperationException catch (error) {
    onInFlight?.call(false);
    final code = error.errorCode;
    if (code != 'WORKTREE_DIRTY' && code != 'WORKTREE_UNPUSHED') {
      if (context.mounted) _report(context, code, error.message);
      return SessionDeleteResult.failed;
    }
    blockedBy = code!;
  } catch (_) {
    // A disposed service or a dead transport. A lapsed reply does not land
    // here — it comes back as an ack. Neither a refusal to ask about nor
    // something to leave as an unhandled async error: this is the one place
    // delete errors land, so the generic message belongs here rather than being
    // re-solved per call site.
    onInFlight?.call(false);
    if (context.mounted) _report(context, null, null);
    return SessionDeleteResult.failed;
  }

  // The second question cannot be asked without a live context, and nothing was
  // deleted — the first attempt was refused.
  if (!context.mounted) return SessionDeleteResult.failed;

  final unpushed = blockedBy == 'WORKTREE_UNPUSHED';
  // Branch deletion is offered only for unpushed commits, because that is the
  // only case where keeping the branch actually preserves something. It is
  // always a separate, unchecked choice — never folded into "force".
  final choice = await dialogs.confirmWithOption(
    context,
    // Says "isolated session", not "worktree": the badge, the composer chip and
    // the error copy all refuse to name the mechanism, and the unknown-kind arm
    // above routes non-worktree kinds through this same dialog.
    title: unpushed
        ? 'Delete isolated session with unpushed commits?'
        : 'Delete isolated session with uncommitted changes?',
    body: unpushed
        ? 'This isolated session\'s branch has commits that exist nowhere else. Deleting removes its working directory; the branch is kept unless you also delete it.'
        : 'This isolated session has uncommitted changes in its working directory. Force deletion discards them. Its branch is preserved.',
    confirmLabel: 'Force delete',
    optionLabel: unpushed ? 'Also delete the branch and its commits' : null,
  );
  if (!choice.confirmed) return SessionDeleteResult.cancelled;

  // Exactly one retry.
  try {
    onInFlight?.call(true);
    final ack = await delete(force: true, deleteBranch: choice.optionSelected);
    onInFlight?.call(false);
    final result = _resultFor(ack);
    if (result == SessionDeleteResult.outcomeUnknown && context.mounted) {
      showAbToast(context, remoteCommandOutcomeUnknownMessage);
    }
    return result;
  } on SessionOperationException catch (error) {
    onInFlight?.call(false);
    if (context.mounted) _report(context, error.errorCode, error.message);
    return SessionDeleteResult.failed;
  } catch (_) {
    onInFlight?.call(false);
    if (context.mounted) _report(context, null, null);
    return SessionDeleteResult.failed;
  }
}

SessionDeleteResult _resultFor(SessionDeleteAck ack) => switch (ack) {
  SessionDeleteAck.deleted => SessionDeleteResult.deleted,
  SessionDeleteAck.outcomeUnknown => SessionDeleteResult.outcomeUnknown,
};

/// Guarded by a literal `context.mounted` at every call site rather than once in
/// here: the analyzer recognises only the literal form, and folding the check
/// into this helper turns a checked lint into an unchecked convention.
void _report(BuildContext context, String? code, String? message) {
  showAbToast(
    context,
    sessionRefusalCopy(code, message, 'Could not delete the session'),
  );
}
