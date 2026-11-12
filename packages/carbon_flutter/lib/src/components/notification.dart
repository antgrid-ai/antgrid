import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import 'button.dart';

/// The meaning of a notification, which picks its icon, accent and
/// announcement urgency.
enum CarbonNotificationKind { info, success, warning, error }

/// An optional action on a notification. It is independent of the close
/// button: activating one never triggers the other.
class CarbonNotificationAction {
  const CarbonNotificationAction({
    required this.label,
    required this.onPressed,
    this.kind = CarbonButtonKind.ghost,
  });

  final String label;
  final VoidCallback onPressed;

  /// Ghost (default) or tertiary.
  final CarbonButtonKind kind;
}

/// An inline notification: a message that lives in the page flow.
///
/// The component never dismisses itself and never fetches or persists
/// anything; the host decides when it exists (omit it to remove it) and
/// passes [onClose] to show a close button.
///
/// The kind is always conveyed by a filled icon labelled with the localized
/// kind name, never by color alone. Announcement: when the notification first
/// appears, info and success are a polite live region and warning and error
/// are announced assertively, once; a notification that changes from info or
/// success to warning or error announces then, and rebuilding an error or
/// warning with new text does not announce again. A polite live region is
/// re-read by the platform whenever its text changes ([announce] false for
/// content already on screen at load).
///
/// Critical information must also remain available elsewhere; a notification
/// that the host removes is gone for assistive technology as well.
///
/// Deviation from Carbon: the default is the low-contrast treatment (the
/// theme's notification backgrounds); [highContrast] selects the inverse
/// surface.
class CarbonNotification extends StatelessWidget {
  const CarbonNotification({
    super.key,
    this.kind = CarbonNotificationKind.info,
    this.title,
    this.subtitle,
    this.action,
    this.onClose,
    this.highContrast = false,
    this.announce = true,
  }) : assert(
         title != null || subtitle != null,
         'A notification needs a title, a subtitle or both.',
       );

  final CarbonNotificationKind kind;

  /// The bold lead. Optional, as in Carbon: a single-sentence message reads
  /// better as a [subtitle] alone than as a run of heading-weight text.
  final String? title;
  final String? subtitle;
  final CarbonNotificationAction? action;

  /// Shows the close button when non-null.
  final VoidCallback? onClose;
  final bool highContrast;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    return _NotificationCard(
      kind: kind,
      title: title,
      subtitle: subtitle,
      action: action,
      onClose: onClose,
      highContrast: highContrast,
      announce: announce,
      stacked: false,
    );
  }
}

/// A toast: a transient, high-contrast message presented by a
/// [CarbonToastOverlay]. Same kinds, semantics and independence of action and
/// close as [CarbonNotification], with an optional [caption] such as a time.
///
/// A toast can vanish before it is read or heard, so it must never be the only
/// place critical information appears.
class CarbonToast extends StatelessWidget {
  const CarbonToast({
    super.key,
    this.kind = CarbonNotificationKind.info,
    required this.title,
    this.subtitle,
    this.caption,
    this.action,
    this.onClose,
    this.highContrast = true,
    this.announce = true,
  });

  final CarbonNotificationKind kind;
  final String title;
  final String? subtitle;
  final String? caption;
  final CarbonNotificationAction? action;
  final VoidCallback? onClose;
  final bool highContrast;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    return _NotificationCard(
      kind: kind,
      title: title,
      subtitle: subtitle,
      caption: caption,
      action: action,
      onClose: onClose,
      highContrast: highContrast,
      announce: announce,
      stacked: true,
    );
  }
}

// The "!" of the warning glyph must read dark on Carbon's yellow in every
// theme, so it is not taken from a theme role that flips with brightness.
const Color _warningGlyph = Color(0xFF161616);

class _NotificationCard extends StatefulWidget {
  const _NotificationCard({
    required this.kind,
    required this.title,
    required this.subtitle,
    this.caption,
    required this.action,
    required this.onClose,
    required this.highContrast,
    required this.announce,
    required this.stacked,
  });

