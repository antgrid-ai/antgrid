import 'package:flutter/widgets.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../models/file_tree_models.dart';
import 'markdown_heading_configs.dart';
import 'preview_with_source_toggle.dart';

/// Renders a markdown file. Defaults to the rendered preview; a header toggle
/// switches to the full source code view.
class MarkdownPreview extends StatelessWidget {
  final FileContent content;
  final VoidCallback? onClose;
  final VoidCallback? onRefreshContent;
  final bool fileWasModified;
  final int? searchLine;
  final String? searchQuery;

  const MarkdownPreview({
    super.key,
    required this.content,
    this.onClose,
    this.onRefreshContent,
    this.fileWasModified = false,
    this.searchLine,
    this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    return PreviewWithSourceToggle(
      content: content,
      onClose: onClose,
      onRefreshContent: onRefreshContent,
      fileWasModified: fileWasModified,
      searchLine: searchLine,
      searchQuery: searchQuery,
      previewBuilder: (context) {
        final c = context.antgrid;
        return Container(
          color: c.bgDeepest,
          child: MarkdownWidget(
            data: content.content ?? '',
            padding: const EdgeInsets.all(AbTokens.space4),
            config: MarkdownConfig(configs: [
              // Prose leading, not the font's default (~1.2) — matches the
              // transcript's PConfig. Inline code tracks it so a code run
              // shares the surrounding paragraph's line box.
              PConfig(
                textStyle: AbTokens.sansStyle(
                  color: c.textPrimary,
                  height: 1.55,
                ),
              ),
              // Underline-only links, matching the transcript — see
              // markdown_body.dart for why the package default is unusable.
              LinkConfig(
                style: AbTokens.sansStyle(
                  color: c.textPrimary,
                  height: 1.55,
                ).copyWith(decoration: TextDecoration.underline),
              ),
              CodeConfig(
                style: AbTokens.monoStyle(color: c.textPrimary, height: 1.55),
              ),
              PreConfig(
                // textStyle controls the inline code font; decoration supplies the block bg.
                textStyle: AbTokens.monoStyle(
                  color: c.textPrimary,
                  height: 1.5,
                ),
                decoration: BoxDecoration(color: c.bgElevated),
                padding: const EdgeInsets.all(AbTokens.space4),
              ),
              // Document scale (this is a full-file view, so more hierarchy
              // than the chat transcript): explicit sizes + weight, and all six
              // levels pinned so H4-H6 don't fall back to the package's large
              // defaults. Default sansStyle() is fontBody (14) with no weight,
              // which left headings indistinguishable from body text. Headings
              // use textSecondary (body is textPrimary) so tone plus weight,
              // not size alone, sets them apart.
              H1ConfigNoRule(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXl,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              H2ConfigNoRule(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontLg,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              H3ConfigNoRule(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontBody,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              H4Config(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              H5Config(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              H6Config(
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
