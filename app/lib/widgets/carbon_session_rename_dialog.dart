import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Asks for a session's new name in a Carbon modal. Returns the trimmed name,
/// or null when the user cancelled, dismissed it or left the field empty. The
/// caller decides whether an unchanged name is a no-op.
///
/// [context] must sit under a Carbon scope.
Future<String?> showCarbonSessionRename(BuildContext context, String current) {
  return showCarbonModal<String>(
    context,
    builder: (_) => _RenameBody(current: current),
  );
}

// A widget of its own because the controller has to outlive the route
// builder, which reruns whenever the modal rebuilds.
class _RenameBody extends StatefulWidget {
  const _RenameBody({required this.current});

  final String current;

  @override
  State<_RenameBody> createState() => _RenameBodyState();
}

class _RenameBodyState extends State<_RenameBody> {
  late final TextEditingController _controller =
      TextEditingController.fromValue(
        TextEditingValue(
          text: widget.current,
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: widget.current.length,
          ),
        ),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    Navigator.of(context).pop(name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    return CarbonModal(
      title: 'Rename session',
      size: CarbonModalSize.xs,
      body: CarbonTextInput(
        controller: _controller,
        label: 'Name',
        autofocus: true,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CarbonModalAction(label: 'Rename', onPressed: _submit),
      ],
    );
  }
}
