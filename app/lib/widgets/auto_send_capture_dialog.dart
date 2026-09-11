import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_progress_rule.dart';
import '../services/upload_service.dart';
import 'send_capture_to_agent.dart';
import 'send_to_agent_comment.dart' show CaptureImagePreview;

/// Sends a preview capture straight to the agent with no comment step first —
/// the picture already IS the message, same reasoning as the draw tool's
/// direct send — but puts the pending capture back up on screen while the
/// send actually happens, rather than leaving nothing behind once the
/// drawing toolbar closes.
///
/// Nothing is actually transmitted until
/// [_AutoSendCaptureDialogState._kGraceWindow] has elapsed — a chat handoff is
/// synchronous, so without that window Close/Cancel would never have
/// anything left to stop. The two destinations [sendCaptureToAgent] can pick
/// past that point are genuinely different speeds, not just different
/// wording, and this dialog has to read honestly for both: a terminal send
/// has a real upload behind it (seconds long on a slow link), so its button
/// actually cancels that upload; a chat handoff is synchronous (the image
/// just becomes a composer attachment), so there's nothing left to call off
/// once it fires, and the dialog instead holds its "done" frame for
/// [_AutoSendCaptureDialogState._kDoneHold] — long enough to actually be seen
/// — before closing itself. Either way the button stays on screen the whole
/// time (reading "Cancel" while a send is still stoppable, "Close"
/// otherwise) so the dialog is never stuck up with no way to dismiss it.
/// Always shown, in both modes: skipping it for chat used to mean the draw
/// tool showed nothing at all whenever the focused session happened to be in
/// chat mode.
Future<void> showAutoSendCapture({
  required BuildContext context,
  required ProviderContainer container,
  required String text,
  required Uint8List imageBytes,
  required String fileName,
}) {
  return showDialog<void>(
    context: context,
    // The send is already committed the moment this opens — a stray tap on
    // the barrier must not silently drop it. Cancel is the only way out.
    barrierDismissible: false,
    builder: (_) => _AutoSendCaptureDialog(
      container: container,
      text: text,
      imageBytes: imageBytes,
      fileName: fileName,
    ),
  );
}

const double _kDialogWidth = 480.0;

class _AutoSendCaptureDialog extends StatefulWidget {
  const _AutoSendCaptureDialog({
    required this.container,
    required this.text,
    required this.imageBytes,
    required this.fileName,
  });

  final ProviderContainer container;
  final String text;
  final Uint8List imageBytes;
  final String fileName;

  @override
  State<_AutoSendCaptureDialog> createState() =>
      _AutoSendCaptureDialogState();
}

class _AutoSendCaptureDialogState extends State<_AutoSendCaptureDialog> {
  /// How long the "done" frame holds before the dialog closes itself — mainly
  /// for the chat route, which has no upload to visibly track and would
  /// otherwise pop the instant it opened.
  static const Duration _kDoneHold = Duration(seconds: 2);

  /// Nothing is actually sent until this elapses — a chat handoff is
  /// synchronous, so without a hold Close would have no window in which it
  /// could ever mean anything: the message would already be gone by the time
  /// the dialog had even finished its first frame. During this window
  /// [_cancel] cancels outright rather than merely dismissing.
  static const Duration _kGraceWindow = Duration(seconds: 1);

