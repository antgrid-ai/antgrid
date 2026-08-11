import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import 'git_status_color.dart';

/// Parsed representation of a single diff hunk.
class _DiffHunk {
  final String header;
  final List<_DiffLine> lines;

  const _DiffHunk({required this.header, required this.lines});
}

enum _DiffLineType { context, addition, deletion }

class _DiffLine {
  final _DiffLineType type;
  final String text;
  final int? oldLineNum;
  final int? newLineNum;

  const _DiffLine({
    required this.type,
    required this.text,
    this.oldLineNum,
    this.newLineNum,
  });
}

/// Parses raw unified diff output into hunks.
List<_DiffHunk> _parseDiff(String raw) {
  final lines = raw.split('\n');
  final hunks = <_DiffHunk>[];
  String? currentHeader;
  var hunkLines = <_DiffLine>[];
  int oldLine = 0;
  int newLine = 0;

  for (final line in lines) {
    // Skip file headers
    if (line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('---') ||
        line.startsWith('+++')) {
      continue;
    }

    if (line.startsWith('@@')) {
      // Save previous hunk
      if (currentHeader != null) {
        hunks.add(_DiffHunk(header: currentHeader, lines: hunkLines));
        hunkLines = [];
      }
      currentHeader = line;
      // Parse line numbers from @@ -old,count +new,count @@
      final match = RegExp(r'@@ -(\d+),?\d* \+(\d+),?\d* @@').firstMatch(line);
      if (match != null) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
      }
      continue;
    }

    if (currentHeader == null) continue;

    if (line.startsWith('+')) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.addition,
          text: line.substring(1),
          newLineNum: newLine,
        ),
      );
      newLine++;
    } else if (line.startsWith('-')) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.deletion,
          text: line.substring(1),
          oldLineNum: oldLine,
        ),
      );
      oldLine++;
    } else if (line.startsWith(' ') || line.isEmpty) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.context,
          text: line.isEmpty ? '' : line.substring(1),
          oldLineNum: oldLine,
          newLineNum: newLine,
        ),
      );
      oldLine++;
      newLine++;
    }
  }

  // Save last hunk
  if (currentHeader != null) {
    hunks.add(_DiffHunk(header: currentHeader, lines: hunkLines));
  }

  return hunks;
}

/// Renders a unified diff with colored lines, dual line numbers, and hunk headers.
class DiffViewer extends StatelessWidget {
  final String path;
  final String? gitStatus;
  final String diff;
  final int additions;
  final int deletions;
  final VoidCallback onViewFile;
  final VoidCallback onClose;

  const DiffViewer({
    super.key,
    required this.path,
    this.gitStatus,
    required this.diff,
    required this.additions,
    required this.deletions,
    required this.onViewFile,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // Check for binary diff
    if (diff.contains('Binary files') && diff.contains('differ')) {
      final fileName = path.split('/').last;
      return _buildBinaryMessage(fileName);
    }

    final hunks = _parseDiff(diff);

    return Column(
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space8,
          ),
          decoration: BoxDecoration(
            color: context.antgrid.bgDeep,
            border: Border(
              bottom: BorderSide(color: context.antgrid.borderSubtle),
            ),
          ),
          child: Row(
            children: [
              if (gitStatus != null) ...[
                Text(
                  gitStatus!,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    fontWeight: FontWeight.w600,
                    color: gitStatusColor(context, gitStatus!),
                  ),
                ),
                const SizedBox(width: AbTokens.space8),
              ],
              Expanded(
                child: Text(
                  path,
                  style: AbTokens.monoStyle(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '+$additions',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.success,
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              Text(
                '\u2212$deletions',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.error,
                ),
              ),
              const SizedBox(width: AbTokens.space12),
              GestureDetector(
                onTap: onViewFile,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Text(
                    'View file',
                    style:
                        AbTokens.sansStyle(
                          fontSize: AbTokens.fontXs,
                          color: context.antgrid.accent,
                        ).copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: context.antgrid.accent,
                        ),
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              AbIconButton(
                icon: AbIcons.close,
                onTap: onClose,
                tooltip: 'Close diff',
              ),
            ],
          ),
        ),

        // Diff content
        Expanded(
          child: hunks.isEmpty
              ? const AbEmptyState.compact(title: 'No changes')
              : ListView.builder(
                  itemCount: hunks.length * 2 - 1,
                  itemBuilder: (context, index) {
                    if (index.isOdd) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: AbTokens.space6,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: context.antgrid.bgDeep,
                          border: Border.symmetric(
                            horizontal: BorderSide(
                              color: context.antgrid.borderSubtle,
                            ),
                          ),
                        ),
                        child: Text(
                          '\u00B7\u00B7\u00B7',
                          style: AbTokens.monoStyle(
                            fontSize: AbTokens.fontXs,
                            color: context.antgrid.textDisabled,
                          ),
                        ),
                      );
                    }

                    final hunk = hunks[index ~/ 2];
                    return _buildHunk(context, hunk);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHunk(BuildContext context, _DiffHunk hunk) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space4,
          ),
          color: context.antgrid.accent.withValues(alpha: 0.08),
          child: Text(
            hunk.header,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.accent.withValues(alpha: 0.7),
            ),
          ),
        ),
        ...hunk.lines.map((line) => _buildLine(context, line)),
      ],
    );
  }

  Widget _buildLine(BuildContext context, _DiffLine line) {
    final (Color? bgColor, Color textColor) = switch (line.type) {
      _DiffLineType.addition => (
        context.antgrid.success.withValues(alpha: 0.15),
        context.antgrid.success,
      ),
      _DiffLineType.deletion => (
        context.antgrid.error.withValues(alpha: 0.15),
        context.antgrid.error,
      ),
      _DiffLineType.context => (null, context.antgrid.textSecondary),
    };

    return Container(
      color: bgColor,
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              line.oldLineNum?.toString() ?? '',
              textAlign: TextAlign.right,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: line.type == _DiffLineType.deletion
                    ? context.antgrid.error.withValues(alpha: 0.6)
                    : context.antgrid.textMuted,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              line.newLineNum?.toString() ?? '',
              textAlign: TextAlign.right,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: line.type == _DiffLineType.addition
                    ? context.antgrid.success.withValues(alpha: 0.6)
                    : context.antgrid.textMuted,
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              line.text,
              style: AbTokens.monoStyle(color: textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBinaryMessage(String fileName) {
    return AbEmptyState(
      icon: AbIcons.fileBinary,
      title: 'Binary file changed: $fileName',
    );
  }

}
