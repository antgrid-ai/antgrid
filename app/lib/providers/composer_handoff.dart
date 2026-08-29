import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'value_controller.dart';

/// A capture produced somewhere other than the transcript — a preview element
/// pick, a drawing over the live preview — on its way into the chat composer.
class ComposerHandoff {
  const ComposerHandoff({
    this.fileName,
    this.bytes,
    this.mimeType,
    this.text = '',
  });

  /// Null when the capture failed and only [text] survived — a pick whose
  /// screenshot could not be taken is still a complete, useful message.
  final String? fileName;
  final Uint8List? bytes;
  final String? mimeType;

  /// Prose to seed the composer with beside the file. Whatever the user still
  /// wants to say is typed on top of it — a handoff never sends.
  final String text;
}

/// The one capture waiting to be picked up by the chat composer, if any.
///
/// A parked VALUE rather than a callback (the shape `switchToAgentProvider`
/// and friends use) precisely because the composer may not be mounted at the
/// moment the capture is made: chat mode renders the transcript, but a desktop
/// panel expanded over the agent, or a session still in terminal mode, does
/// not. A callback published only while mounted would drop the handoff on the
/// floor in exactly those cases; a parked value waits, and
/// `AgentTranscriptView` clears it as it consumes it.
///
/// Single-slot on purpose: two captures in flight at once is not a real
/// workflow, and a queue would let a forgotten one surface much later beside
/// an unrelated message.
final composerHandoffProvider =
    NotifierProvider<ValueController<ComposerHandoff?>, ComposerHandoff?>(
      () => ValueController(null),
    );
