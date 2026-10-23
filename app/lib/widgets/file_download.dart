import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toast.dart';
import '../models/file_tree_models.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'viewer_support.dart';

/// The bytes of a file the viewer already holds, or null when it holds none
/// (an error, or a file the bridge refused as too large). Nothing is re-read:
/// what saves is exactly what is on screen.
Uint8List? fileContentBytes(FileContent content) {
  final raw = content.content;
  if (raw == null) return null;
  if (content.encoding == 'base64') return decodeBase64Content(raw);
  return Uint8List.fromList(utf8.encode(raw));
}

/// Splits on both separators: an image outside the checkout arrives as the
/// host's own absolute path, which on Windows is backslashed.
String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

/// Saves [content] to this device. Desktop asks where with the OS save
/// dialog; touch has no such dialog, so it hands the file to the share sheet,
/// whose "Save to Files" / "Save to device" targets are how a phone saves.
Future<void> downloadFileContent(
  BuildContext context,
  FileContent content,
) async {
  final name = _fileName(content.path);
  final bytes = fileContentBytes(content);
  if (bytes == null) {
    showAbToast(context, "Couldn't read $name to save it");
    return;
  }
  final file = XFile.fromData(bytes, name: name, mimeType: content.mimeType);
  try {
    if (isMobilePlatform) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          // Anchors the iPad popover; phones ignore it.
          sharePositionOrigin: box != null && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
      return;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return;
    await file.saveTo(location.path);
    if (context.mounted) showAbToast(context, 'Saved $name');
  } catch (e) {
    AbLog.warn('FileDownload', 'save failed', fields: {'error': '$e'});
    if (context.mounted) showAbToast(context, "Couldn't save $name");
  }
}

/// The viewer headers' Download action. Absent while there is nothing held to
/// save.
class FileDownloadButton extends StatelessWidget {
  const FileDownloadButton({super.key, required this.content});

  final FileContent content;

  @override
  Widget build(BuildContext context) {
    if (content.content == null) return const SizedBox.shrink();
    return AbIconButton(
      key: const Key('file-download'),
      icon: AbIcons.download,
      tooltip: 'Download',
      onTap: () => detached(
        'FileDownload',
        'download',
        () => downloadFileContent(context, content),
      ),
    );
  }
}
