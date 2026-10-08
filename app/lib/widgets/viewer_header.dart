import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/providers.dart';
import 'copy_path.dart';
import 'viewer_support.dart';

/// Shared header for media/preview viewers. [trailing] holds optional actions
/// (e.g. a preview/source toggle) placed left of the close button.
Widget buildViewerHeader({
  required String path,
  required int size,
  VoidCallback? onClose,
  List<Widget> trailing = const [],
}) {
  return Builder(
    builder: (context) => AbToolbar.custom(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(child: ViewerPathBreadcrumb(path: path)),
              const SizedBox(width: AbTokens.space6),
              Text(
                formatFileSize(size),
                style: AbTokens.monoStyle(color: context.antgrid.textMuted),
              ),
            ],
          ),
        ),
        ...trailing,
        if (onClose != null) AbIconButton(icon: AbIcons.close, onTap: onClose),
      ],
    ),
  );
}

/// The open file's project-relative path as an address-bar breadcrumb —
/// `docs › protocol › peer-session.md` — the way Windows Explorer shows where
/// you are. Folders muted, the file itself emphasised; a path too long for
/// the header slides off on the LEFT, so the file name is always the part
/// that stays.
///
/// The whole crumb is one target: clicking it opens a menu offering the path
/// in the project-relative form the file tree's Copy path gives, or absolute
/// on the machine that holds the checkout.
class ViewerPathBreadcrumb extends StatefulWidget {
  const ViewerPathBreadcrumb({super.key, required this.path});

  final String path;

  @override
  State<ViewerPathBreadcrumb> createState() => _ViewerPathBreadcrumbState();
}

class _ViewerPathBreadcrumbState extends State<ViewerPathBreadcrumb> {
  bool _hovered = false;

  /// The focused checkout's root, from its `agent:status`. Read at click time
  /// through the container rather than watched, so rendering the crumb needs
  /// no `ProviderScope` and a status frame never rebuilds it.
  String? _checkoutRoot() {
    try {
      return ProviderScope.containerOf(
        context,
        listen: false,
      ).read(terminalStateProvider).value?.checkoutPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showMenu() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final root = _checkoutRoot();
    final absolute = isAbsoluteViewerPath(widget.path)
        ? widget.path
        : (root == null || root.isEmpty)
        ? null
        : joinCheckoutPath(root, widget.path);
    final pick = await showAbMenu<String>(
      context: context,
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      entries: [
        AbMenuItem(
          label: 'Copy relative path',
          icon: AbIcons.copy,
          value: widget.path,
        ),
        AbMenuItem(
          label: 'Copy absolute path',
          icon: AbIcons.copy,
          value: absolute ?? '',
          enabled: absolute != null,
          // An older bridge reports no checkout root, and the app has no
          // other way to learn where the checkout lives.
          disabledReason: 'This agent does not report where its checkout is.',
        ),
      ],
    );
    if (!mounted || pick == null || pick.isEmpty) return;
    await copyPathWithToast(context, pick);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final parts = widget.path
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    final folder = AbTokens.monoStyle(color: p.textMuted);
    final file = AbTokens.monoStyle(
      color: p.textPrimary,
      fontWeight: FontWeight.w600,
    );
    final crumbs = <Widget>[
      for (final (i, part) in parts.indexed) ...[
        if (i > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space2),
            child: AbIcon(AbIcons.chevronRight, size: 12, color: p.textMuted),
          ),
        Text(part, style: i == parts.length - 1 ? file : folder),
      ],
    ];
    return AbTooltip(
      message: 'Copy path',
      child: Semantics(
        button: true,
        label: 'Copy path ${widget.path}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showMenu,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space6,
                vertical: AbTokens.space2,
              ),
              decoration: BoxDecoration(
                color: _hovered ? p.bgHover : null,
                borderRadius: AbTokens.borderRadius5,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(mainAxisSize: MainAxisSize.min, children: crumbs),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// True for a path that already names its own root: POSIX, a Windows drive,
/// or UNC. The viewer is handed one for an image outside the checkout
/// (`externalImagePath`), which has no relative form to join.
bool isAbsoluteViewerPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// [relative] joined onto [root] in [root]'s separator style — the checkout
/// lives on the bridge's machine, which need not share this one's OS.
String joinCheckoutPath(String root, String relative) {
  final windows = root.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(root);
  final base = root.replaceAll(RegExp(r'[\\/]+$'), '');
  final parts = relative.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  return [base, ...parts].join(windows ? r'\' : '/');
}
