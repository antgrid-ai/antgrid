import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_info.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_menu.dart';
import '../providers/app_version.dart';
import '../providers/support_chat.dart';
import '../util/external_url.dart';
import '../util/detached.dart';
import 'log_files_button.dart';
import 'settings/legal_notices_sheet.dart';

AbMenuSubmenu helpMenu({
  required BuildContext context,
  required WidgetRef ref,
  Rect? shareOrigin,
  Future<void> Function(BuildContext, String) openUrl = openExternalUrl,
  Future<void> Function(BuildContext, WidgetRef) openChat = openSupportChat,
  Future<void> Function(BuildContext, Rect?)? openLogs,
}) {
  void run(Future<void> Function() action) {
    if (context.mounted) detached('HelpMenu', 'open help action', action);
  }

  final logLabel = logFilesActionLabel();
  return AbMenuSubmenu(
    label: 'Help',
    icon: AbIcons.info,
    entries: [
      AbMenuItem(
        label: 'Getting started',
        onTap: () =>
            run(() => openUrl(context, 'https://antgrid.ai/get-started')),
      ),
      AbMenuItem(
        label: 'Chat with support',
        onTap: () => run(() => openChat(context, ref)),
      ),
      AbMenuItem(
        label: 'Support centre',
        onTap: () => run(() => openUrl(context, 'https://antgrid.ai/support')),
      ),
      AbMenuItem(
        label: '${logLabel[0].toUpperCase()}${logLabel.substring(1)}',
        onTap: () => run(
          () => openLogs != null
              ? openLogs(context, shareOrigin)
              : runLogFilesAction(context, origin: shareOrigin),
        ),
      ),
      const AbMenuDivider(),
      AbMenuItem(
        label: 'Source code',
        onTap: () => run(() => openUrl(context, BuildInfo.sourceUrl)),
      ),
      AbMenuItem(
        label: 'Licences & notices',
        onTap: () => run(() => showLegalNotices(context)),
      ),
      const AbMenuInfo(label: 'Version', value: _HelpVersion()),
    ],
  );
}

class _HelpVersion extends ConsumerWidget {
  const _HelpVersion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionLabelProvider).asData?.value ?? '';
    return Text(
      version,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXs,
        color: context.antgrid.textMuted,
      ),
    );
  }
}
