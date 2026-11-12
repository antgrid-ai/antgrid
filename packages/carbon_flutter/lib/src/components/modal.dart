import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import 'button.dart';

/// Carbon's modal widths. The dialog is never wider than the viewport allows.
enum CarbonModalSize {
  xs(400),
  sm(560),
  md(720),
  lg(960);

  const CarbonModalSize(this.width);

  /// The preferred width in logical pixels.
  final double width;
}

/// One footer button of a [CarbonModal]. The host owns [onPressed] (null
/// disables the button) and [busy]; the modal never changes either.
class CarbonModalAction {
  const CarbonModalAction({
    required this.label,
    this.onPressed,
    this.kind = CarbonButtonKind.primary,
    this.busy = false,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final CarbonButtonKind kind;
  final bool busy;

  /// Takes initial focus when the modal opens, e.g. the safe choice of a
  /// destructive confirmation.
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;

  CarbonModalAction _withKind(CarbonButtonKind kind) => CarbonModalAction(
    label: label,
    onPressed: onPressed,
    kind: kind,
    busy: busy,
    autofocus: autofocus,
    focusNode: focusNode,
    semanticLabel: semanticLabel,
  );
}

/// Tells a [CarbonModal] whether its presentation gives it the whole screen.
/// Presentations wrap the modal in one; without it the modal sizes itself
/// from [CarbonModal.size].
class CarbonModalFrame extends InheritedWidget {
  const CarbonModalFrame({
    super.key,
    required this.fullScreen,
    required super.child,
  });

  final bool fullScreen;

  static bool fullScreenOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CarbonModalFrame>()
          ?.fullScreen ??
      false;

  @override
  bool updateShouldNotify(CarbonModalFrame old) =>
      old.fullScreen != fullScreen;
}

/// How a modal route places and animates its content.
///
/// Subclass to supply a host presentation (a bottom sheet, a side panel).
/// The route keeps values, focus and dismissal rules; the presentation only
/// positions [modal], honoring the safe area and keyboard inset so actions
/// stay reachable, and should wrap it in a [CarbonModalFrame].
abstract class CarbonModalPresentation {
  const CarbonModalPresentation();

  /// Centered dialog sized by [CarbonModal.size].
  const factory CarbonModalPresentation.centered() = _CenteredPresentation;

  /// Fills the screen inside the safe area.
  const factory CarbonModalPresentation.fullScreen() = _FullScreenPresentation;

  /// Centered, becoming full screen when the viewport is narrower than
  /// [compactBelow].
  const factory CarbonModalPresentation.adaptive({double compactBelow}) =
      _AdaptivePresentation;

  /// [animation] runs 0 to 1 on enter and back on exit; it is already
  /// instantaneous under reduced motion.
  Widget build(
    BuildContext context,
    Animation<double> animation,
    Widget modal,
  );
}

/// Supplies the [CarbonModalPresentation] that [showCarbonModal] uses for
/// modals presented from below it, so an app picks one policy once.
class CarbonModalPresentationScope extends InheritedWidget {
  const CarbonModalPresentationScope({
    super.key,
    required this.presentation,
    required super.child,
  });

  final CarbonModalPresentation presentation;

  static CarbonModalPresentation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CarbonModalPresentationScope>()
      ?.presentation;

  @override
  bool updateShouldNotify(CarbonModalPresentationScope old) =>
      old.presentation != presentation;
}

EdgeInsets _safeInsets(BuildContext context) {
  final padding = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
  final insets = MediaQuery.maybeViewInsetsOf(context) ?? EdgeInsets.zero;
  return EdgeInsets.fromLTRB(
    math.max(padding.left, insets.left),
    math.max(padding.top, insets.top),
    math.max(padding.right, insets.right),
    math.max(padding.bottom, insets.bottom),
  );
}

Widget _enter(BuildContext context, Animation<double> animation, Widget child) {
  if (CarbonMotion.reduced(context)) return child;
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final curve = animation.status == AnimationStatus.reverse
          ? CarbonMotion.exit
          : CarbonMotion.entrance;
      final t = curve.transform(animation.value.clamp(0.0, 1.0));
      return Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, -CarbonSpacing.spacing06 * (1 - t)),
          child: child,
        ),
      );
    },
  );
}