  final CarbonNotificationKind kind;
  final String? title;
  final String? subtitle;
  final String? caption;
  final CarbonNotificationAction? action;
  final VoidCallback? onClose;
  final bool highContrast;
  final bool announce;

  /// Title, subtitle and caption on separate lines (toast) instead of running
  /// together (inline).
  final bool stacked;

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  bool _announced = false;

  bool get _assertive =>
      widget.kind == CarbonNotificationKind.error ||
      widget.kind == CarbonNotificationKind.warning;

  @override
  void initState() {
    super.initState();
    if (widget.announce && _assertive) _scheduleAnnouncement();
  }

  @override
  void didUpdateWidget(_NotificationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasAssertive =
        oldWidget.kind == CarbonNotificationKind.error ||
        oldWidget.kind == CarbonNotificationKind.warning;
    // The live region of a polite kind disappears in the same rebuild, so the
    // switch to an urgent kind has to be spoken explicitly.
    if (widget.announce && _assertive && !wasAssertive) {
      _announced = false;
      _scheduleAnnouncement();
    }
  }

  // Needs the view and localizations, which are only readable after the first
  // dependency pass.
  void _scheduleAnnouncement() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _announce());

  void _announce() {
    if (!mounted || _announced) return;
    _announced = true;
    final view = View.maybeOf(context);
    if (view == null) return;
    final loc = CarbonLocalizations.of(context);
    final parts = <String>[
      _kindName(loc),
      ?widget.title,
      ?widget.subtitle,
    ];
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        parts.join('. '),
        Directionality.maybeOf(context) ?? TextDirection.ltr,
        assertiveness: Assertiveness.assertive,
      ).catchError((Object _) {}),
    );
  }

  String _kindName(CarbonLocalizations loc) => switch (widget.kind) {
    CarbonNotificationKind.info => loc.info,
    CarbonNotificationKind.success => loc.success,
    CarbonNotificationKind.warning => loc.warning,
    CarbonNotificationKind.error => loc.error,
  };

  CarbonIcons get _icon => switch (widget.kind) {
    CarbonNotificationKind.info => CarbonIcons.informationFilled,
    CarbonNotificationKind.success => CarbonIcons.checkmarkFilled,
    CarbonNotificationKind.warning => CarbonIcons.warningAltFilled,
    CarbonNotificationKind.error => CarbonIcons.errorFilled,
  };

  static CarbonThemeScheme _inverseScheme(CarbonThemeScheme scheme) =>
      switch (scheme) {
        CarbonThemeScheme.white => CarbonThemeScheme.gray100,
        CarbonThemeScheme.gray10 => CarbonThemeScheme.gray90,
        CarbonThemeScheme.gray90 => CarbonThemeScheme.gray10,
        CarbonThemeScheme.gray100 => CarbonThemeScheme.white,
      };

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final loc = CarbonLocalizations.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final high = widget.highContrast;
    final kind = widget.kind;

    final Color background;
    final Color accent;
    final Color textColor;
    switch (kind) {
      case CarbonNotificationKind.info:
        background = high
            ? colors.backgroundInverse
            : colors.notificationBackgroundInfo;
        accent = high ? colors.supportInfoInverse : colors.supportInfo;
      case CarbonNotificationKind.success:
        background = high
            ? colors.backgroundInverse
            : colors.notificationBackgroundSuccess;
        accent = high ? colors.supportSuccessInverse : colors.supportSuccess;
      case CarbonNotificationKind.warning:
        background = high
            ? colors.backgroundInverse
            : colors.notificationBackgroundWarning;
        accent = high ? colors.supportWarningInverse : colors.supportWarning;
      case CarbonNotificationKind.error:
        background = high
            ? colors.backgroundInverse
            : colors.notificationBackgroundError;
        accent = high ? colors.supportErrorInverse : colors.supportError;
    }
    textColor = high ? colors.textInverse : colors.textPrimary;
    final glyphInner = kind == CarbonNotificationKind.warning
        ? _warningGlyph
        : background;

    // Buttons on the inverse surface need the inverse theme's roles to stay
    // legible; a custom palette is left alone because its inverse is unknown.
    var controlTheme = theme;
    if (high && colors == theme.scheme.colors) {
      controlTheme = theme.copyWith(scheme: _inverseScheme(theme.scheme));
    }

    // Carbon's sizes are the compact ones; touch keeps the density's own icon
    // and text so finger-use layouts do not shrink.
    final compact = !theme.isTouch;
    final stacked = widget.stacked;
    final iconSize = compact ? 20.0 : theme.iconSize;
    final lineHeight = (type.body.height ?? 1.4) * (type.body.fontSize ?? 14);
    final titleStyle = type.heading.copyWith(color: textColor);
    final bodyStyle = (compact ? type.control : type.body).copyWith(
      color: textColor,
    );
    // Carbon puts the icon 14 px (16 in a toast) below the top edge and the
    // text 15 px (16) below it, so the card's own padding is the smaller of
    // the two and the text takes the difference.
    final topPad = compact
        ? (stacked ? CarbonSpacing.spacing05 : 14.0)
        : CarbonSpacing.spacing04;
    final textExtraTop = compact && !stacked ? 1.0 : 0.0;
    final bottomPad = compact
        ? (stacked ? CarbonSpacing.spacing05 : 15.0)
        : CarbonSpacing.spacing04;
    final closeGap = stacked ? CarbonSpacing.spacing05 : 13.0;

    final title = widget.title;
    final subtitle = widget.subtitle;
    final caption = widget.caption;
    final Widget text;
    if (widget.stacked) {
      text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) Text(title, style: titleStyle),
          if (subtitle != null) Text(subtitle, style: bodyStyle),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: CarbonSpacing.spacing03),
              child: Text(
                caption,
                style: bodyStyle,
              ),
            ),
        ],
      );
    } else {
      text = Text.rich(
        TextSpan(
          children: [
            if (title != null) TextSpan(text: title, style: titleStyle),
            if (subtitle != null)
              TextSpan(
                text: title == null ? subtitle : ' $subtitle',
                style: bodyStyle,
              ),
          ],
        ),
      );
    }

    final message = Semantics(
      container: true,
      liveRegion: widget.announce && !_assertive,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: compact ? 0 : math.max(0, (lineHeight - iconSize) / 2),
            ),
            child: CarbonIcon(
              _icon,
              size: iconSize,
              color: accent,
              innerColor: glyphInner,
              semanticLabel: _kindName(loc),
            ),
          ),
          const SizedBox(width: CarbonSpacing.spacing05),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: textExtraTop),
              child: text,
            ),
          ),
        ],
      ),
    );

    final action = widget.action;
    final onClose = widget.onClose;
    // Touch density takes its target from the theme, so a host that sets a
    // smaller touch target gets a close button that honours it.
    final closeSize = theme.isTouch
        ? theme.minTarget
        : math.max(theme.minTarget, CarbonSizes.lg);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          border: BorderDirectional(
            start: BorderSide(color: accent, width: CarbonBorders.selectedTab),
          ),
          boxShadow: stacked
              ? const [
                  BoxShadow(
                    color: Color(0x33000000),
                    offset: Offset(0, 2),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
        // Carbon outlines the low-contrast inline card in its support colour
        // at 40% on every edge but the accent bar's. Painted over the card, so
        // it takes no layout space.
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: high || stacked
                ? null
                : BorderDirectional(
                    top: BorderSide(color: accent.withValues(alpha: 0.4)),
                    end: BorderSide(color: accent.withValues(alpha: 0.4)),
                    bottom: BorderSide(color: accent.withValues(alpha: 0.4)),
                  ),
          ),
          child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: closeSize),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: CarbonSpacing.spacing05 - CarbonBorders.selectedTab,
                    end: onClose == null ? CarbonSpacing.spacing05 : closeGap,
                    top: topPad,
                    bottom: bottomPad,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      message,
                      if (action != null)
                        Padding(
                          padding: EdgeInsetsDirectional.only(
                            start: iconSize + CarbonSpacing.spacing05,
                            top: CarbonSpacing.spacing03,
                          ),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: CarbonTheme(
                              data: controlTheme,
                              child: CarbonButton(
                                label: action.label,
                                kind: action.kind,
                                size: CarbonButtonSize.small,
                                onPressed: action.onPressed,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (onClose != null)
                CarbonTheme(
                  data: controlTheme,
                  child: CarbonButton.iconOnly(
                    icon: const CarbonIcon(CarbonIcons.close),
                    semanticLabel: loc.dismissNotification,
                    hoverFill: false,
                    size: theme.isTouch ? null : CarbonButtonSize.large,
                    onPressed: onClose,
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// A handle on a toast shown through [CarbonToastController.show].
class CarbonToastHandle {
  CarbonToastHandle._(this._controller, this.id);

  final CarbonToastController _controller;
  final int id;

  /// Whether the toast is still showing.
  bool get isShowing => _controller._find(id) != null;

  /// Removes the toast. Idempotent.
  void dismiss() => _controller.dismiss(id);
}

class _ToastEntry {
  _ToastEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.caption,
    required this.action,
    required this.autoDismiss,
    required this.dismissible,
  });

  final int id;
  final CarbonNotificationKind kind;
  final String title;
  final String? subtitle;
  final String? caption;
  final CarbonNotificationAction? action;
  final Duration? autoDismiss;
  final bool dismissible;
}

/// Owns the list of showing toasts for a [CarbonToastOverlay]. Host-owned:
/// create it once, dispose it with its owner.
///
/// Toasts stay until [dismiss] or the user's close button, unless a toast is
/// shown with [show]'s opt-in `autoDismiss`.
class CarbonToastController extends ChangeNotifier {
  final List<_ToastEntry> _entries = <_ToastEntry>[];
  int _nextId = 0;
  bool _disposed = false;

  // A handle outlives the screen that showed it, so a late dismiss after the
  // owner disposed the controller must be a no-op rather than a notify on a
  // disposed ChangeNotifier.
  @override
  void dispose() {
    _disposed = true;
    _entries.clear();
    super.dispose();
  }

  /// How many toasts are showing.
  int get length => _entries.length;

  _ToastEntry? _find(int id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Shows a toast, newest last. [action]'s callback does not dismiss the
  /// toast; call the returned handle's [CarbonToastHandle.dismiss] from it if
  /// that is wanted.
  ///
  /// [autoDismiss] is opt-in. The timer pauses while the pointer is over the
  /// toast or focus is inside it, and restarts when they leave. It does not run
  /// at all while the platform reports screen-reader navigation. Auto-dismissal
  /// is unsuitable for critical information and for anything that needs an
  /// action: users with cognitive, motor or screen-reader needs may not get
  /// to it in time. Leave it null for those and keep the information
  /// available elsewhere too.
  ///
  /// [dismissible] false omits the close button (host removes it).
  CarbonToastHandle show({
    CarbonNotificationKind kind = CarbonNotificationKind.info,
    required String title,
    String? subtitle,
    String? caption,
    CarbonNotificationAction? action,
    Duration? autoDismiss,
    bool dismissible = true,
  }) {
    final id = _nextId++;
    _entries.add(
      _ToastEntry(
        id: id,
        kind: kind,
        title: title,
        subtitle: subtitle,
        caption: caption,
        action: action,
        autoDismiss: autoDismiss,
        dismissible: dismissible,
      ),
    );
    notifyListeners();
    return CarbonToastHandle._(this, id);
  }

  void dismiss(int id) {
    if (_disposed) return;
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length != before) notifyListeners();
  }

  void dismissAll() {
    if (_disposed || _entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}

/// Stacks the toasts of a [CarbonToastController] at a corner above [child].
///
/// Place it once, near the top of the app, inside the theme and a
/// `Directionality`. It occupies no layout space and only the toasts
/// themselves receive pointer events, so the UI underneath stays usable. It
/// keeps clear of the safe area. Toasts come after [child] in focus order and
/// are never focused automatically. A stack taller than the screen scrolls, so
/// every toast and its close button stays reachable at large text.
class CarbonToastOverlay extends StatelessWidget {
  const CarbonToastOverlay({
    super.key,
    required this.controller,
    required this.child,
    this.alignment = AlignmentDirectional.topEnd,
    this.maxWidth = 288,
    this.maxVisible = 4,
    this.hiddenLabel,
  });

  final CarbonToastController controller;
  final Widget child;

  /// The corner or edge the stack hugs; toasts stack in the order shown.
  final AlignmentGeometry alignment;
  final double maxWidth;

  /// Toasts beyond this many wait out of sight, oldest shown first, so a burst
  /// cannot cover the screen. A line after the stack counts them, as a live
  /// region, so a waiting toast is never silently lost.
  final int maxVisible;

  /// Text of that counting line for [count] waiting toasts; defaults to
  /// "`count` more".
  final String Function(int count)? hiddenLabel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final entries = controller._entries;
              if (entries.isEmpty) return const SizedBox.shrink();
              final padding =
                  MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
              final shown = entries.length > maxVisible
                  ? entries.sublist(0, maxVisible)
                  : entries;
              return Padding(
                padding: padding.add(
                  const EdgeInsets.all(CarbonSpacing.spacing05),
                ),
                child: Align(
                  alignment: alignment,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    // Unclipped so the shadow paints past the cards without
                    // widening the area that swallows taps meant for the app
                    // underneath.
                    child: SingleChildScrollView(
                      clipBehavior: Clip.none,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in shown)
                            Padding(
                              key: ObjectKey(entry),
                              padding: const EdgeInsets.only(
                                bottom: CarbonSpacing.spacing03,
                              ),
                              child: _ToastItem(
                                entry: entry,
                                controller: controller,
                              ),
                            ),
                          if (entries.length > shown.length)
                            _HiddenCount(
                              label: (hiddenLabel ?? _defaultHiddenLabel)(
                                entries.length - shown.length,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

String _defaultHiddenLabel(int count) => '$count more';

class _HiddenCount extends StatelessWidget {
  const _HiddenCount({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: DecoratedBox(
          decoration: BoxDecoration(color: theme.colors.backgroundInverse),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CarbonSpacing.spacing04,
              vertical: CarbonSpacing.spacing02,
            ),
            child: Text(
              label,
              style: theme.typography.helper.copyWith(
                color: theme.colors.textInverse,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastItem extends StatefulWidget {
  const _ToastItem({required this.entry, required this.controller});

  final _ToastEntry entry;
  final CarbonToastController controller;

  @override
  State<_ToastItem> createState() => _ToastItemState();
}

class _ToastItemState extends State<_ToastItem> {
  Timer? _timer;
  bool _hovered = false;
  bool _focused = false;
  bool _screenReader = false;
  late Duration _remaining = widget.entry.autoDismiss ?? Duration.zero;

  bool get _timed => widget.entry.autoDismiss != null;

  @override
  void initState() {
    super.initState();
    if (_timed) _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Accessibility focus is neither hover nor input focus, so the platform
    // flag is the only signal that someone is navigating by screen reader.
    _screenReader = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Counted down in ticks rather than measured against the wall clock so a
  // pause keeps exactly the time that was left.
  static const Duration _tick = Duration(milliseconds: 100);

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) {
      _remaining -= _tick;
      if (_remaining <= Duration.zero) _expire();
    });
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
  }

  void _expire() {
    _timer?.cancel();
    _timer = null;
    if (mounted) widget.controller.dismiss(widget.entry.id);
  }

  void _syncTimer() {
    if (!_timed) return;
    if (_hovered || _focused || _screenReader) {
      _pause();
    } else if (_timer == null) {
      _start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _syncTimer();
      },
      onExit: (_) {
        _hovered = false;
        _syncTimer();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: (focused) {
          _focused = focused;
          _syncTimer();
        },
        child: CarbonToast(
          kind: entry.kind,
          title: entry.title,
          subtitle: entry.subtitle,
          caption: entry.caption,
          action: entry.action,
          onClose: entry.dismissible
              ? () => widget.controller.dismiss(entry.id)
              : null,
        ),
      ),
    );
  }
}
