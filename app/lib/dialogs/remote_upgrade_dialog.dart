import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../models/subscription_info.dart';

/// Browser URL where subscription changes (cancel, resume, plan) are managed.
String subscriptionManageUrl(String licenseApiUrl) {
  final base = licenseApiUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/dashboard';
}

/// Shown when the user tries to buy or change a subscription on the wrong platform.
Future<void> showCrossPlatformBillingDialog(
  BuildContext context, {
  required String provider,
  required String licenseApiUrl,
}) {
  final manageUrl = crossPlatformManageUrl(
    provider: provider,
    licenseApiUrl: licenseApiUrl,
  );
  return showDialog<void>(
    context: context,
    builder: (_) => _CrossPlatformBillingDialog(
      title: crossPlatformDialogTitle(provider),
      manageUrl: manageUrl,
    ),
  );
}

class _CrossPlatformBillingDialog extends StatelessWidget {
  const _CrossPlatformBillingDialog({
    required this.title,
    required this.manageUrl,
  });

  final String title;
  final String manageUrl;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              abDialogTitle(title, onClose: () => Navigator.of(context).pop()),
              const SizedBox(height: AbTokens.space16),
              Text(
                'You can\'t make changes to your subscription inside this app, '
                'because you purchased this subscription on another platform.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              Text(
                'Please visit $manageUrl in a browser to modify your subscription.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AbTokens.space16),
              Align(
                alignment: Alignment.centerRight,
                child: AbButton(
                  label: 'OK',
                  variant: AbButtonVariant.primary,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
