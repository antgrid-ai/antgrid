import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/file_tree_models.dart';
import '../providers/providers.dart';
import '../util/detached.dart';
import 'copy_path.dart';
import 'file_download.dart';
import 'viewer_support.dart';

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

/// The row every viewer's tools sit in: a first-layer strip one control tall,
/// so ghost buttons keep their own hit areas and the strip follows density.
class ViewerToolbar extends StatelessWidget {
  const ViewerToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return CarbonLayerSurface(
      padding: const EdgeInsets.symmetric(horizontal: CarbonSpacing.spacing02),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: theme.controlHeight),
        child: Row(spacing: CarbonSpacing.spacing02, children: children),
      ),
    );
  }
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
        return ViewerToolbar(children: [const Spacer(), ...trailing]);
      }
      return ViewerToolbar(
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
            ViewerIconButton(
              icon: CarbonIcons.close,
              label: 'Close file',
              onPressed: onClose,
            ),
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

  void _copy(String path) => detached('ViewerPathBreadcrumb', 'copy path', () async {
    if (!mounted) return;
    await copyPathWithToast(context, path);
  });

  void _showMenu() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final root = _checkoutRoot();
    final absolute = isAbsoluteViewerPath(widget.path)
        ? widget.path
        : (root == null || root.isEmpty)
        ? null
        : joinCheckoutPath(root, widget.path);
    showCarbonMenuAt(
      context,
      box.localToGlobal(Offset(0, box.size.height)),
      [
        // An image outside the checkout has no relative form, so the only
        // copy on offer is the absolute path it already is.
        if (!isAbsoluteViewerPath(widget.path))
          CarbonMenuItem(
            label: 'Copy relative path',
            icon: const CarbonIcon(CarbonIcons.copy),
            onPressed: () => _copy(widget.path),
          ),
        // Kept visible while an older bridge reports no checkout root, which
        // is the only way the app learns where the checkout lives, so the
        // reason is on the row rather than the item silently missing.
        CarbonMenuItem(
          label: 'Copy absolute path',
          icon: const CarbonIcon(CarbonIcons.copy),
          onPressed: absolute == null ? null : () => _copy(absolute),
          disabledReason: 'This agent does not report where its checkout is.',
        ),
      ],
      semanticLabel: 'Copy path',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final parts = _segments(widget.path).toList();
    final folder = theme.typography.code.copyWith(color: colors.textSecondary);
    final file = theme.typography.code.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w600,
    );
    final crumbs = <Widget>[
      for (final (i, part) in parts.indexed) ...[
        if (i > 0)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CarbonSpacing.spacing01,
            ),
            child: CarbonIcon(
              CarbonIcons.chevronRight,
              size: CarbonSpacing.spacing04,
              color: colors.iconSecondary,
            ),
          ),
        Text(
          i == parts.length - 1 ? part : _shortenFolder(part),
          style: i == parts.length - 1 ? file : folder,
        ),
      ],
    ];
    return CarbonTooltip(
      message: 'Copy path',
      child: CarbonInteraction(
        onPressed: _showMenu,
        label: 'Copy path ${widget.path}',
        excludeChildSemantics: true,
        builder: (context, state, child) => CarbonFocusRing(
          visible: state.focusVisible,
          child: Container(
            constraints: BoxConstraints(minHeight: theme.smallControlHeight),
            padding: const EdgeInsets.symmetric(
              horizontal: CarbonSpacing.spacing03,
            ),
            color: state.hovered ? colors.layerHover01 : null,
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: child,
            ),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(mainAxisSize: MainAxisSize.min, children: crumbs),
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
