import 'dart:io';

import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../services/upload_service.dart';
import 'attachment_file.dart';

/// Reads native file references, never paths guessed from clipboard text.
/// The full selection is captured before uploads can outlive the clipboard.
Future<List<Uri>> readClipboardFiles({
  Future<ClipboardReader?> Function()? read,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ClipboardReader? reader;
  try {
    reader =
        await (read != null
                ? read()
                : SystemClipboard.instance?.read() ??
                      Future<ClipboardReader?>.value(null))
            .timeout(timeout);
  } on MissingPluginException {
    return const [];
  } on UnsupportedError {
    return const [];
  }
  if (reader == null) return const [];
  final values = await Future.wait(
    reader.items.map(
      (item) => Future<Uri?>.sync(
        () => item.canProvide(Formats.fileUri)
            ? item.readValue(Formats.fileUri)
            : null,
      ),
    ),
  ).timeout(timeout);
  // A file URI and a web URL can share a native format. canProvide alone
  // would turn a copied browser link into a failed attachment.
  return List.unmodifiable(
    values.whereType<Uri>().where((u) => u.isScheme('file')),
  );
}

typedef ClipboardFileAttach =
    Future<void> Function({required Uint8List bytes, required String fileName});

/// Sequential reads keep a large selection bounded to one file in memory.
Future<void> attachClipboardFiles({
  required List<Uri> files,
  required ClipboardFileAttach attach,
  required void Function(String message) onError,
  int limit = UploadService.kMaxUploadBytes,
}) async {
  for (final uri in List<Uri>.of(files)) {
    final name = attachmentFileName(
      uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull,
      null,
    );
    try {
      final file = File.fromUri(uri);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.directory) {
        onError('Cannot paste folder "$name" — copy files instead');
        continue;
      }
      if (stat.type != FileSystemEntityType.file) {
        onError('Could not read "$name" from the clipboard');
        continue;
      }
      final bytes = await readCapped(
        declaredSize: stat.size,
        stream: file.openRead,
        limit: limit,
      );
      await attach(bytes: bytes, fileName: name);
    } catch (error) {
      onError(uploadErrorText(error, name));
    }
  }
}
