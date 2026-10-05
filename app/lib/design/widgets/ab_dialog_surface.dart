import 'package:flutter/material.dart' show Dialog, showDialog;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon_button.dart';

/// Compact centered dialog chrome shared across touch and desktop platforms.
class AbDialogSurface extends StatelessWidget {
  const AbDialogSurface({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) => showDialog<T>(context: context, builder: builder);

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
    },
    child: Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop();
            return null;
          },
        ),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(AbTokens.space16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: AbTokens.sansStyle(fontSize: AbTokens.fontBody),
                      ),
                    ),
                    AbIconButton(
                      icon: AbIcons.close,
                      tooltip: 'Close',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: AbTokens.space16),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
