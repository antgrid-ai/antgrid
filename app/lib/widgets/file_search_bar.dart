import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_search_field.dart';

/// A compact search bar for filtering the file tree by filename.
///
/// Carries no padding and sizes itself to a dense action row: it is mounted
/// in the file tree's [AbToolbar.actions] centre slot, which owns the inset
/// and the row height.
class FileSearchBar extends StatefulWidget {
  final String? currentQuery;
  /// Coalescing window before [onQueryChanged] fires. A mount whose callback
  /// already debounces passes [Duration.zero] rather than paying both.
  final Duration debounce;
  final void Function(String?) onQueryChanged;

  const FileSearchBar({
    super.key,
    this.currentQuery,
    this.debounce = const Duration(milliseconds: 300),
    required this.onQueryChanged,
    this.focusNode,
  });

  /// Lets the explorer put the keyboard here for the Filter files shortcut.
  final FocusNode? focusNode;

  @override
  State<FileSearchBar> createState() => _FileSearchBarState();
}

class _FileSearchBarState extends State<FileSearchBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentQuery ?? '');
  }

  @override
  void didUpdateWidget(FileSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync controller if external query changed (e.g. cleared externally)
    if (widget.currentQuery != oldWidget.currentQuery &&
        widget.currentQuery != _controller.text) {
      _controller.text = widget.currentQuery ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.onQueryChanged(value.isEmpty ? null : value);
  }

  /// ↓ to the tree below, ↑ back to the tab strip above. A one-line field
  /// takes both as caret moves, which would trap arrow navigation here.
  void _leave(TraversalDirection direction) =>
      FocusManager.instance.primaryFocus?.focusInDirection(direction);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _leave(TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _leave(TraversalDirection.up),
      },
      child: _buildField(context),
    );
  }

  Widget _buildField(BuildContext context) {
    return AbSearchField(
      controller: _controller,
      focusNode: widget.focusNode,
      hint: 'Filter files...',
      height: AbTokens.rowHeightXs,
      // Chrome, not a control. The action row already bounds it, so an
      // outline and a fill of its own would draw a box inside a box; taking
      // both away leaves the row reading as one surface.
      border: false,
      fillColor: context.antgrid.bgDeep,
      // Drops the magnifier into the column the tree's disclosure chevrons
      // occupy directly below. Both start at the same inset by construction:
      // the row's own is AbTokens.space12, and the toolbar's padding plus its
      // centre-slot gap come to the same, so squaring the prefix slot to the
      // glyph is all the alignment needs.
      prefixIconWidth: AbTokens.iconButtonGlyph,
      debounce: widget.debounce,
      onChanged: _onChanged,
    );
  }
}
