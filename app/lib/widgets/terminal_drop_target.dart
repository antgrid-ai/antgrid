import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../services/upload_service.dart';
import '../util/detached.dart';
import 'clipboard_image.dart' show imageFormatHint;
import 'data_reader_bytes.dart';

/// Exactly `TerminalAttachmentUploader.attach`'s signature, so the shared
/// pipeline's method tears off straight into the drop path.
typedef AttachRunner =
    Future<void> Function({
      required Uint8List bytes,
      required String fileName,
      String? mimeType,
    });

/// One dropped item, reduced to what the attach pipeline needs.
///
/// This is the seam the drop tests run against: a native drag session cannot be
/// synthesized under `flutter_test`, while every decision worth pinning (the
/// name, the size cap, what happens to the extras) lives above it.
abstract class DroppedFile {
  /// Extension + MIME type for the first image format this item advertises,
  /// null when it carries no image.
  (String extension, String mimeType)? get imageHint;

  /// The platform's best guess at a file name, null for raw dragged bytes.
  Future<String?> suggestedName();

  /// Reads the bytes, refusing anything over [limit] both from the size the
  /// platform declares up front and from a running count while streaming.
  /// Null when the item turned out to carry nothing readable; throws
  /// [UploadException] `TOO_LARGE` when it is over the limit.
  Future<Uint8List?> read({required int limit});
}

/// Uploads dropped items one at a time, in the order they were dropped.
///
/// Sequential rather than parallel: the upload transport is a single chunk/ack
/// conversation per session and the shared uploader single-flights, so
/// concurrent attempts would only refuse each other. All of them rather than
/// the first: dropping four screenshots and getting one path back, with no word
/// about the other three, is the kind of quiet loss a user only notices from
/// the agent's answer.
///
/// Every read and name lookup is STARTED before the first await, because the
/// caller runs this from `onPerformDrop` and the platform's drag data is only
/// guaranteed live for that callback — anything deferred until the previous
/// file's upload finished would be reading from a released session. Only the
/// uploads are sequenced.
Future<void> performTerminalDrop({
  required List<DroppedFile> items,
  required AttachRunner attach,
  required void Function(String message) onError,
  int limit = UploadService.kMaxUploadBytes,
}) async {
  final started = [
    for (final item in items)
      (item, _nameOf(item), _settled(() => item.read(limit: limit))),
  ];

  for (final (item, named, read) in started) {
    final name = await named;
    try {
      final (bytes, error) = await read;
      if (error != null) {
        onError(uploadErrorText(error, name));
        continue;
      }
      if (bytes == null) {
        onError('Could not read "$name" from the drop');
        continue;
      }
      await attach(bytes: bytes, fileName: name, mimeType: item.imageHint?.$2);
    } catch (error) {
      onError(uploadErrorText(error, name));
    }
  }
}

/// Resolves the staged name, never rejecting: a name is the one thing every
/// later branch needs, failure copy included.
Future<String> _nameOf(DroppedFile item) async {
  try {
    return droppedFileName(await item.suggestedName(), item.imageHint?.$1);
  } catch (_) {
    return droppedFileName(null, null);
  }
}

/// Folds a rejection into the value so an eagerly-started read that fails while
/// an earlier file is still uploading has a handler from the moment it
/// completes. Without this it is an unhandled async error — fatal, per
/// `util/detached.dart`.
///
/// Takes a thunk rather than a future so a SYNCHRONOUS throw out of the reader
/// is folded too: raised while the started-list is still being built, it would
/// otherwise escape past every per-file handler and abandon the whole drop
/// without a word to the user.
Future<(Uint8List?, Object?)> _settled(Future<Uint8List?> Function() start) {
  try {
    return start().then<(Uint8List?, Object?)>(
      (bytes) => (bytes, null),
      onError: (Object error) => (null, error),
    );
  } catch (error) {
    return Future.value((null, error));
  }
}

/// A name the bridge's uploader will accept for a dropped item.
///
/// `sanitizeUploadFileName` keeps only `[A-Za-z0-9._ -]`, strips leading dots
/// and rejects anything that sanitizes to empty, so the name is reduced into
/// that alphabet here rather than trusted from the platform. Unlike a pasted
/// image the reported extension is kept — a drop carries real files, and
/// forcing the advertised image format onto a `.log` would misname it.
String droppedFileName(
  String? reported,
  String? fallbackExtension, {
  DateTime? now,
}) {
  final base = (reported ?? '').split(RegExp(r'[\\/]')).last;
  final cleaned = base
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
      .trim();
  if (cleaned.isNotEmpty) {
    final needsExtension = !cleaned.contains('.') && fallbackExtension != null;
    return needsExtension ? '$cleaned.$fallbackExtension' : cleaned;
  }

  final at = now ?? DateTime.now();
  String pad(int v) => v.toString().padLeft(2, '0');
  return 'dropped-${at.year}${pad(at.month)}${pad(at.day)}'
      '-${pad(at.hour)}${pad(at.minute)}${pad(at.second)}'
      '.${fallbackExtension ?? 'bin'}';
}

/// Accepts OS drags onto the terminal and routes them into the shared attach
/// pipeline.
///
/// The dropped file is always READ AND UPLOADED, never forwarded as a path: on
/// a relay session the path the OS reports names a file on the user's own
/// machine, which the agent — running on the other one — cannot open. That is
/// the whole bug this gesture fixes. It stays byte-based for a local session
/// too, so both modes stage into the same project-local dir and the agent's
/// read boundary never has to reach outside the workspace.
class TerminalDropTarget extends StatefulWidget {
  const TerminalDropTarget({
    super.key,
    required this.child,
    required this.attach,
    required this.onError,
  });

