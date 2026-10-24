import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_toast.dart';
import '../models/file_tree_models.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'viewer_support.dart';

/// The bytes of a file the viewer already holds, or null when it holds none
/// (an error, or a file the bridge refused as too large) or cannot give back
/// exactly. Nothing is re-read: what saves is exactly what is on screen.
///
/// UTF-8 decoding can replace malformed sequences without changing the byte
/// count. Only the bridge can distinguish those replacements from literal
/// U+FFFD characters, so older bridges' ambiguous text is refused too.
Uint8List? fileContentBytes(FileContent content) {
  final raw = content.content;
  if (raw == null) return null;
  if (content.encoding == 'base64') return decodeBase64Content(raw);
  if (content.utf8Valid == false ||
      (content.utf8Valid == null && raw.contains('\uFFFD'))) {
    return null;
  }
  final bytes = Uint8List.fromList(utf8.encode(raw));
  return bytes.length == content.size ? bytes : null;
}

/// The bytes to hand on, or null after telling the user why there are none.
Uint8List? _bytesOrExplain(BuildContext context, FileContent content) {
  final bytes = fileContentBytes(content);
  if (bytes != null) return bytes;
  final name = viewerBasename(content.path);
  showAbToast(
    context,
    content.encoding == 'base64' || content.content == null
        ? "Couldn't read $name to save it"
        : "Couldn't save $name exactly — it isn't UTF-8 text",
  );
  return null;
}

/// The native app on [platform]. A web build in a phone's browser reports that
/// phone's platform too, but has neither the channel nor the share-to-save path
/// — it saves through the browser like any other web build.
bool _isNative(TargetPlatform platform) =>
    !kIsWeb && defaultTargetPlatform == platform;

/// Android's system Save-as screen, implemented in `MainActivity.kt`.
const _androidSave = MethodChannel('ai.radhaai.antgrid/save_file');

/// Saves [content] to this device, asking where with the platform's own save
/// screen. iOS has none an app can open with bytes in hand, but its share
/// sheet always offers "Save to Files", so there the share sheet IS the save.
Future<void> downloadFileContent(
  BuildContext context,
  FileContent content,
) async {
  if (_isNative(TargetPlatform.iOS)) {
    return shareFileContent(context, content);
  }
  final bytes = _bytesOrExplain(context, content);
  if (bytes == null) return;
  final name = viewerBasename(content.path);
  try {
    if (_isNative(TargetPlatform.android)) {
      final saved = await _androidSave.invokeMethod<bool>('save', {
        'name': name,
        // A text file has no MIME type from the bridge, and naming one here
        // would let the picker append its extension: README.md.txt.
        'mimeType': content.mimeType ?? 'application/octet-stream',
        'bytes': bytes,
      });
      if (saved == true && context.mounted) showAbToast(context, 'Saved $name');
      return;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return;
    await XFile.fromData(
      bytes,
      name: name,
      mimeType: content.mimeType,
    ).saveTo(location.path);
    if (context.mounted) showAbToast(context, 'Saved $name');
  } catch (e) {
    AbLog.warn('FileDownload', 'save failed', fields: {'error': '$e'});
    if (context.mounted) showAbToast(context, "Couldn't save $name");
  }
}

/// Hands [content] to the platform share sheet — to send it to another app,
/// or on iOS to "Save to Files".
Future<void> shareFileContent(BuildContext context, FileContent content) async {
  final bytes = _bytesOrExplain(context, content);
  if (bytes == null) return;
  final name = viewerBasename(content.path);
  final box = context.findRenderObject() as RenderBox?;
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: content.mimeType)],
        fileNameOverrides: [name],
        // Anchors the iPad popover; phones ignore it.
        sharePositionOrigin: box != null && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      ),
    );
  } catch (e) {
    AbLog.warn('FileDownload', 'share failed', fields: {'error': '$e'});
    if (context.mounted) showAbToast(context, "Couldn't share $name");
  }
}

/// The viewer headers' Download action, plus Share on Android, where Download
/// saves and the share sheet would otherwise be unreachable. Absent while there
/// is nothing held to save.
class FileDownloadButton extends StatelessWidget {
  const FileDownloadButton({super.key, required this.content});

  final FileContent content;

  @override
  Widget build(BuildContext context) {
    if (content.content == null) return const SizedBox.shrink();
    final download = AbIconButton(
      key: const Key('file-download'),
      icon: AbIcons.download,
      tooltip: 'Download',
      onTap: () => detached(
        'FileDownload',
        'download',
        () => downloadFileContent(context, content),
      ),
    );
    if (!_isNative(TargetPlatform.android)) return download;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbIconButton(
          key: const Key('file-share'),
          icon: AbIcons.share,
          tooltip: 'Share',
          onTap: () => detached(
            'FileDownload',
            'share',
            () => shareFileContent(context, content),
          ),
        ),
        download,
      ],
    );
  }
}
