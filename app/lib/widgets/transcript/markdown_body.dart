import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../providers/providers.dart';
import '../../providers/visible_surface.dart';
import '../../util/external_url.dart';
import '../markdown_heading_configs.dart';

/// Markdown for assistant messages: MarkdownBlock (non-scrollable — the
/// transcript ListView scrolls), AbTokens-themed, code fences get a copy
/// button. Mirrors markdown_preview.dart's config so the two stay consistent.
class TranscriptMarkdown extends ConsumerWidget {
  final String data;
  const TranscriptMarkdown({super.key, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.antgrid;
    return MarkdownBlock(
      data: data,
      selectable: false,
      config: MarkdownConfig(
        configs: [
          PConfig(
            // Prose leading, not the font's default (~1.2). Body copy is the
            // one run in a transcript that gets read rather than scanned, and
            // tight leading is what makes a wall of agent output feel dense.
            textStyle: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              color: c.textPrimary,
              height: 1.55,
            ),
          ),
          // Underline is the whole affordance — links take body color, no tint.
          // The package default is GitHub blue (#0969DA), a light-theme link
          // color that lands near 3:1 on our dark surfaces.
          // `onTap` routes through the same file/preview/browser split every
          // other link-bearing surface uses — see [openContentLink].
          LinkConfig(
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              color: c.textPrimary,
              height: 1.55,
            ).copyWith(decoration: TextDecoration.underline),
            onTap: (url) => openContentLink(
              context,
              url,
              fileService: () => focusedCheckoutServiceOrNull(
                ref.container,
                (s) => s.fileService,
              ),
              previewService: () => focusedCheckoutServiceOrNull(
                ref.container,
                (s) => s.previewService,
              ),
              revealView: (view) =>
                  ref.read(workspaceMenuControlProvider)?.reveal(view),
            ),
          ),
          CodeConfig(
            // Match body (fontMd), not the smaller fontSm, so an inline-code run
            // and surrounding prose highlight at the same height under selection
            // (BoxHeightStyle.tight sizes each rect to raw glyph metrics — a
            // smaller font paints a shorter selection box on the same line).
            // height tracks PConfig for the same reason fontSize does: an
            // inline-code run shares a line box with the prose around it, and a
            // shorter line box paints a misaligned selection rect.
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontMd,
              color: c.textPrimary,
              height: 1.55,
            ),
          ),
          PreConfig(
            textStyle: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: c.textPrimary,
              height: 1.5,
            ),
            // Package default is a11yLightTheme — light-bg token colors on our
            // dark UI, and the spec says no syntax coloring (v1). Empty theme +
            // styleNotMatched = plain mono.
            theme: const {},
            styleNotMatched: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: c.textPrimary,
              height: 1.5,
            ),
            decoration: BoxDecoration(
              color: c.bgElevated,
              border: Border.all(color: c.borderSubtle),
              borderRadius: BorderRadius.circular(AbTokens.radius),
            ),
            padding: const EdgeInsets.all(AbTokens.space8),
            wrapper: (child, code, language) =>
                _CodeBlockFrame(code: code, child: child),
          ),
          // Tight chat scale: body is fontMd (13), so headings stay close to it
          // and lean on weight, not size, for hierarchy — a big display scale
          // reads as shouting in a transcript. height 1.3 keeps heading rows
          // from stacking tall. H4-H6 are pinned too, else they fall back to the
          // package's large defaults when an agent emits `####`+. Headings use
          // textSecondary (body is textPrimary): the bold weight carries
          // prominence while the tone sets them apart from the body run.
          H1ConfigNoRule(
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontLg,
              color: c.textSecondary,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          H2ConfigNoRule(
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontBody,
              color: c.textSecondary,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          H3ConfigNoRule(
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
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
        ],
      ),
    );
  }
}

class _CodeBlockFrame extends StatelessWidget {
  final String code;
  final Widget child;
  const _CodeBlockFrame({required this.code, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: AbTokens.space2,
          right: AbTokens.space2,
          child: AbIconButton(
            icon: AbIcons.copy,
            tone: AbIconButtonTone.muted,
            tooltip: 'Copy',
            onTap: () => Clipboard.setData(ClipboardData(text: code)),
          ),
        ),
      ],
    );
  }
}
