import 'package:flutter/widgets.dart';

import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../services/sessions_service.dart';
import 'ab_status_helpers.dart' show sessionRefusalCopy;

/// Performs one delete attempt. Returns whether the session was deleted, and
/// raises [SessionOperationException] for a typed refusal — that refusal is the
/// confirm ladder's input, not a failure to report.
typedef SessionDeleter =
    Future<bool> Function({bool? force, bool? deleteBranch});

enum SessionDeleteResult { deleted, cancelled, failed }

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
}) async {
  final (String title, String consequence) = switch (checkoutKind) {
    'main' => ('Delete session?', sharedBody),
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

  final confirmed = await AbConfirmDialog.show(
    context: context,
    title: title,
    body: '$consequence This cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!confirmed) return SessionDeleteResult.cancelled;

  // Always attempted non-destructively first: the bridge checks both
  // uncommitted and unpushed work before removing anything.
  final String blockedBy;
  try {
    return await delete()
        ? SessionDeleteResult.deleted
        : SessionDeleteResult.failed;
  } on SessionOperationException catch (error) {
    final code = error.errorCode;
    if (code != 'WORKTREE_DIRTY' && code != 'WORKTREE_UNPUSHED') {
      if (context.mounted) _report(context, code, error.message);
      return SessionDeleteResult.failed;
    }
    blockedBy = code!;
  } catch (_) {
    // A transport timeout or a disposed service is neither a refusal to ask
    // about nor something to leave as an unhandled async error: this is the one
    // place every surface's delete errors land, so the generic message belongs
    // here rather than being re-solved per call site.
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
  final choice = await AbConfirmDialog.showWithOption(
    context: context,
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
    destructive: true,
    optionLabel: unpushed ? 'Also delete the branch and its commits' : null,
  );
  if (!choice.confirmed) return SessionDeleteResult.cancelled;

  // Exactly one retry.
  try {
    return await delete(force: true, deleteBranch: choice.optionSelected)
        ? SessionDeleteResult.deleted
        : SessionDeleteResult.failed;
  } on SessionOperationException catch (error) {
    if (context.mounted) _report(context, error.errorCode, error.message);
    return SessionDeleteResult.failed;
  } catch (_) {
    if (context.mounted) _report(context, null, null);
    return SessionDeleteResult.failed;
  }
}

/// Guarded by a literal `context.mounted` at every call site rather than once in
/// here: the analyzer recognises only the literal form, and folding the check
/// into this helper turns a checked lint into an unchecked convention.
void _report(BuildContext context, String? code, String? message) {
  showAbSnackBar(
    context,
    sessionRefusalCopy(code, message, 'Could not delete the session'),
  );
}
