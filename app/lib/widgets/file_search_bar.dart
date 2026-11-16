import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// A compact search field for filtering the file tree by filename. Only for use
/// inside an `AbCarbonScope`.
///
/// Reports every keystroke: the bridge-backed filter behind it already
/// debounces, and a second window here would stack on the first.
class FileSearchBar extends StatefulWidget {
  final String? currentQuery;
  final void Function(String?) onQueryChanged;

  const FileSearchBar({
    super.key,
    this.currentQuery,
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
    return CarbonSearch(
      controller: _controller,
      placeholder: 'Filter files…',
      semanticLabel: 'Filter files',
      size: CarbonFieldSize.small,
      onChanged: _onChanged,
    );
  }
}
