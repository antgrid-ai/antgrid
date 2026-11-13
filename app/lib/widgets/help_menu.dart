import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_info.dart';
import '../providers/app_version.dart';
import '../providers/support_chat.dart';
import '../util/external_url.dart';
import '../util/detached.dart';
import '../update/update_status_dialog.dart';
import 'log_files_button.dart';
import 'settings/legal_notices_sheet.dart';

/// The Help submenu of the account menu.
///
/// Call it from a build method: the version heading watches
/// [appVersionLabelProvider], so it fills in while the menu is open.
CarbonMenuSubmenu helpMenu({
  required BuildContext context,
  required WidgetRef ref,
  Rect? shareOrigin,
  FocusNode? returnFocus,
  Future<void> Function(BuildContext, String) openUrl = openExternalUrl,
  Future<void> Function(BuildContext, WidgetRef) openChat = openSupportChat,
  Future<void> Function(BuildContext, Rect?)? openLogs,
}) {
  void run(Future<void> Function() action) {
    if (context.mounted) detached('HelpMenu', 'open help action', action);
  }

  final logLabel = logFilesActionLabel();
  final container = ref.container;
  final version = ref.watch(appVersionLabelProvider).asData?.value ?? '';
  return CarbonMenuSubmenu(
    label: 'Help',
    entries: [
      CarbonMenuItem(
        label: 'Getting started',
        onPressed: () =>
            run(() => openUrl(context, 'https://antgrid.ai/get-started')),
      ),
      CarbonMenuItem(
        label: 'Chat with support',
        onPressed: () => run(() => openChat(context, ref)),
      ),
      CarbonMenuItem(
        label: 'Support centre',
        onPressed: () =>
            run(() => openUrl(context, 'https://antgrid.ai/support')),
      ),
      CarbonMenuItem(
        label: '${logLabel[0].toUpperCase()}${logLabel.substring(1)}',
        onPressed: () => run(
          () => openLogs != null
              ? openLogs(context, shareOrigin)
              : runLogFilesAction(context, origin: shareOrigin),
        ),
      ),
      const CarbonMenuDivider(),
      CarbonMenuItem(
        label: 'Source code',
        onPressed: () => run(() => openUrl(context, BuildInfo.sourceUrl)),
      ),
      CarbonMenuItem(
        label: 'Licences & notices',
        onPressed: () => run(() => showLegalNotices(context)),
      ),
      CarbonMenuItem(
        label: 'Check for updates…',
        onPressed: () => run(
          () => showUpdateStatusDialog(
            context,
            container,
            returnFocus: returnFocus,
          ),
        ),
      ),
      CarbonMenuGroup(
        label: version.isEmpty ? 'Version' : 'Version $version',
        children: const [],
      ),
    ],
  );
}
