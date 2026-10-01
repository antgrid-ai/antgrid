import 'dart:async';

import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../services/screen_share_backend.dart';

/// Thumbnail box in the picker list. Sized 16:9 so a wide desktop window and a
/// tall one occupy the same slot and the titles stay on one left edge.
const double _kThumbWidth = 96;
const double _kThumbHeight = 54;

/// Picks one native window to share, on the machine that owns it.
///
/// The host-picks half of the choice. Its counterpart publishes TITLES to a
/// viewer (`screen:windows`); the thumbnails below are the reason this dialog
/// still exists separately and is never the thing serialised — a thumbnail is a
/// picture of a window nobody has agreed to share, and it stays on the machine
/// that took it.
///
/// Thumbnails are asynchronous everywhere — enumeration returns zero bytes and
/// the images land later — so this subscribes to [windowUpdates] rather than
/// reading them off the initial list.
class ScreenWindowPicker extends StatefulWidget {
  const ScreenWindowPicker({
    super.key,
    required this.listWindows,
    required this.windowUpdates,
    this.prompt,
  });

  final Future<List<ScreenWindow>> Function() listWindows;
  final Stream<ScreenWindow> windowUpdates;

  /// Why the dialog opened, when it opened on a remote peer's request rather
  /// than because the local user reached for it.
  final String? prompt;

  @override
  State<ScreenWindowPicker> createState() => _ScreenWindowPickerState();
}

class _ScreenWindowPickerState extends State<ScreenWindowPicker> {
  StreamSubscription<ScreenWindow>? _updateSub;
  List<ScreenWindow>? _windows;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Subscribe before enumerating: a thumbnail can land between the platform
    // call returning and a later listener attaching, and that tile would then
    // stay blank until the user refreshed.
    _updateSub = widget.windowUpdates.listen(_applyUpdate);
    unawaited(_load());
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    super.dispose();
  }

  void _applyUpdate(ScreenWindow window) {
    final windows = _windows;
    if (windows == null) return;
    final index = windows.indexWhere((w) => w.id == window.id);
    if (index < 0) return;
    setState(() {
      _windows = [...windows]..[index] = window;
    });
  }

  Future<void> _load() async {
    setState(() {
      _windows = null;
      _error = null;
    });
    try {
      final windows = await widget.listWindows();
      if (!mounted) return;
      setState(() => _windows = windows);
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: abDialogTitlePadding,
              child: abDialogTitle(
                'Share a window',
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space16,
                AbTokens.space8,
                AbTokens.space16,
                0,
              ),
              child: Text(
                widget.prompt ??
                    'Only the window you pick is streamed. It is brought to the '
                        'front of this desktop while it is being captured.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textMuted,
                ),
              ),
            ),
            Flexible(child: _buildBody(context)),
            Padding(
              padding: const EdgeInsets.all(AbTokens.space16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(label: 'Refresh', onTap: () => unawaited(_load())),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space24),
        child: AbEmptyState.error(
          title: 'Could not list windows',
          subtitle: '$error',
        ),
      );
    }
    final windows = _windows;
    if (windows == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AbTokens.space24),
        child: AbLoading(message: 'finding windows...'),
      );
    }
    if (windows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AbTokens.space24),
        child: AbEmptyState(
          icon: AbIcons.browser,
          title: 'No shareable windows',
          subtitle: 'Open a window on this machine and refresh',
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
      shrinkWrap: true,
      itemCount: windows.length,
      itemBuilder: (context, index) {
        final window = windows[index];
        return AbListRow(
          key: ValueKey(window.id),
          density: AbRowDensity.lg,
          hoverable: true,
          leading: _Thumbnail(window: window),
          title: Text(window.title.isEmpty ? 'Untitled window' : window.title),
          subtitle: window.minimised
              ? Text(
                  'minimised — will be restored to share',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    color: context.antgrid.textMuted,
                  ),
                )
              : Text(
                  window.id,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXxs,
                    color: context.antgrid.textMuted,
                  ),
                ),
          onTap: () => Navigator.of(context).pop(window.id),
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.window});

  final ScreenWindow window;

  @override
  Widget build(BuildContext context) {
    final bytes = window.thumbnail;
    return Container(
      width: _kThumbWidth,
      height: _kThumbHeight,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeepest,
        border: Border.all(color: context.antgrid.borderSubtle),
      ),
      clipBehavior: Clip.hardEdge,
      alignment: Alignment.center,
      child: bytes == null || bytes.isEmpty
          ? AbIcon(
              AbIcons.browser,
              size: AbTokens.iconButtonGlyph,
              color: context.antgrid.textDisabled,
            )
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              // The image is replaced in place as newer thumbnails arrive;
              // without this the tile blanks for a frame on each one.
              gaplessPlayback: true,
            ),
    );
  }
}

/// Shows the picker and resolves to the chosen window id, or null if the user
/// dismissed it.
Future<String?> showScreenWindowPicker(
  BuildContext context, {
  required Future<List<ScreenWindow>> Function() listWindows,
  required Stream<ScreenWindow> windowUpdates,
  String? prompt,
}) => showDialog<String>(
  context: context,
  builder: (_) => ScreenWindowPicker(
    listWindows: listWindows,
    windowUpdates: windowUpdates,
    prompt: prompt,
  ),
);