  late final bool _isChat = focusedSessionIsChat(widget.container);
  final _cancelToken = UploadCancelToken();
  int _sent = 0;
  int _total = 0;
  bool _cancelling = false;
  bool _cancelledInGrace = false;
  bool _started = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(_kGraceWindow);
    if (!mounted) return;
    if (_cancelledInGrace) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _started = true);
    // sendCaptureToAgent's own bool only ever means "landed in the terminal
    // right now" — a chat handoff returns false too, same as a failure or a
    // cancel, so it can't stand in for "this dialog's job is done" on its
    // own. [_isChat] is what makes those cases distinguishable.
    final sent = await sendCaptureToAgent(
      context: context,
      container: widget.container,
      text: widget.text,
      imageBytes: widget.imageBytes,
      fileName: widget.fileName,
      cancelToken: _isChat ? null : _cancelToken,
      onProgress: _isChat
          ? null
          : (sent, total) {
              if (!mounted) return;
              setState(() {
                _sent = sent;
                _total = total;
              });
            },
    );
    if (!mounted) return;
    if (_cancelling) {
      Navigator.of(context).pop();
      return;
    }
    if (!_isChat && !sent) {
      // A real failure, not a cancel — already reported by a snackbar from
      // within sendCaptureToAgent, which states it better than a checkmark
      // this dialog has no room to contradict would.
      Navigator.of(context).pop();
      return;
    }
    setState(() => _done = true);
    await Future<void>.delayed(_kDoneHold);
    if (mounted) Navigator.of(context).pop();
  }

  /// Inside the grace window this cancels outright — nothing has been sent
  /// yet, so there's nothing to be gentle about. Once the real send has
  /// started, a terminal upload in flight is still genuinely stoppable;
  /// everywhere else (chat's synchronous handoff, or the post-send "done"
  /// hold) there is nothing left to call off, so it just dismisses the
  /// dialog on the spot instead of leaving the user stuck watching a hold
  /// with no way out.
  void _cancel() {
    if (_cancelling) return;
    if (!_started) {
      _cancelledInGrace = true;
      Navigator.of(context).pop();
      return;
    }
    if (!_isChat && !_done) {
      setState(() => _cancelling = true);
      _cancelToken.cancel();
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final fraction = total > 0 ? _sent / total : null;
    final finishing = total > 0 && _sent >= total;
    // "Cancel" whenever tapping it actually stops something from being sent
    // — the grace window (nothing sent yet) or a real upload in flight.
    // Every other state — chat's instant handoff already fired, or the
    // post-send hold — gets "Close", so the dialog is never stuck on screen
    // with no way out.
    final canCancelUpload = !_started || (!_isChat && !_done);
    final dismissLabel = _cancelling
        ? 'Cancelling…'
        : (canCancelUpload ? 'Cancel' : 'Close');
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kDialogWidth),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CaptureImagePreview(bytes: widget.imageBytes),
              const SizedBox(height: AbTokens.space12),
              Row(
                children: [
                  AbIcon(
                    _done ? AbIcons.check : AbIcons.upload,
                    size: AbTokens.iconButtonGlyph,
                    color: _done
                        ? context.antgrid.success
                        : context.antgrid.accent,
                  ),
                  const SizedBox(width: AbTokens.space6),
                  Expanded(
                    child: Text(
                      _statusLabel(
                        isChat: _isChat,
                        started: _started,
                        cancelling: _cancelling,
                        done: _done,
                        finishing: finishing,
                        fraction: fraction,
                      ),
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontSm,
                        color: context.antgrid.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space8),
              AbProgressRule(
                fraction: _done
                    ? 1.0
                    : (_cancelling || _isChat ? null : fraction),
              ),
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(
                    label: dismissLabel,
                    onTap: _cancelling ? null : _cancel,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _statusLabel({
  required bool isChat,
  required bool started,
  required bool cancelling,
  required bool done,
  required bool finishing,
  required double? fraction,
}) {
  if (cancelling) return 'Cancelling…';
  if (done) return isChat ? 'Added to composer' : 'Sent to agent';
  // Still inside the grace window — nothing has actually gone out yet, so
  // this must read differently from the in-flight state right after it,
  // which is what makes Close/Cancel meaning "nothing sent" believable.
  if (!started) return 'Preparing to send…';
  if (isChat) return 'Adding to composer…';
  if (fraction == null) return 'Sending to agent…';
  if (finishing) return 'Sending to agent · finishing…';
  return 'Sending to agent · ${(fraction * 100).round()}%';
}
