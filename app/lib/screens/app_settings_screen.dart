import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/theme_presets.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_theme.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_panel_header.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_tap_target.dart';
import '../design/widgets/ab_text_field.dart';
import '../providers/auth.dart';
import '../providers/sign_out.dart';
import '../services/account_api.dart';
import '../services/app_settings_service.dart';
import '../widgets/color_swatch_button.dart';
import '../widgets/delete_account_dialog.dart';
import '../widgets/settings/help_about_section.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import 'design_gallery_screen.dart';
import 'upgrade_screen.dart';

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

class AppSettingsScreen extends ConsumerStatefulWidget {
  const AppSettingsScreen({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  late final TextEditingController _relayCtrl;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(appSettingsServiceProvider).defaultRelayUrl ?? '';
    _relayCtrl = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _relayCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveRelayUrl(AppSettingsService service, String value) async {
    final error = await service.setDefaultRelayUrl(value);
    if (!mounted) return;
    showAbSnackBar(
      context,
      error ?? 'Saved default relay URL.',
      clearPrevious: true,
    );
  }

  Future<void> _deleteAccount() async {
    final confirmed = await DeleteAccountDialog.show(context);
    if (!confirmed || !mounted) return;
    final result = await ref.read(accountApiProvider).deleteAccount();
    if (!mounted) return;
    switch (result) {
      case DeleteAccountResult.ok:
        // Full local teardown + provider invalidation; the root re-renders in
        // its signed-out state (sign-in screen on mobile).
        await performHardSignOut(ref);
      case DeleteAccountResult.blockedBySubscription:
        final go = await AbConfirmDialog.show(
          context: context,
          title: 'Cancel your subscription first',
          body: 'You have an active subscription. Cancel it before deleting your '
              'account. Subscriptions billed by the App Store or Google Play must '
              'also be cancelled in your store account.',
          confirmLabel: 'Manage subscription',
        );
        if (!mounted) return;
        if (go) await openUpgradeInBrowser(ref.container);
      case DeleteAccountResult.error:
        showAbSnackBar(
          context,
          'Could not delete account. Check your connection and try again.',
          clearPrevious: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final settings = ref.watch(appSettingsServiceProvider);
    final service = ref.read(appSettingsServiceProvider.notifier);
    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    final palette = paletteFor(
      preset: settings.preset,
      customBg: settings.customBg,
      customPrimary: settings.customPrimary,
      customAccent: settings.customAccent,
    );

    return Scaffold(
      backgroundColor: antgrid.bgDeepest,
      body: Column(
        children: [
          AbPanelHeader(
            title: 'APP SETTINGS',
            actions: [
              AbIconButton(
                icon: AbIcons.close,
                onTap: widget.onClose ?? () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AbTokens.space12),
              children: [
                if (defaultNativeUpgradePlatformCheck()) ...[
                  _Section(
                    title: 'BILLING',
                    body: [
                      const SizedBox(height: AbTokens.space8),
                      InkWell(
                        onTap: () => openUpgrade(context, ref.container),
                        borderRadius: AbTokens.borderRadius,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AbTokens.space8,
                          ),
                          child: Row(
                            children: [
                              Text(
                                'Pricing',
                                style: AbTokens.monoStyle(
                                  color: antgrid.textPrimary,
                                ),
                              ),
                              const Spacer(),
                              AbIconButton(
                                icon: AbIcons.chevronRight,
                                onTap: () => openUpgrade(context, ref.container),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AbTokens.space12),
                ],
                if (!isNarrow) ...[
                  _Section(
                    title: 'CONNECTION',
                    body: [
                      const SizedBox(height: AbTokens.space8),
                      Text(
                        'Default relay URL — used when pairing via a URI that doesn\'t specify a relay.',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXxs,
                          color: antgrid.textMuted,
                        ),
                      ),
                      const SizedBox(height: AbTokens.space8),
                      AbTextField(
                        controller: _relayCtrl,
                        hintText: 'wss://relay.example.com',
                        onSubmitted: (v) => _saveRelayUrl(service, v),
                      ),
                      const SizedBox(height: AbTokens.space8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: AbButton(
                          label: 'SAVE URL',
                          onTap: () => _saveRelayUrl(service, _relayCtrl.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AbTokens.space12),
                ],
                _Section(
                  title: 'APPEARANCE',
                  body: [
                    const SizedBox(height: AbTokens.space8),
                    Text(
                      'Theme preset',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: antgrid.textMuted,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space8),
                    Wrap(
                      spacing: AbTokens.space8,
                      runSpacing: AbTokens.space8,
                      children: [
                        for (final preset in AbThemePreset.values)
                          _PresetTile(
                            preset: preset,
                            selected: settings.preset == preset,
                            caption:
                                settings.followSystemBrightness &&
                                    preset == AbThemePreset.light
                                ? 'used when system is light'
                                : null,
                            onTap: () => preset == AbThemePreset.custom
                                ? service.setCustomColors(
                                    bg: settings.customBg ?? palette.bgDeepest,
                                    primary:
                                        settings.customPrimary ??
                                        palette.signalMut,
                                    accent:
                                        settings.customAccent ?? palette.accent,
                                  )
                                : service.setPreset(preset),
                          ),
                      ],
                    ),
                    const SizedBox(height: AbTokens.space8),
                    _ToggleRow(
                      title: 'Follow system light/dark',
                      caption:
                          'System light mode shows the Light preset; dark mode '
                          'shows your chosen preset.',
                      enabled: settings.followSystemBrightness,
                      onTap: () => service.setFollowSystemBrightness(
                        !settings.followSystemBrightness,
                      ),
                    ),
                    if (settings.preset == AbThemePreset.custom) ...[
                      const SizedBox(height: AbTokens.space12),
                      Text(
                        'Custom colors — surface, border, and text are derived from these.',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXxs,
                          color: antgrid.textMuted,
                        ),
                      ),
                      const SizedBox(height: AbTokens.space8),
                      Wrap(
                        spacing: AbTokens.space8,
                        runSpacing: AbTokens.space8,
                        children: [
                          ColorSwatchButton(
                            label: 'BG',
                            color: settings.customBg ?? palette.bgDeepest,
                            onChanged: (c) => service.setCustomColors(bg: c),
                          ),
                          ColorSwatchButton(
                            label: 'PRIMARY',
                            color: settings.customPrimary ?? palette.signalMut,
                            onChanged: (c) =>
                                service.setCustomColors(primary: c),
                          ),
                          ColorSwatchButton(
                            label: 'ACCENT',
                            color: settings.customAccent ?? palette.accent,
                            onChanged: (c) =>
                                service.setCustomColors(accent: c),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                Align(
                  alignment: Alignment.centerRight,
                  child: AbButton(
                    label: 'RESET TO DEFAULTS',
                    onTap: () async {
                      await service.reset();
                      if (!mounted) return;
                      _relayCtrl.text = '';
                    },
                  ),
                ),
                const SizedBox(height: AbTokens.space12),
                _Section(
                  title: 'UI SIZE',
                  body: [
                    const SizedBox(height: AbTokens.space8),
                    Text(
                      'Scales text across the app. Spacing and row heights stay constant.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: antgrid.textMuted,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space8),
                    Wrap(
                      spacing: AbTokens.space8,
                      runSpacing: AbTokens.space8,
                      children: [
                        for (final step in _uiScaleSteps)
                          _UiScaleChip(
                            step: step,
                            selected: settings.uiScale == step.value,
                            onTap: () => service.setUiScale(step.value),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                _Section(
                  title: 'ACCESSIBILITY',
                  body: [
                    const SizedBox(height: AbTokens.space8),
                    _ToggleRow(
                      title: 'Reduce motion',
                      caption:
                          'Stops pulsing status dots and loading animations. '
                          'Indicators hold a static "busy" state instead.',
                      enabled: settings.reduceMotion,
                      onTap: () =>
                          service.setReduceMotion(!settings.reduceMotion),
                    ),
                  ],
                ),
                // Dev-only: the design gallery is a developer reference, not a
                // user-facing feature — keep it out of release builds.
                if (!kReleaseMode) ...[
                  const SizedBox(height: AbTokens.space12),
                  _Section(
                    title: 'DESIGN',
                    body: [
                      const SizedBox(height: AbTokens.space8),
                      AbButton(
                        label: 'Open design gallery',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DesignGalleryScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AbTokens.space12),
                _Section(
                  title: 'PRIVACY',
                  body: [
                    const SizedBox(height: AbTokens.space8),
                    _ToggleRow(
                      title: 'Anonymous usage analytics',
                      caption:
                          'No code, files, or prompts — ever. Opt out anytime.',
                      enabled: settings.telemetryEnabled,
                      onTap: () => service.setTelemetryEnabled(
                        !settings.telemetryEnabled,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                const _Section(
                  title: 'HELP',
                  body: [
                    SizedBox(height: AbTokens.space8),
                    HelpAboutSection(),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                _Section(
                  title: 'ACCOUNT',
                  body: [
                    const SizedBox(height: AbTokens.space8),
                    Text(
                      'Permanently delete your account and all associated data. '
                      'This cannot be undone.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: antgrid.textMuted,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: AbButton(
                        label: 'DELETE ACCOUNT',
                        color: antgrid.error,
                        onTap: _deleteAccount,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});
  final String title;
  final List<Widget> body;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return Container(
      padding: const EdgeInsets.all(AbTokens.space12),
      decoration: BoxDecoration(
        border: Border.all(color: antgrid.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AbTokens.sansStyle()),
          ...body,
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.onTap,
    this.caption,
  });

  final AbThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  /// Optional role hint under the preset name (e.g. the light preset's
  /// "used when system is light" while follow-system is on).
  final String? caption;

  AbColors _peek(BuildContext context) {
    if (preset == AbThemePreset.custom) {
      return context.antgrid;
    }
    return kPresets[preset] ?? kDefaultPalette;
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final p = _peek(context);
    final name = preset.name.toUpperCase();
    return InkWell(
      onTap: onTap,
      borderRadius: AbTokens.borderRadius8,
      child: Container(
        width: 130,
        padding: const EdgeInsets.all(AbTokens.space8),
        decoration: BoxDecoration(
          color: p.bgDeepest,
          border: Border.all(
            color: selected ? antgrid.accent : antgrid.borderDefault,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: AbTokens.borderRadius8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Swatch(color: p.bgSurface),
                const SizedBox(width: AbTokens.space4),
                _Swatch(color: p.accent),
                const SizedBox(width: AbTokens.space4),
                _Swatch(color: p.signalMut),
              ],
            ),
            const SizedBox(height: AbTokens.space8),
            Text(
              name,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: p.textPrimary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            if (caption != null) ...[
              const SizedBox(height: AbTokens.space2),
              Text(
                caption!,
                // Colored with the TILE's palette (not the ambient theme) so
                // the hint stays legible on the light preview surface.
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: p.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Full-width settings row: title + muted caption on the left, a
/// [_SettingsToggle] on the right; the whole row is the hit area. Vertical
/// space8 padding lifts the two-line row past [AbTokens.tapTargetMin] —
/// AbTapTarget's shrink-wrapping Center can't hold a Row with an Expanded,
/// so padding is the tap-target mechanism here.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.caption,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final String caption;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AbTokens.sansStyle(color: antgrid.textPrimary),
                  ),
                  const SizedBox(height: AbTokens.space2),
                  Text(
                    caption,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: antgrid.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AbTokens.space12),
            _SettingsToggle(enabled: enabled),
          ],
        ),
      ),
    );
  }
}

/// A compact on/off track+knob toggle built entirely from design-system
/// primitives. No Material Switch, no InkWell, no elevation or ripple.
/// Tapping is handled by the parent [_ToggleRow]'s GestureDetector.
class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({required this.enabled});

  final bool enabled;

  // Track dimensions — 28×16 matches a compact pill switch.
  static const _trackW = 28.0;
  static const _trackH = 16.0;
  static const _knobSize = 10.0;
  static const _knobPad = 3.0;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return AnimatedContainer(
      duration: AbTokens.motionSnap,
      width: _trackW,
      height: _trackH,
      decoration: BoxDecoration(
        // "on" = accent; "off" = elevated background with subtle border.
        color: enabled ? antgrid.accent : antgrid.bgElevated,
        border: enabled
            ? null
            : Border.all(color: antgrid.borderDefault),
        borderRadius: AbTokens.borderRadiusFull,
      ),
      child: Padding(
        padding: const EdgeInsets.all(_knobPad),
        child: Align(
          alignment: enabled ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: _knobSize,
            height: _knobSize,
            decoration: BoxDecoration(
              color: enabled ? antgrid.accentForeground : antgrid.textMuted,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _UiScaleChip extends StatelessWidget {
  const _UiScaleChip({
    required this.step,
    required this.selected,
    required this.onTap,
  });

  final _UiScaleStep step;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    // InkWell keeps the tap; AbTapTarget only guarantees the mobile-minimum
    // hit box in case a future restyle shrinks the chip below 44dp.
    return AbTapTarget(
      child: InkWell(
        onTap: onTap,
        borderRadius: AbTokens.borderRadius5,
        child: Container(
          width: 110,
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space10,
            vertical: AbTokens.space8,
          ),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? antgrid.accent : antgrid.borderDefault,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: AbTokens.borderRadius5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.label,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: antgrid.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: AbTokens.space2),
              Text(
                '${step.value.toStringAsFixed(2)}×',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: antgrid.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
