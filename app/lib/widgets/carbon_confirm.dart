import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Asks a yes/no question in a Carbon confirmation modal; dismissing it any
/// other way answers no.
///
/// [context] must sit under a Carbon scope. A [danger] confirmation opens on
/// Cancel, the safe choice.
Future<bool> showCarbonConfirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final confirmed = await showCarbonModal<bool>(
    context,
    builder: (modalContext) {
      final t = CarbonTheme.of(modalContext);
      void answer(bool value) => Navigator.of(modalContext).pop(value);
      return CarbonModal.confirmation(
        title: title,
        body: Text(
          body,
          style: t.typography.body.copyWith(color: t.colors.textPrimary),
        ),
        danger: danger,
        secondary: CarbonModalAction(
          label: cancelLabel,
          onPressed: () => answer(false),
        ),
        primary: CarbonModalAction(
          label: confirmLabel,
          onPressed: () => answer(true),
        ),
      );
    },
  );
  return confirmed ?? false;
}
