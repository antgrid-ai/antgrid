import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const String _longSubtitle =
    'A longer explanation that wraps onto several lines at narrow widths and '
    'large text sizes without clipping or overlapping the close button.';

class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Notification',
      summary:
          'Inline notifications live in the page; toasts are transient and '
          'stacked at a corner. Both lifetimes belong to the host: nothing '
          'dismisses itself unless asked to.',
      children: [
        GallerySection(
          title: 'Inline, low contrast',
          description: 'Every kind with a labelled icon, never color alone.',
          children: [
            for (final kind in CarbonNotificationKind.values)
              CarbonNotification(
                kind: kind,
                title: _title(kind),
                subtitle: 'Subtitle text for the ${kind.name} notification.',
                announce: false,
                onClose: () {},
              ),
          ],
        ),
        GallerySection(
          title: 'Inline, high contrast',
          children: [
            for (final kind in CarbonNotificationKind.values)
              CarbonNotification(
                kind: kind,
                title: _title(kind),
                subtitle: 'Subtitle text for the ${kind.name} notification.',
                highContrast: true,
                announce: false,
                action: CarbonNotificationAction(
                  label: 'Action',
                  onPressed: () {},
                ),
                onClose: () {},
              ),
          ],
        ),
        GallerySection(
          title: 'Long content and actions',
          description:
              'Text wraps and the notification grows; the action and the '
              'close button stay separately reachable.',
          children: [
            CarbonNotification(
              kind: CarbonNotificationKind.warning,
              title: 'Disk space is running low on this machine',
              subtitle: _longSubtitle,
              announce: false,
              action: CarbonNotificationAction(
                label: 'Review large files',
                onPressed: () {},
              ),
              onClose: () {},
            ),
            const CarbonNotification(
              kind: CarbonNotificationKind.info,
              title: 'Action unavailable',
              subtitle: 'A null onPressed shows the action disabled.',
              announce: false,
              action: CarbonNotificationAction(
                label: 'Retry',
                onPressed: null,
              ),
            ),
            const CarbonNotification(
              kind: CarbonNotificationKind.info,
              title: 'No close button',
              subtitle: 'Without onClose the notification stays until the host removes it.',
              announce: false,
            ),
          ],
        ),
        const GallerySection(
          title: 'Host-controlled lifetime',
          description:
              'The host owns whether the notification exists. Error and '
              'warning are announced assertively when they first appear.',
          children: [_DismissDemo()],
        ),
        const GallerySection(
          title: 'Toasts',
          description:
              'Place one CarbonToastOverlay near the top of the app. Here it '
              'covers only the framed area; the buttons outside stay usable.',
          children: [_ToastDemo()],
        ),
        const GalleryNote(
          useWhen:
              'Inline for messages tied to a region of the page; a toast for '
              'brief confirmation of something the user just did. Critical '
              'information must also appear somewhere that persists, because '
              'a toast can vanish before it is read or heard.',
          keyboard:
              'Tab reaches the action and then the close button; both are '
              'ordinary buttons. Toasts are never focused automatically, and '
              'an opt-in timeout pauses while the pointer is over a toast or '
              'focus is inside it.',
          accessibility:
              'The kind is a labelled icon with the localized name. Info and '
              'success are polite live regions; warning and error are '
              'announced assertively once when shown, not on rebuild. '
              'Auto-dismiss is off by default and unsuitable for critical '
              'messages or anything needing an action.',
          carbonReference:
              'Carbon v11 Inline notification and Toast notification '
              '(callout and actionable variants are not included).',
        ),
      ],
    );
  }

  static String _title(CarbonNotificationKind kind) => switch (kind) {
    CarbonNotificationKind.info => 'Update available',
    CarbonNotificationKind.success => 'Project saved',
    CarbonNotificationKind.warning => 'Connection is unstable',
    CarbonNotificationKind.error => 'Could not reach the machine',
  };
}

class _DismissDemo extends StatefulWidget {
  const _DismissDemo();

  @override
  State<_DismissDemo> createState() => _DismissDemoState();
}

class _DismissDemoState extends State<_DismissDemo> {
  bool _shown = true;
  int _retries = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_shown)
          CarbonNotification(
            kind: CarbonNotificationKind.error,
            title: 'Sync failed',
            subtitle: 'Retried $_retries times.',
            action: CarbonNotificationAction(
              label: 'Retry',
              onPressed: () => setState(() => _retries++),
            ),
            onClose: () => setState(() => _shown = false),
          ),
        const SizedBox(height: CarbonSpacing.spacing04),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: CarbonButton(
            label: _shown ? 'Remove from host' : 'Show again',
            kind: CarbonButtonKind.tertiary,
            onPressed: () => setState(() => _shown = !_shown),
          ),
        ),
      ],
    );
  }
}

class _ToastDemo extends StatefulWidget {
  const _ToastDemo();

  @override
  State<_ToastDemo> createState() => _ToastDemoState();
}

class _ToastDemoState extends State<_ToastDemo> {
  final CarbonToastController _controller = CarbonToastController();
  int _count = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _show(
    CarbonNotificationKind kind, {
    Duration? autoDismiss,
    bool withAction = false,
  }) {
    _count++;
    _controller.show(
      kind: kind,
      title: 'Toast $_count',
      subtitle: 'A ${kind.name} message.',
      caption: autoDismiss == null ? null : 'Closes by itself',
      autoDismiss: autoDismiss,
      action: withAction
          ? CarbonNotificationAction(label: 'Undo', onPressed: () {})
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: CarbonSpacing.spacing04,
          runSpacing: CarbonSpacing.spacing03,
          children: [
            for (final kind in CarbonNotificationKind.values)
              CarbonButton(
                label: kind.name,
                kind: CarbonButtonKind.tertiary,
                onPressed: () => _show(kind),
              ),
            CarbonButton(
              label: 'With action',
              kind: CarbonButtonKind.tertiary,
              onPressed: () =>
                  _show(CarbonNotificationKind.success, withAction: true),
            ),
            CarbonButton(
              label: 'Auto-dismiss 5s',
              kind: CarbonButtonKind.tertiary,
              onPressed: () => _show(
                CarbonNotificationKind.info,
                autoDismiss: const Duration(seconds: 5),
              ),
            ),
            CarbonButton(
              label: 'Clear all',
              kind: CarbonButtonKind.ghost,
              onPressed: _controller.dismissAll,
            ),
          ],
        ),
        const SizedBox(height: CarbonSpacing.spacing04),
        SizedBox(
          height: 360,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.layer(1),
              border: Border.all(color: theme.borderSubtle(1)),
            ),
            child: ClipRect(
              child: CarbonToastOverlay(
                controller: _controller,
                child: Padding(
                  padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                  child: Text(
                    'App content stays interactive underneath the toasts.',
                    style: theme.typography.body.copyWith(
                      color: theme.colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
