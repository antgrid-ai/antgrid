import 'dart:io' show Platform;

/// Last non-empty path segment of [folder]. Avoids pulling in `package:path`
/// for one call.
String pathBasename(String folder) {
  final parts = folder
      .split(Platform.pathSeparator)
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? folder : parts.last;
}