class _CenteredPresentation extends CarbonModalPresentation {
  const _CenteredPresentation();

  @override
  Widget build(BuildContext context, Animation<double> animation, Widget modal) {
    return Padding(
      padding: _safeInsets(context).add(
        const EdgeInsets.all(CarbonSpacing.spacing05),
      ),
      child: Center(
        child: _enter(
          context,
          animation,
          CarbonModalFrame(fullScreen: false, child: modal),
        ),
      ),
    );
  }

  @override
  bool operator ==(Object other) => other is _CenteredPresentation;

  @override
  int get hashCode => 0;
}

class _FullScreenPresentation extends CarbonModalPresentation {
  const _FullScreenPresentation();

  @override
  Widget build(BuildContext context, Animation<double> animation, Widget modal) {
    return Padding(
      padding: _safeInsets(context),
      child: _enter(
        context,
        animation,
        CarbonModalFrame(fullScreen: true, child: modal),
      ),
    );
  }

  @override
  bool operator ==(Object other) => other is _FullScreenPresentation;

  @override
  int get hashCode => 1;
}

class _AdaptivePresentation extends CarbonModalPresentation {
  const _AdaptivePresentation({this.compactBelow = 480});

  final double compactBelow;

  @override
  Widget build(BuildContext context, Animation<double> animation, Widget modal) {
    final compact = MediaQuery.sizeOf(context).width < compactBelow;
    return compact
        ? const _FullScreenPresentation().build(context, animation, modal)
        : const _CenteredPresentation().build(context, animation, modal);
  }

  @override
  bool operator ==(Object other) =>
      other is _AdaptivePresentation && other.compactBelow == compactBelow;

  @override
  int get hashCode => compactBelow.hashCode;
}

/// A Carbon dialog surface: title, optional eyebrow label, scrollable body,
/// close button and footer actions.
///
/// Variants: [CarbonModal.informational] (no actions, the close button is the
/// way out), [CarbonModal.confirmation] (secondary plus primary, optionally
/// danger) and the default constructor for form dialogs, whose body hosts
/// fields and whose actions the host disables or marks busy while it
/// validates or submits.
///
/// Long content scrolls while the header and actions stay in view; at large
/// text or small heights the body gives up space first. Present it with
/// [showCarbonModal]. The close button calls [onClose], or by default asks
/// the route to close, which honors the route's dismissal veto.
class CarbonModal extends StatelessWidget {
  const CarbonModal({
    super.key,
    required this.title,
    required this.body,
    this.label,
    this.actions = const <CarbonModalAction>[],
    this.size = CarbonModalSize.sm,
    this.onClose,
    this.showCloseButton = true,
    this.semanticLabel,
  });

  /// A passive dialog with no actions.
  const CarbonModal.informational({
    super.key,
    required this.title,
    required this.body,
    this.label,
    this.size = CarbonModalSize.sm,
    this.onClose,
    this.showCloseButton = true,
    this.semanticLabel,
  }) : actions = const <CarbonModalAction>[];

  /// A decision dialog. [primary] is forced to the danger treatment when
  /// [danger] is set and [secondary] is always the secondary treatment.
  CarbonModal.confirmation({
    super.key,
    required this.title,
    required this.body,
    required CarbonModalAction primary,
    required CarbonModalAction secondary,
    bool danger = false,
    this.label,
    this.size = CarbonModalSize.sm,
    this.onClose,
    this.showCloseButton = true,
    this.semanticLabel,
  }) : actions = <CarbonModalAction>[
         secondary._withKind(CarbonButtonKind.secondary),
         primary._withKind(
           danger ? CarbonButtonKind.danger : CarbonButtonKind.primary,
         ),
       ];

