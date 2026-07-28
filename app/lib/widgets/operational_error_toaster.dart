import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_snack_bar.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';

/// Invisible host for the focused project's transient operational errors and feedback.
///
/// Git-checkout, git commit/discard feedback, and session failures are stored
/// in the focused services' state but have no in-context UI of their own
/// (unlike file-read/search,
/// which render their error where they happen). This surfaces them as a
/// snackbar so they aren't silently swallowed — without a persistent drawer
/// dot (reserved for structural config errors).
///
/// Errors are de-duplicated per project. The focused-state providers re-emit
/// the newly-focused project's `currentState` on every focus switch — and
/// that state may still hold a stale error that was already announced (these
/// errors clear only on the next git/session op, not on blur). A plain
/// prev-vs-next comparison would therefore re-toast old failures when you
/// switch back to a project. Keying the last-announced error by projectId
/// suppresses that; resetting the key when the error clears lets a genuine
/// recurrence of the same message toast again.
class OperationalErrorToaster extends ConsumerStatefulWidget {
  const OperationalErrorToaster({super.key});

  @override
  ConsumerState<OperationalErrorToaster> createState() =>
      _OperationalErrorToasterState();
}

class _OperationalErrorToasterState
    extends ConsumerState<OperationalErrorToaster> {
  // projectId -> last error string already toasted, per channel. One entry
  // per visited project; lives for the app session.
  final Map<String, String?> _lastGitError = {};
  final Map<String, String?> _lastBranchesError = {};
  final Map<String, String?> _lastSessionError = {};
  // git op feedback de-dups on the op SEQUENCE, not the message string: two
  // ops can carry identical text ("Discarded changes") and must each toast.
  final Map<String, int> _lastGitOpSeq = {};

  /// Toast [error] once per (project, message), recording what was shown in
  /// [seen]. De-dup is keyed by [projectId] — the id carried ON THE STATE,
  /// never the focused id (`selectedRegistrationIdProvider`): Riverpod retains the
  /// previous project's `AsyncData` while the focused-state provider
  /// re-subscribes after a focus switch (see `freshSessionsStateProvider`), so
  /// keying on the focused id would attribute a retained stale error to the
  /// wrong project. Resetting the key on clear lets a genuine recurrence toast.
  void _announce(
    Map<String, String?> seen,
    String? projectId,
    String? error,
    String Function(String) format,
  ) {
    if (projectId == null) return;
    if (error == null) {
      seen[projectId] = null;
      return;
    }
    if (seen[projectId] == error) return;
    seen[projectId] = error;
    showAbSnackBar(context, format(error));
  }

  /// Toast a git op result once per (project, seq). Unlike [_announce], de-dup
  /// is keyed by the monotonically-increasing op seq carried on the state, so
  /// an identical message from a later op (seq advanced) toasts again without
  /// needing a null transition in between.
  void _announceOp(String? projectId, int? seq, String? message) {
    if (projectId == null || seq == null || seq == 0 || message == null) return;
    if (_lastGitOpSeq[projectId] == seq) return;
    _lastGitOpSeq[projectId] = seq;
    showAbSnackBar(context, message);
  }

  @override
  Widget build(BuildContext context) {
    // `.select` to a (projectId, error) record so each listener fires only when
    // the error (or its owning project) changes — not on every terminal frame.
    ref.listen(
      terminalStateProvider.select(
        (s) => (s.value?.projectId, s.value?.gitCheckoutError),
      ),
      // The terminal service already stores a 'Checkout failed' fallback in
      // gitCheckoutError, so surface the message verbatim rather than
      // re-prefixing (which would read "Checkout failed: Checkout failed").
      (_, next) => _announce(_lastGitError, next.$1, next.$2, (e) => e),
    );
    ref.listen(
      terminalStateProvider.select(
        (s) => (s.value?.projectId, s.value?.gitBranchesError),
      ),
      // Same verbatim surface as gitCheckoutError: the service stores a full
      // message, and the branch picker has no in-context error UI of its own.
      (_, next) => _announce(_lastBranchesError, next.$1, next.$2, (e) => e),
    );
    ref.listen(
      sessionsStateProvider.select(
        (s) => (s.value?.projectId, s.value?.error),
      ),
      (_, next) => _announce(
        _lastSessionError,
        next.$1,
        next.$2,
        (e) => 'Session error: $e',
      ),
    );
    ref.listen(
      fileTreeStateProvider.select(
        (s) => (
          s.value?.projectId,
          s.value?.gitOpFeedbackSeq,
          s.value?.gitOpFeedback,
        ),
      ),
      (_, next) => _announceOp(next.$1, next.$2, next.$3),
    );
    return const SizedBox.shrink();
  }
}
