import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../models/agent_event.dart';

enum DiffOp { context, add, del }

class DiffLine {
  final String text;
  final DiffOp op;
  const DiffLine(this.text, this.op);
}

const _kMaxDiffLines = 2000;

/// Line-level LCS diff. O(n*m) DP — fine for edit-sized files; inputs beyond
/// [_kMaxDiffLines] fall back to whole-file del+add (no quadratic blowup).
List<DiffLine> computeLineDiff(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  if (a.length > _kMaxDiffLines || b.length > _kMaxDiffLines) {
    return [
      for (final l in a) DiffLine(l, DiffOp.del),
      for (final l in b) DiffLine(l, DiffOp.add),
    ];
  }
  final n = a.length, m = b.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(DiffLine(a[i], DiffOp.context));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(DiffLine(a[i], DiffOp.del));
      i++;
    } else {
      out.add(DiffLine(b[j], DiffOp.add));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(a[i++], DiffOp.del));
  }
  while (j < m) {
    out.add(DiffLine(b[j++], DiffOp.add));
  }
  return out;
}

/// Parses pre-rendered unified-patch text (lines prefixed +/-/@@) when the
/// bridge sent a patch instead of old/new texts.
List<DiffLine> parsePatchText(String patch) => [
  for (final l in patch.split('\n'))
    if (l.startsWith('+'))
      DiffLine(l.substring(1), DiffOp.add)
    else if (l.startsWith('-'))
      DiffLine(l.substring(1), DiffOp.del)
    else if (!l.startsWith('@@'))
      DiffLine(l, DiffOp.context),
];

/// Old/new-vs-patch source selection, separate from the widget so callers can
/// compute lines once and reuse them (stats line + render).
List<DiffLine> diffLinesFor(ToolContent content) {
  final oldT = content.oldText;
  final newT = content.newText;
  if (oldT != null || newT != null) {
    // A missing/empty side means the file was wholly created or deleted —
    // treat as all-add/all-del, not a diff against a phantom empty line.
    final oldEmpty = oldT == null || oldT.isEmpty;
    final newEmpty = newT == null || newT.isEmpty;
    if (oldEmpty && newEmpty) return const [];
    if (oldEmpty) {
      return [for (final l in newT!.split('\n')) DiffLine(l, DiffOp.add)];
    }
    if (newEmpty) {
      return [for (final l in oldT.split('\n')) DiffLine(l, DiffOp.del)];
    }
    return computeLineDiff(oldT, newT);
  }
  if (content.text != null) return parsePatchText(content.text!);
  return const [];
}

class DiffView extends StatelessWidget {
  final List<DiffLine> lines;
  const DiffView({super.key, required this.lines});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    if (lines.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Container(
              color: switch (l.op) {
                DiffOp.add => c.success.withValues(alpha: 0.08),
                DiffOp.del => c.error.withValues(alpha: 0.08),
                DiffOp.context => null,
              },
              child: Text(
                '${switch (l.op) {
                  DiffOp.add => '+',
                  DiffOp.del => '-',
                  DiffOp.context => ' ',
                }} ${l.text}',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontSm,
                  color: switch (l.op) {
                    DiffOp.add => c.success,
                    DiffOp.del => c.error,
                    DiffOp.context => c.textMuted,
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
