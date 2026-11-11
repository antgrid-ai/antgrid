import 'dart:typed_data';

import '../services/upload_service.dart';

String attachmentFileName(
  String? reported,
  String? fallbackExtension, {
  DateTime? now,
  String prefix = 'attached',
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
  return '$prefix-${at.year}${pad(at.month)}${pad(at.day)}'
      '-${pad(at.hour)}${pad(at.minute)}${pad(at.second)}'
      '.${fallbackExtension ?? 'bin'}';
}

/// The running count also protects reads whose size is unknown or changes
/// after the initial stat. Checking only after readAll would buffer too much.
Future<Uint8List> readCapped({
  required int? declaredSize,
  required Stream<List<int>> Function() stream,
  required int limit,
}) async {
  if (declaredSize != null && declaredSize > limit) {
    throw const UploadException('TOO_LARGE', '');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream()) {
    if (builder.length + chunk.length > limit) {
      throw const UploadException('TOO_LARGE', '');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}