  final Widget child;
  final AttachRunner attach;
  final void Function(String message) onError;

  @override
  State<TerminalDropTarget> createState() => _TerminalDropTargetState();
}

class _TerminalDropTargetState extends State<TerminalDropTarget> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (!mounted || _hovering == value) return;
    setState(() => _hovering = value);
  }

  /// A drag is worth accepting when it carries a real file or raw image bytes.
  /// A plain-text drag is deliberately refused: the terminal already has a
  /// paste chord for that, and staging a text selection as a file would answer
  /// the wrong gesture.
  static bool _canAttach(DropItem item) {
    try {
      return item.canProvide(Formats.fileUri) ||
          imageFormatHint(item.canProvide) != null;
    } catch (_) {
      // Format resolution throws on a target platform the package does not
      // know; an unrecognized drag is simply not ours to take.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropRegion(
      formats: Formats.standardFormats,
      // Not the `deferToChild` default: a non-driver terminal is letterboxed
      // inside an `Align`, so a drop onto the dead margin would find no region
      // at all. `opaque` only absorbs hits from siblings behind this one — its
      // own child is hit-tested first — so the terminal's selection drag and
      // the Ghostty gesture coordinator are untouched.
      hitTestBehavior: HitTestBehavior.opaque,
      onDropEnter: (_) => _setHovering(true),
      onDropLeave: (_) => _setHovering(false),
      onDropEnded: (_) => _setHovering(false),
      onDropOver: (event) {
        if (!event.session.allowedOperations.contains(DropOperation.copy)) {
          return DropOperation.none;
        }
        return event.session.items.any(_canAttach)
            ? DropOperation.copy
            : DropOperation.none;
      },
      onPerformDrop: (event) async {
        _setHovering(false);
        final items = <DroppedFile>[
          for (final item in event.session.items)
            if (_canAttach(item) && item.dataReader != null)
              _DropItemFile(item.dataReader!),
        ];
        if (items.isEmpty) return;
        // Started, never awaited: `onPerformDrop` blocks the platform thread
        // until it returns, and awaiting a 20 MB chunk/ack upload here would
        // freeze the OS drag animation for the whole transfer. The reads
        // themselves begin synchronously inside `performTerminalDrop`.
        detached(
          'TerminalDropTarget',
          'dropped file upload failed',
          () => performTerminalDrop(
            items: items,
            attach: widget.attach,
            onError: widget.onError,
          ),
        );
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering) const Positioned.fill(child: _DropHoverOverlay()),
        ],
      ),
    );
  }
}

/// The hover state: an accent wash over the terminal with a centered pill
/// saying what the drop will do. [IgnorePointer] so it can never enter a hit
/// test the native drag machinery is walking.
class _DropHoverOverlay extends StatelessWidget {
  const _DropHoverOverlay();

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: 0.08),
          border: Border.all(color: p.accent),
        ),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.bgElevated,
              borderRadius: AbTokens.borderRadius8,
              border: Border.all(color: p.accent.withValues(alpha: 0.3)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space16,
                vertical: AbTokens.space12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AbIcon(AbIcons.upload, size: 24, color: p.accent),
                  const SizedBox(height: AbTokens.space8),
                  Text(
                    'Drop to attach',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AbTokens.space4),
                  Text(
                    "Uploaded to the agent's machine, then typed as a path",
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: p.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [DroppedFile] over one drag item's [DataReader].
class _DropItemFile implements DroppedFile {
  _DropItemFile(this._reader);

  final DataReader _reader;

  @override
  (String, String)? get imageHint {
    try {
      return imageFormatHint(_reader.canProvide);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> suggestedName() async {
    try {
      return await _reader.getSuggestedName();
    } catch (_) {
      // A missing suggestion costs a synthesized name, never the attach.
      return null;
    }
  }

  @override
  Future<Uint8List?> read({required int limit}) => collectFileBytes(
    // A null format lets super_clipboard pick: a file synthesized from the
    // dropped file URI first, then a virtual file, then the first platform
    // format. Every one of those hands over BYTES — which is the point, since
    // the local path the OS reports does not exist on a remote agent's machine.
    (onFile, onError) =>
        _reader.getFile(
          null,
          (file) => onFile(
            () => readCapped(
              declaredSize: file.fileSize,
              stream: file.getStream,
              limit: limit,
            ),
          ),
          onError: onError,
        ) !=
        null,
  );
}

/// Reads the file, refusing anything over [limit] from both the size the
/// platform declares up front and a running count while streaming.
///
/// The declared size is checked before a byte is read: a dropped 2 GB video
/// would otherwise be buffered into app memory just to be refused. The running
/// count is not redundant with it — `readAll` would buffer the whole thing
/// first, and the platform does not always declare a size to refuse it by.
@visibleForTesting
Future<Uint8List> readCapped({
  required int? declaredSize,
  required Stream<Uint8List> Function() stream,
  required int limit,
}) async {
  if (declaredSize != null && declaredSize > limit) {
    throw const UploadException('TOO_LARGE', '');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream()) {
    builder.add(chunk);
    if (builder.length > limit) throw const UploadException('TOO_LARGE', '');
  }
  return builder.takeBytes();
}
