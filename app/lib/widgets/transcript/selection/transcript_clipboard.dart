import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'copy_resolver.dart';

enum CopyKind { rich, plain, markdown }

enum ClipboardFormat { html, plain }

class ClipboardFragment {
  final ClipboardFormat format;
  final String data;
  const ClipboardFragment(this.format, this.data);
}

/// Fragments written when the platform clipboard supports multi-format writes.
List<ClipboardFragment> formatsFor(CopyKind kind, CopyOutput out) =>
    switch (kind) {
      CopyKind.rich => [
          ClipboardFragment(ClipboardFormat.html, out.html),
          ClipboardFragment(ClipboardFormat.plain, out.plain),
        ],
      CopyKind.plain => [ClipboardFragment(ClipboardFormat.plain, out.plain)],
      CopyKind.markdown => [
          ClipboardFragment(ClipboardFormat.plain, out.markdown),
        ],
    };

/// Plain payload used when [SystemClipboard.instance] is null.
String fallbackText(CopyKind kind, CopyOutput out) =>
    kind == CopyKind.markdown ? out.markdown : out.plain;

abstract class TranscriptClipboardSink {
  Future<void> write(CopyKind kind, CopyOutput out);
}

/// Writes via super_clipboard; degrades to core [Clipboard] when the platform
/// clipboard API is unavailable (e.g. some web/headless contexts).
class SuperClipboardSink implements TranscriptClipboardSink {
  const SuperClipboardSink();

  @override
  Future<void> write(CopyKind kind, CopyOutput out) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      await Clipboard.setData(ClipboardData(text: fallbackText(kind, out)));
      return;
    }
    final item = DataWriterItem();
    for (final fragment in formatsFor(kind, out)) {
      switch (fragment.format) {
        case ClipboardFormat.html:
          item.add(Formats.htmlText(fragment.data));
        case ClipboardFormat.plain:
          item.add(Formats.plainText(fragment.data));
      }
    }
    await clipboard.write([item]);
  }
}
