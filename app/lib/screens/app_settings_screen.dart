import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../billing/pricing_visibility.dart';
import '../design/ab_carbon.dart';
import '../design/ab_colors.dart' show AbColors;
import '../design/ab_theme.dart' show paletteFor;
import '../design/theme_presets.dart';
import '../design/widgets/ab_toast.dart';
import '../models/pending_nav.dart';
import '../models/settings_section.dart';
import '../providers/agent_transport.dart';
import '../providers/auth.dart';
import '../providers/ui_attention_providers.dart';
import '../services/account_api.dart';
import '../services/app_settings_service.dart';
import '../util/detached.dart';
import '../widgets/carbon_confirm.dart';
import '../widgets/color_swatch_button.dart';
import '../widgets/delete_account_dialog.dart';
import '../widgets/sign_out_action.dart';
import 'upgrade_screen.dart';
import 'memory_screen.dart';

class _UiScaleStep {
  const _UiScaleStep(this.label, this.value);
  final String label;
  final double value;
}

const _uiScaleSteps = <_UiScaleStep>[
  _UiScaleStep('Compact', 0.85),
  _UiScaleStep('Default', 1.00),
  _UiScaleStep('Comfortable', 1.15),
  _UiScaleStep('Large', 1.30),
];

/// The widest the settings column grows; a form line longer than this stops
/// reading as one.
const double _kSettingsMaxWidth = 672;

/// The key [section]'s frame carries, and the handle a navigation scrolls to.
///
/// A [GlobalObjectKey] rather than a `GlobalKey` map held by the screen's
/// State, so the target can be named from outside that State — the enum value
/// IS the identity, so the same section yields an equal key on every rebuild.
/// Uniqueness holds because only one settings screen is ever mounted: AppShell
/// picks exactly one of the two routes that host it.
GlobalObjectKey settingsSectionKey(SettingsSection section) =>
    GlobalObjectKey(section);

extension SettingsSectionUI on SettingsSection {
  /// The section's header text. Lives beside the sections rather than on the
  /// model so display strings stay out of the model layer, and derived from the
  /// enum rather than written per call site so a header and the value that
  /// addresses it cannot drift apart.
  String get title => switch (this) {
    SettingsSection.billing => 'Billing',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.uiSize => 'UI size',
    SettingsSection.accessibility => 'Accessibility',
    SettingsSection.files => 'Files',
    SettingsSection.privacy => 'Privacy',
    SettingsSection.help => 'Help',
    SettingsSection.account => 'Account',
  };
}

class AppSettingsScreen extends ConsumerStatefulWidget {
  const AppSettingsScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  // A context under this screen's Carbon scope, which modals opened from here
  // must use: the State's own context sits above it.
  BuildContext? _scoped;

