import 'package:flutter/material.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_search_field.dart';

/// A compact search bar for filtering the file tree by filename.
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
  });

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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      child: AbSearchField(
        controller: _controller,
        hint: 'Filter files...',
        debounce: widget.debounce,
        onChanged: _onChanged,
      ),
    );
  }
}