  final String title;

  /// Small text above the title, e.g. the name of the project concerned.
  final String? label;

  /// The content. Scrolls when taller than the dialog.
  final Widget body;

  /// Footer buttons in display order; by convention the last is primary.
  final List<CarbonModalAction> actions;

  final CarbonModalSize size;

  /// Null closes the enclosing route through `maybePop`.
  final VoidCallback? onClose;
  final bool showCloseButton;

  /// Announced as the dialog's name; defaults to [title].
  final String? semanticLabel;

  void _close(BuildContext context) {
    final onClose = this.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.maybeOf(context)?.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final loc = CarbonLocalizations.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final fullScreen = CarbonModalFrame.fullScreenOf(context);
    final closeSize = math.max(theme.minTarget, CarbonSizes.lg);

    final header = ConstrainedBox(
      constraints: BoxConstraints(minHeight: closeSize),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              CarbonSpacing.spacing05,
              CarbonSpacing.spacing05,
              showCloseButton ? closeSize + CarbonSpacing.spacing03 : 16,
              CarbonSpacing.spacing03,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null)
                  Text(
                    label!,
                    style: type.label.copyWith(color: colors.textSecondary),
                  ),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: type.headingLarge.copyWith(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          if (showCloseButton)
            PositionedDirectional(
              top: 0,
              end: 0,
              child: CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.close),
                semanticLabel: loc.close,
                size: CarbonButtonSize.large,
                onPressed: () => _close(context),
              ),
            ),
        ],
      ),
    );

    final bodyView = SingleChildScrollView(
      padding: const EdgeInsetsDirectional.fromSTEB(
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing02,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing06,
      ),
      child: DefaultTextStyle.merge(
        style: type.body.copyWith(color: colors.textPrimary),
        child: body,
      ),
    );

    final footer = actions.isEmpty
        ? null
        : CarbonButtonSet(
            alignment: CarbonButtonSetAlignment.fill,
            children: [
              for (final action in actions)
                CarbonButton(
                  label: action.label,
                  kind: action.kind,
                  size: CarbonButtonSize.extraLarge,
                  busy: action.busy,
                  autofocus: action.autofocus,
                  focusNode: action.focusNode,
                  semanticLabel: action.semanticLabel,
                  onPressed: action.onPressed,
                ),
            ],
          );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: semanticLabel ?? title,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boundedHeight = constraints.hasBoundedHeight;
          final width = fullScreen
              ? constraints.maxWidth
              : math.min(size.width, constraints.maxWidth);
          final content = Column(
            mainAxisSize: fullScreen ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (!boundedHeight)
                bodyView
              else if (fullScreen)
                Expanded(child: bodyView)
              else
                Flexible(child: bodyView),
              ?footer,
            ],
          );
          return SizedBox(
            width: width,
            height: fullScreen && boundedHeight ? constraints.maxHeight : null,
            child: CarbonLayerSurface(child: content),
          );
        },
      ),
    );
  }
}