  @override
  void initState() {
    super.initState();
    // A link naming a section writes it before this screen exists — the surface
    // it also names is what mounts us — so the first frame is the first chance
    // to honour it. Post-frame: the sections need to be laid out before one can
    // be scrolled to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _drainPendingSettingsSection();
    });
  }

  /// Scroll to the section a navigation left in [pendingSettingsSectionProvider]
  /// and clear it, so a later mount cannot replay a spent link.
  ///
  /// A section stamped for another project is spent without scrolling: the
  /// settings surface belongs to the project it was opened over, and the user
  /// has since moved to a different one.
  void _drainPendingSettingsSection() {
    final pending = ref.read(pendingSettingsSectionProvider);
    if (pending == null) return;
    ref.read(pendingSettingsSectionProvider.notifier).set(null);
    if (pending.target != ref.read(selectedTargetProvider)) return;
    // Absent sections retain the codec's degrade-rather-than-reject contract,
    // including the old Help address now served by the account menu.
    final ctx = settingsSectionKey(pending.value).currentContext;
    if (ctx == null) return;
    unawaited(
      Scrollable.ensureVisible(
        ctx,
        duration: CarbonMotion.resolve(ctx, CarbonMotion.moderate02),
        // Header to the top of the viewport: a section is a block, and landing
        // on its first row reads as "here it is" where centring it does not.
        alignment: 0,
      ),
    );
  }

  Future<void> _deleteAccount() async {
    final scoped = _scoped;
    if (scoped == null) return;
    final confirmed = await DeleteAccountDialog.show(scoped);
    if (!confirmed || !mounted || !scoped.mounted) return;
    final (:result, :message) = await ref
        .read(accountApiProvider)
        .deleteAccount();
    if (!mounted || !scoped.mounted) return;
    switch (result) {
      case DeleteAccountResult.ok:
        // Full local teardown + provider invalidation; the root re-renders in
        // its signed-out state (sign-in screen on mobile).
        await hardSignOutFromUi(ref.container, AbToaster.maybeOf(scoped));
      case DeleteAccountResult.blockedBySubscription:
        final go = await showCarbonConfirm(
          scoped,
          title: 'Cancel your subscription first',
          body:
              'You have an active subscription. Cancel it before deleting your '
              'account. Subscriptions billed by the App Store or Google Play must '
              'also be cancelled in your store account.',
          confirmLabel: 'Manage subscription',
        );
        if (!mounted) return;
        if (go) await openManageSubscription(ref.container);
      case DeleteAccountResult.blockedByTeam:
        final go = await showCarbonConfirm(
          scoped,
          title: 'Remove your team members first',
          body:
              message ??
              'Your account still has team members. Remove them on the Team '
                  'page, or contact support to transfer ownership, before deleting '
                  'your account.',
          confirmLabel: 'Manage team',
        );
        if (!mounted) return;
        if (go) await openAccountInBrowser(ref.container, path: '/team');
      case DeleteAccountResult.blocked:
        // The web account page renders every block the server knows, including
        // ones newer than this build.
        final go = await showCarbonConfirm(
          scoped,
          title: "Account can't be deleted yet",
          body:
              message ??
              'Something on your account has to be resolved first. Your '
                  'account page says what it is.',
          confirmLabel: 'Open account',
        );
        if (!mounted) return;
        if (go) await openAccountInBrowser(ref.container);
      case DeleteAccountResult.error:
        showAbToast(
          scoped,
          'Could not delete account. Check your connection and try again.',
          clearPrevious: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsServiceProvider);
    final service = ref.read(appSettingsServiceProvider.notifier);

    // Links that land while this screen is already up (and back/forward over
    // them) drain here; the initState post-frame callback covers the mount.
    ref.listen<PendingNav<SettingsSection>?>(pendingSettingsSectionProvider, (
      _,
      next,
    ) {
      if (next == null) return;
      _drainPendingSettingsSection();
    });

    final palette = paletteFor(
      preset: settings.preset,
      customBg: settings.customBg,
      customPrimary: settings.customPrimary,
      customAccent: settings.customAccent,
    );

    void run(String what, Future<void> Function() action) =>
        detached('AppSettingsScreen', what, action);

    return AbCarbonScope(
      child: Builder(
        builder: (scoped) {
          _scoped = scoped;
          final t = CarbonTheme.of(scoped);
          final sections = <Widget>[
            if (kPricingSurfacesEnabled && defaultNativeUpgradePlatformCheck())
              _Section(
                section: SettingsSection.billing,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CarbonLink(
                      label: 'Pricing',
                      icon: const CarbonIcon(CarbonIcons.arrowRight),
                      onPressed: () => openUpgrade(scoped, ref.container),
                    ),
                  ),
                ],
              ),
            _Section(
              section: SettingsSection.appearance,
              children: [
                _FieldGroup(
                  label: 'Theme preset',
                  child: Wrap(
                    spacing: CarbonSpacing.spacing03,
                    runSpacing: CarbonSpacing.spacing03,
                    children: [
                      for (final preset in AbThemePreset.values)
                        _ChoiceTile(
                          label: preset.label,
                          selected: settings.preset == preset,
                          preview: preset == AbThemePreset.custom
                              ? palette
                              : (kPresets[preset] ?? kDefaultPalette),
                          onPressed: () => run(
                            'set preset',
                            () => preset == AbThemePreset.custom
                                ? service.setCustomColors(
                                    bg: settings.customBg ?? palette.bgDeepest,
                                    primary:
                                        settings.customPrimary ??
                                        palette.signalMut,
                                    accent:
                                        settings.customAccent ??
                                        palette.accent,
                                  )
                                : service.setPreset(preset),
                          ),
                        ),
                    ],
                  ),
                ),
                _SettingToggle(
                  title: 'Follow system light/dark',
                  caption:
                      'System light mode shows the Light preset; dark mode '
                      'shows your chosen preset.',
                  value: settings.followSystemBrightness,
                  onChanged: (v) => run(
                    'set follow system brightness',
                    () => service.setFollowSystemBrightness(v),
                  ),
                ),
                if (settings.preset == AbThemePreset.custom)
                  _FieldGroup(
                    label: 'Custom colors',
                    helper:
                        'Surface, border, and text are derived from these.',
                    child: Wrap(
                      spacing: CarbonSpacing.spacing03,
                      runSpacing: CarbonSpacing.spacing03,
                      children: [
                        ColorSwatchButton(
                          label: 'Background',
                          color: settings.customBg ?? palette.bgDeepest,
                          onChanged: (c) => run(
                            'set custom background',
                            () => service.setCustomColors(bg: c),
                          ),
                        ),
                        ColorSwatchButton(
                          label: 'Primary',
                          color: settings.customPrimary ?? palette.signalMut,
                          onChanged: (c) => run(
                            'set custom primary',
                            () => service.setCustomColors(primary: c),
                          ),
                        ),
                        ColorSwatchButton(
                          label: 'Accent',
                          color: settings.customAccent ?? palette.accent,
                          onChanged: (c) => run(
                            'set custom accent',
                            () => service.setCustomColors(accent: c),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonButton(
                label: 'Reset to defaults',
                kind: CarbonButtonKind.tertiary,
                onPressed: () => run('reset', service.reset),
              ),
            ),
            _Section(
              section: SettingsSection.uiSize,
              description:
                  'Scales text across the app. Spacing and row heights stay constant.',
              children: [
                Wrap(
                  spacing: CarbonSpacing.spacing03,
                  runSpacing: CarbonSpacing.spacing03,
                  children: [
                    for (final step in _uiScaleSteps)
                      _ChoiceTile(
                        label: step.label,
                        detail: '${step.value.toStringAsFixed(2)}×',
                        selected: settings.uiScale == step.value,
                        onPressed: () => run(
                          'set ui scale',
                          () => service.setUiScale(step.value),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            _Section(
              section: SettingsSection.accessibility,
              children: [
                _SettingToggle(
                  title: 'Reduce motion',
                  caption:
                      'Stops pulsing status dots and loading animations. '
                      'Indicators hold a static "busy" state instead.',
                  value: settings.reduceMotion,
                  onChanged: (v) => run(
                    'set reduce motion',
                    () => service.setReduceMotion(v),
                  ),
                ),
              ],
            ),
            _Section(
              section: SettingsSection.files,
              children: [
                _SettingToggle(
                  title: 'Hide git-ignored files',
                  caption:
                      'Applies to the file tree and its filter box — '
                      '@-mentions always skip ignored files, whatever '
                      'this is set to.',
                  value: settings.hideGitIgnoredFiles,
                  onChanged: (v) => run(
                    'set hide git-ignored files',
                    () => service.setHideGitIgnoredFiles(v),
                  ),
                ),
              ],
            ),
            _Section(
              section: SettingsSection.privacy,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: CarbonLink(
                    label: 'Manage machine memory',
                    icon: const CarbonIcon(CarbonIcons.arrowRight),
                    onPressed: () => openMemoryScreen(scoped, null),
                  ),
                ),
                _SettingToggle(
                  title: 'Allow terminal programs to copy text',
                  caption:
                      'Applies to this device. Explicit copy and paste remain available.',
                  value: settings.terminalProgramCopies,
                  onChanged: (v) => run(
                    'set terminal program copies',
                    () => service.setTerminalProgramCopies(v),
                  ),
                ),
                _SettingToggle(
                  title: 'Anonymous usage analytics',
                  caption: 'No code, files, or prompts — ever. Opt out anytime.',
                  value: settings.telemetryEnabled,
                  onChanged: (v) => run(
                    'set telemetry',
                    () => service.setTelemetryEnabled(v),
                  ),
                ),
              ],
            ),
            _Section(
              section: SettingsSection.account,
              children: [
                if (ref.watch(currentUserProvider).value != null)
                  _FieldGroup(
                    helper:
                        'Set or change your password on the web, where a '
                        'password change can re-check who you are and sign out '
                        'your other sessions.',
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: CarbonLink(
                        label: 'Manage password',
                        icon: const CarbonIcon(CarbonIcons.launch),
                        onPressed: () => run(
                          'open account page',
                          () => openAccountInBrowser(ref.container),
                        ),
                      ),
                    ),
                  ),
                _FieldGroup(
                  helper:
                      'Permanently delete your account and all associated data. '
                      'This cannot be undone.',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CarbonButton(
                      label: 'Delete account',
                      kind: CarbonButtonKind.dangerTertiary,
                      onPressed: () => run('delete account', _deleteAccount),
                    ),
                  ),
                ),
              ],
            ),
          ];
          return ColoredBox(
            color: t.colors.background,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsHeader(
                  onClose:
                      widget.onClose ?? () => Navigator.of(scoped).pop(),
                ),
                Expanded(
                  // Not a ListView: scroll-to-section resolves its target
                  // through the section's key context, and a lazy sliver has
                  // built no element for a section below the fold — null
                  // exactly for the sections a link is most useful for. A
                  // handful of cheap blocks is affordable eagerly.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: _kSettingsMaxWidth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < sections.length; i++) ...[
                              if (i > 0)
                                const SizedBox(height: CarbonSpacing.spacing07),
                              sections[i],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The surface's toolbar, the same shape as the Memory header. Phones get the
/// close button alone: settings has no drawer button of its own.
class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSubtle(1))),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: CarbonSizes.lg),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: CarbonSpacing.spacing05,
            end: CarbonSpacing.spacing03,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'App settings',
                    style: t.typography.heading.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                ),
              ),
              CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.close),
                semanticLabel: 'Close settings',
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One addressable block of the settings list: an unframed, titled section
/// whose key is derived from [section], so every section is reachable by a
/// `nav/settings?section=` link by construction rather than by remembering to
/// pass one. The key sits on this outermost widget, which is what a scroll to
/// the section measures.
class _Section extends StatelessWidget {
  _Section({required this.section, this.description, required this.children})
    : super(key: settingsSectionKey(section));

  final SettingsSection section;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CarbonFormSection(
    title: section.title,
    description: description,
    spacing: CarbonSpacing.spacing05,
    children: children,
  );
}

/// A control with an optional label above it and helper text below, in the
/// positions Carbon gives a form field's.
class _FieldGroup extends StatelessWidget {
  const _FieldGroup({this.label, this.helper, required this.child});

  final String? label;
  final String? helper;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: t.typography.label.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: CarbonSpacing.spacing03),
        ],
        child,
        if (helper != null) ...[
          const SizedBox(height: CarbonSpacing.spacing03),
          Text(
            helper!,
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// A Carbon stacked toggle: label above, the On/Off word beside the switch,
/// and the caption below. The label is part of the toggle's tap target.
class _SettingToggle extends StatelessWidget {
  const _SettingToggle({
    required this.title,
    required this.caption,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _FieldGroup(
    helper: caption,
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: CarbonToggle(
        labelText: title,
        value: value,
        onChanged: onChanged,
      ),
    ),
  );
}

/// One option of a single-choice setting, drawn as a Carbon selectable tile.
///
/// Each tile is its own tab stop and announces whether it is selected, so a
/// choice is never carried by the border colour alone: the selected tile also
/// carries a check mark. [preview] paints the preset's own colours as a strip
/// above the label.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.detail,
    this.preview,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onPressed;
  final AbColors? preview;

  static const double _width = 148;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final c = t.colors;
    return CarbonInteraction(
      onPressed: onPressed,
      label: label,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      excludeChildSemantics: true,
      builder: (context, state, _) {
        // A selected tile draws a thicker rule; the padding gives the extra
        // pixel back so the tile does not change size when selected.
        final border = selected ? 2.0 : 1.0;
        return CarbonFocusRing(
          visible: state.focusVisible,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: state.hovered ? c.layerHover01 : c.layer01,
              border: Border.all(
                color: selected ? c.borderInverse : c.borderTile01,
                width: border,
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: _width,
                maxWidth: _width,
                minHeight: t.minTarget,
              ),
              child: Padding(
                padding: EdgeInsets.all(CarbonSpacing.spacing04 - border + 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview case final p?) ...[
                      _PreviewStrip(p),
                      const SizedBox(height: CarbonSpacing.spacing03),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: t.typography.control.copyWith(
                              color: c.textPrimary,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (selected)
                          CarbonIcon(
                            CarbonIcons.checkmarkFilled,
                            size: 16,
                            color: c.iconPrimary,
                          ),
                      ],
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: CarbonSpacing.spacing01),
                      Text(
                        detail!,
                        style: t.typography.code.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The three colours that characterise a preset, side by side.
class _PreviewStrip extends StatelessWidget {
  const _PreviewStrip(this.colors);

  final AbColors colors;

  @override
  Widget build(BuildContext context) {
    final rule = CarbonTheme.of(context).borderSubtle(1);
    Widget swatch(Color color) => Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: rule),
        ),
        child: const SizedBox(height: CarbonSpacing.spacing05),
      ),
    );
    return Row(
      children: [
        swatch(colors.bgSurface),
        swatch(colors.accent),
        swatch(colors.signalMut),
      ],
    );
  }
}
