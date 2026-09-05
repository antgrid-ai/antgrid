import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_snack_bar.dart';
import '../providers/composer_handoff.dart';
import '../providers/providers.dart';
import '../providers/session_mode.dart';
import '../services/upload_service.dart';
import 'send_to_agent_comment.dart';

/// True when the focused session is a chat rather than a terminal. Anything
/// that isn't the literal `chat` mode is a terminal, matching how
/// `AgentPanel` picks which view to render — an unknown mode string must not
/// route a capture somewhere nothing is listening.
bool focusedSessionIsChat(ProviderContainer container) =>
    container.read(activeSessionModeProvider) == 'chat';

/// Hands a captured image to the focused session's agent by whichever route
/// its mode has for receiving one.
///
/// The two modes are genuinely different destinations, not two spellings of
/// one: a chat agent takes files as ATTACHMENTS, so the image goes into the
/// composer as a chip and the user says what they want about it and presses
/// send themselves; a terminal agent has only its stdin, so the image is
/// uploaded and referenced by absolute path in the text written into it. The
/// terminal route therefore sends on the spot, and the chat route deliberately
/// does not — which is why this returns whether anything was actually sent, so
/// a caller can decide whether "Sent to agent" is a true thing to say.
///
/// [text] is the message body without any path line; the terminal route
/// appends its own. [uploadService] is resolved by the caller so this stays
/// usable from a surface whose own service may already be gone. [onProgress]
/// and [cancelToken] only matter to the terminal route's upload — a caller
/// wanting to surface it in flight (see `showAutoSendCapture`) passes them
/// through; the chat route is synchronous and ignores both.
Future<bool> sendCaptureToAgent({
  required BuildContext context,
  required ProviderContainer container,
  required String text,
  Uint8List? imageBytes,
  String? fileName,
  void Function(int sent, int total)? onProgress,
  UploadCancelToken? cancelToken,
}) async {
  if (focusedSessionIsChat(container)) {
    container
        .read(composerHandoffProvider.notifier)
        .set(
          ComposerHandoff(
            fileName: imageBytes == null ? null : fileName,
            bytes: imageBytes,
            mimeType: imageBytes == null ? null : 'image/png',
            text: text,
          ),
        );
    container.read(switchToAgentProvider)?.call();
    return false;
  }

  final termSvc = focusedCheckoutServiceOrNull(
    container,
    (s) => s.terminalService,
  );
  if (termSvc == null) {
    if (context.mounted) {
      showAbSnackBar(context, 'Not connected to the agent — could not send');
    }
    return false;
  }

  var body = text.trim();
  if (imageBytes != null && fileName != null) {
    final uploadSvc = focusedCheckoutServiceOrNull(
      container,
      (s) => s.uploadService,
    );
    if (uploadSvc == null) {
      if (context.mounted) {
        showAbSnackBar(context, 'Not connected to the agent — could not send');
      }
      return false;
    }
    final UploadResult result;
    try {
      result = await uploadSvc.upload(
        fileName: fileName,
        bytes: imageBytes,
        mimeType: 'image/png',
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } on Object catch (e) {
      // A cancel is the user's own doing, not a failure to report — the
      // caller that owns cancelToken already knows and is closing its own UI.
      if (e is UploadException && e.code == 'CANCELLED') return false;
      if (context.mounted) {
        showAbSnackBar(context, uploadErrorText(e, fileName));
      }
      return false;
    }
    final line = formatScreenshotAttachment(result.path);
    body = body.isEmpty ? line : '$body\n$line';
  }
  if (body.isEmpty) return false;

  termSvc.sendToAgentTerminal(body);
  container.read(switchToAgentProvider)?.call();
  // The capture was composed over the preview, so the keyboard is still there.
  // Hand it to the terminal the message just landed in, or the user has to
  // click into it before they can say anything about what they sent. The chat
  // route above needs no equivalent: the composer focuses itself as it picks
  // the handoff up (`AgentTranscriptView._consumeHandoff`).
  container.read(focusAgentInputProvider)?.call();
  if (context.mounted) showSentToAgentSnackBar(context);
  return true;
}

/// The staged-path line every capture route writes into a terminal prompt.
/// Matches `appendAttachmentPaths`' wording so a message composed here and one
/// composed in the chat composer read identically to the agent.
String formatScreenshotAttachment(String path) => 'Attached file: $path';
