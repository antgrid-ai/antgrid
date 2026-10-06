import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog_surface.dart';
import '../design/widgets/ab_progress_rule.dart';
import '../util/detached.dart';
import 'update_check_controller.dart';
import 'update_check_result.dart';
import 'update_install_controller.dart';
import 'update_strategy.dart';

Future<void> showUpdateStatusDialog(
  BuildContext context,
  ProviderContainer container, {
  FocusNode? returnFocus,
}) async {
  final controller = container.read(updateCheckControllerProvider.notifier);
  if (!controller.claimDialog()) return;
  bool? install;
  try {
    detached('UpdateCheck', 'manual check', controller.checkManually);
    install = await AbDialogSurface.show<bool>(
      context: context,
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: const UpdateStatusDialog(),
      ),
    );
  } finally {
    controller.releaseDialog();
    if (returnFocus?.context != null) returnFocus!.requestFocus();
  }
  if (install == true && context.mounted) {
    await container
        .read(updateInstallControllerProvider.notifier)
        .start(context);
  }
}

class UpdateStatusDialog extends ConsumerWidget {
  const UpdateStatusDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateCheckControllerProvider);
    final installing = !ref.watch(updateInstallControllerProvider).canStart;
    final strategy = ref.watch(updateStrategyProvider);
    final result = state.result;
    final busy = installing || result?.status == UpdateCheckStatus.downloading;
    final title = state.checking
        ? 'Checking for updates…'
        : busy
        ? 'Update in progress'
        : switch (result?.status) {
            UpdateCheckStatus.upToDate => 'You’re up to date',
            UpdateCheckStatus.available => 'Update available',
            UpdateCheckStatus.restartReady => 'Update ready to restart',
            UpdateCheckStatus.failed => 'Couldn’t check for updates',
            _ => 'Updates unavailable',
          };
    final message = state.checking
        ? 'Contacting the update service.'
        : busy
        ? 'The platform update is already in progress.'
        : result?.message ??
              switch (result?.status) {
                UpdateCheckStatus.upToDate =>
                  'You’re running the latest available version.',
                UpdateCheckStatus.available =>
                  'A new version is available to install.',
                UpdateCheckStatus.restartReady =>
                  'The update has downloaded. Restart to install it.',
                UpdateCheckStatus.failed =>
                  'Try again when the update service is reachable.',
                _ => UpdateCheckResult.unsupported.message!,
              };
    return AbDialogSurface(
      title: 'Check for updates',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              title,
              style: AbTokens.sansStyle(fontSize: AbTokens.fontBody),
            ),
          ),
          const SizedBox(height: AbTokens.space8),
          Text(
            message,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textSecondary,
            ),
          ),
          if (!state.checking && result?.version != null) ...[
            const SizedBox(height: AbTokens.space8),
            Text(
              'Version ${result!.version}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: context.antgrid.textSecondary,
              ),
            ),
          ],
          if (state.checking || busy) ...[
            const SizedBox(height: AbTokens.space16),
            const AbProgressRule(fraction: null),
          ],
          if (!state.checking &&
              !busy &&
              (result?.actionable == true ||
                  result?.status == UpdateCheckStatus.failed)) ...[
            const SizedBox(height: AbTokens.space16),
            Align(
              alignment: Alignment.centerRight,
              child: AbButton(
                label: result!.status == UpdateCheckStatus.failed
                    ? 'Retry'
                    : strategy!.actionLabel(result),
                variant: AbButtonVariant.primary,
                onTap: () {
                  if (result.status == UpdateCheckStatus.failed) {
                    final controller = ref.read(
                      updateCheckControllerProvider.notifier,
                    );
                    detached(
                      'UpdateCheck',
                      'retry manual check',
                      controller.checkManually,
                    );
                  } else {
                    Navigator.of(context).pop(true);
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
