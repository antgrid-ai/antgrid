import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/file_tree_models.dart';
import '../providers/providers.dart';
import 'copy_path.dart';
import 'file_download.dart';

/// Marks a subtree whose host already draws the file's title bar (name, path,
/// download, close), so the viewers inside keep only their own tools. The
/// preview popup is the one host.
class ViewerChrome extends InheritedWidget {
  const ViewerChrome({super.key, required super.child});

  /// Whether the nearest host owns the title bar.
  static bool embeddedIn(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ViewerChrome>() != null;

  @override
  bool updateShouldNotify(ViewerChrome oldWidget) => false;
}

/// Shared header for media/preview viewers. [trailing] holds optional actions
/// (e.g. a preview/source toggle) placed left of Download and close.
Widget buildViewerHeader({
  required FileContent content,
  VoidCallback? onClose,
  List<Widget> trailing = const [],
}) {
  return Builder(
    builder: (context) {
      if (ViewerChrome.embeddedIn(context)) {
        if (trailing.isEmpty) return const SizedBox.shrink();
        return AbToolbar.custom(
          children: [const Spacer(), ...trailing],
        );
      }
      return AbToolbar.custom(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ViewerPathBreadcrumb(path: content.path),
            ),
          ),
          ...trailing,
          FileDownloadButton(content: content),
          if (onClose != null)
            AbIconButton(icon: AbIcons.close, onTap: onClose),
        ],
      );
    },
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
        // An image outside the checkout has no relative form, so the only
        // copy on offer is the absolute path it already is.
        if (!isAbsoluteViewerPath(widget.path))
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
    final parts = _segments(widget.path).toList();
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
        Text(
          i == parts.length - 1 ? part : _shortenFolder(part),
          style: i == parts.length - 1 ? file : folder,
        ),
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

final _separator = RegExp(r'[\\/]');
final _driveRoot = RegExp(r'^[A-Za-z]:');
final _driveRootSlash = RegExp(r'^[A-Za-z]:[\\/]');
final _trailingSeparators = RegExp(r'[\\/]+$');

Iterable<String> _segments(String path) =>
    path.split(_separator).where((s) => s.isNotEmpty);

/// A folder name too long to scan, such as the session UUID in an agent's
/// scratchpad path, kept to its ends: `66dd53be…a8631`. Display only — every
/// copy gives the full path.
String _shortenFolder(String name) => name.length <= 24
    ? name
    : '${name.substring(0, 8)}…${name.substring(name.length - 5)}';

/// True for a path that already names its own root: POSIX, a Windows drive,
/// or UNC. The viewer is handed one for an image outside the checkout
/// (`externalImagePath`), which has no relative form to join.
bool isAbsoluteViewerPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    _driveRootSlash.hasMatch(path);

/// [relative] joined onto [root] in [root]'s separator style — the checkout
/// lives on the bridge's machine, which need not share this one's OS.
String joinCheckoutPath(String root, String relative) {
  final windows = root.contains(r'\') || _driveRoot.hasMatch(root);
  final base = root.replaceAll(_trailingSeparators, '');
  final parts = _segments(relative);
  return [base, ...parts].join(windows ? r'\' : '/');
}