/// Presents [builder]'s content as a modal route and completes with the value
/// passed to `Navigator.pop`.
///
/// Theme, density, localizations and direction stay live: the route follows
/// the presenting context's [CarbonTheme] through a [CarbonScopeRelay], so
/// switching them while the modal is open updates it in place and keeps text
/// already typed.
///
/// Dismissal: a tap on the scrim closes only when [barrierDismissible]; Escape,
/// system back and the barrier are all subject to [canDismiss], evaluated at
/// the moment of the attempt, so a host can veto while a save is in flight.
/// Programmatic `Navigator.pop` is never vetoed. Focus is contained in the
/// dialog while open and returns to the previously focused widget on close.
///
/// [presentation] defaults to the enclosing [CarbonModalPresentationScope],
/// else [CarbonModalPresentation.adaptive].
Future<T?> showCarbonModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  ValueGetter<bool>? canDismiss,
  CarbonModalPresentation? presentation,
  bool useRootNavigator = true,
  String? barrierLabel,
  RouteSettings? routeSettings,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = _CarbonModalRoute<T>(
    builder: builder,
    relay: CarbonScopeRelay.of(context),
    presentation:
        presentation ??
        CarbonModalPresentationScope.maybeOf(context) ??
        const CarbonModalPresentation.adaptive(),
    barrierDismissible: barrierDismissible,
    canDismiss: canDismiss,
    barrierLabel:
        barrierLabel ?? CarbonLocalizations.of(context).close,
    reducedMotion: CarbonMotion.reduced(context),
    restoreFocus: FocusManager.instance.primaryFocus,
    settings: routeSettings,
  );
  return navigator.push<T>(route);
}

class _CarbonModalRoute<T> extends RawDialogRoute<T> {
  _CarbonModalRoute({
    required WidgetBuilder builder,
    required CarbonScopeRelay relay,
    required CarbonModalPresentation presentation,
    required bool barrierDismissible,
    required this.canDismiss,
    required String barrierLabel,
    required bool reducedMotion,
    required FocusNode? restoreFocus,
    super.settings,
  }) : _restoreFocus = restoreFocus,
       super(
         barrierDismissible: barrierDismissible,
         barrierLabel: barrierLabel,
         barrierColor: const Color(0x00000000),
         transitionDuration: reducedMotion
             ? Duration.zero
             : CarbonMotion.moderate02,
         transitionBuilder: (context, animation, secondary, child) => child,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         pageBuilder: (context, animation, secondaryAnimation) => relay.wrap(
           _ModalPage(
             animation: animation,
             presentation: presentation,
             builder: builder,
           ),
         ),
       );

  final ValueGetter<bool>? canDismiss;
  final FocusNode? _restoreFocus;

  // Escape, system back and the barrier all reach the route through
  // `maybePop`, which consults this; one veto point covers them.
  @override
  RoutePopDisposition get popDisposition =>
      (canDismiss?.call() ?? true)
      ? super.popDisposition
      : RoutePopDisposition.doNotPop;

  @override
  Duration get reverseTransitionDuration => transitionDuration == Duration.zero
      ? Duration.zero
      : CarbonMotion.fast02;

  @override
  void dispose() {
    super.dispose();
    final node = _restoreFocus;
    if (node == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final context = node.context;
      if (context == null || !context.mounted || !node.canRequestFocus) return;
      node.requestFocus();
    });
  }
}

class _ModalPage extends StatefulWidget {
  const _ModalPage({
    required this.animation,
    required this.presentation,
    required this.builder,
  });

  final Animation<double> animation;
  final CarbonModalPresentation presentation;
  final WidgetBuilder builder;

  @override
  State<_ModalPage> createState() => _ModalPageState();
}

class _ModalPageState extends State<_ModalPage> {
  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      };

  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    DismissIntent: CallbackAction<DismissIntent>(
      onInvoke: (_) {
        Navigator.maybeOf(context)?.maybePop();
        return null;
      },
    ),
  };

  @override
  void initState() {
    super.initState();
    // Dialog content that does not autofocus anything would leave focus on the
    // page behind; start on the first control instead. Autofocus requests of
    // descendants are also post-frame callbacks, and they register after this
    // one, so the check waits until they have all run.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (!mounted) return;
        final scope = FocusScope.of(context);
        if (scope.focusedChild == null) {
          scope.nextFocus();
        } else if (!scope.hasFocus) {
          scope.requestFocus();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: _actions,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FadeTransition(
              opacity: widget.animation,
              child: IgnorePointer(child: ColoredBox(color: colors.overlay)),
            ),
            widget.presentation.build(
              context,
              widget.animation,
              Builder(builder: widget.builder),
            ),
          ],
        ),
      ),
    );
  }
}
