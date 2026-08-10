import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_switch.dart';
import '../design/widgets/ab_tooltip.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../launcher/host_control_client.dart';
import '../providers/device_provisioning.dart';
import '../providers/first_run.dart';
import '../providers/remote_access.dart';
import '../services/devices_api.dart';
import '../util/relative_time.dart';

/// The machine-wide remote-access switch, what it grants, and the roster of
/// devices that have connected — the panel behind the title-bar chip.
///
/// One surface for all three because they are one question. The switch alone
/// can't say what it admits; the roster alone reads as an access list, which it
/// is not — access is machine-wide, so a row is identity and housekeeping only
/// (who it is, when it last connected, and the one way to cut it off).
///
/// Turning access ON is confirmed and turning it OFF is not, on purpose: the
/// two directions carry opposite risk. Granting every account device the whole
/// machine is worth one sentence of friction; withdrawing that grant should
/// never be slower than the fear that prompted it.
///
/// The two levers here cut at different scopes, and neither substitutes for the
/// other: the switch is THIS machine for ALL devices and reverses in a tap;
/// signing a device out is THAT device across EVERY machine and holds until it
/// signs in again.
class RemoteAccessPanel extends ConsumerWidget {
  const RemoteAccessPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AccessSection(),
        Container(height: 1, color: p.borderSubtle),
        const _DevicesSection(),
      ],
    );
  }
}

/// The one confirm-then-enable flow for machine-wide remote access. Reused by
/// the panel switch below and the New Session remote-access nudge — the wording
/// of this grant must never fork.
///
/// Resolves the notifier (and captures the container) BEFORE the dialog: the
/// caller's element can die while the dialog is up (popup panel dismissed,
/// canvas rebuild), and a WidgetRef read after an await would then throw.
Future<void> confirmAndEnableRemoteAccess(
  BuildContext context,
  WidgetRef ref,
) async {
  final container = ref.container;
  final notifier = ref.read(remoteAccessPolicyProvider.notifier);
  final ok = await AbConfirmDialog.show(
    context: context,
    title: 'Turn on remote access?',
    body:
        'Every device signed in to your account will be able to open and '
        'drive every project on this machine, until you turn it off.',
    confirmLabel: 'Turn on',
  );
  if (!ok) return;
  await notifier.setEnabled(true);
  // Once remote access has been on — from ANY surface — the one-time soft
  // nudge has served its purpose and must never resurrect after a later
  // disable. Latched here, in the flow every enable routes through, because a
  // widget-side listener only exists while its surface happens to be mounted.
  // `setEnabled` reports failure as error STATE (retaining the prior value),
  // so a failed enable reads false here and correctly leaves the nudge alive.
  if (container.read(remoteAccessPolicyProvider).value?.enabled == true) {
    container.read(firstRunProvider.notifier).dismissNudgeSoft();
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// The switch
// ──────────────────────────────────────────────────────────────────────────────

class _AccessSection extends ConsumerWidget {
  const _AccessSection();

  Future<void> _set(BuildContext context, WidgetRef ref, bool next) async {
    if (next) {
      await confirmAndEnableRemoteAccess(context, ref);
      return;
    }
    await ref.read(remoteAccessPolicyProvider.notifier).setEnabled(false);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final async = ref.watch(remoteAccessPolicyProvider);
    final policy = async.value;
    final enabled = policy?.enabled == true;
    // Inert until the machine's real state is known: a switch with nothing
    // behind it would invite a tap that writes a value the user never saw.
    // Same reason a flip in flight locks it — one flip at a time.
    final live = policy != null && !async.isLoading;

    final control = AbSwitch(
      key: const Key('remote-access-switch'),
      value: enabled,
      semanticLabel: 'Remote access',
      // Green, not accent: this reports a machine that is on the air, and it
      // has to agree with the title-bar chip that reports the same fact.
      tone: p.statusRunning,
      onChanged: live ? (next) => _set(context, ref, next) : null,
    );

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'REMOTE ACCESS',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    letterSpacing: 0.66,
                    color: p.textMuted,
                  ),
                ),
              ),
              async.isLoading ? PulsingOpacity(child: control) : control,
            ],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            policy == null
                ? "Couldn't read this machine's setting. It stays as it was."
                : 'Any device signed in to your account — phone, tablet or '
                      'another desktop — can open and drive every project on '
                      'this machine.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: policy == null ? p.error : p.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Device roster
// ──────────────────────────────────────────────────────────────────────────────

class _DevicesSection extends ConsumerWidget {
  const _DevicesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final async = ref.watch(remoteDevicesProvider);
    // A mutation keeps the prior data (copyWithPrevious in the notifier), so a
    // forget never blanks the roster to a spinner.
    final phones = async.value?.phones ?? const <PairedPhoneSummary>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space8,
        AbTokens.space8,
        AbTokens.space8,
        AbTokens.space6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            phones.isEmpty ? 'DEVICES' : 'DEVICES · ${phones.length}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              letterSpacing: 0.66,
              color: p.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space4),
          if (async.hasError && phones.isEmpty)
            _Note(
              text: "Couldn't load this machine's devices.",
              color: p.error,
              action: AbButton(
                label: 'Retry',
                compact: true,
                onTap: () => ref.invalidate(remoteDevicesProvider),
              ),
            )
          else if (phones.isEmpty)
            // No CTA: there is nothing to do here. A device signed in to this
            // account admits itself on first connect, so the only instruction
            // is where to go and sign in.
            _Note(
              text:
                  'None yet. Sign in to Antgrid on your phone or another '
                  'desktop and it shows up here.',
              color: p.textMuted,
            )
          else
            // Bounded so a machine with many devices scrolls the roster instead
            // of growing the popup past the screen.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 208),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: phones.length,
                itemBuilder: (_, i) => _DeviceRow(phone: phones[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerStatefulWidget {
  const _DeviceRow({required this.phone});
  final PairedPhoneSummary phone;

  @override
  ConsumerState<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends ConsumerState<_DeviceRow> {
  bool _busy = false;

  PairedPhoneSummary get phone => widget.phone;

  /// The bridge never learns a device's name — nothing writes `PairedPhone.label`,
  /// because admission carries an identity, not a profile. The name the user
  /// actually chose lives on the ACCOUNT device record, which is why the join
  /// through [accountDevicesByBridgeIdProvider] is what makes this row readable
  /// at all. Falling back to a truncated id keeps the row scannable when the
  /// account is unreachable; the full id stays one line down.
  String _nameFor(DeviceSummary? account) =>
      account?.displayName ?? phone.label ?? _shortId(phone.phoneDeviceId);

  /// Revoke the ACCOUNT device, then drop the local record.
  ///
  /// Order matters and so does the pairing. Revoking alone leaves a row for a
  /// device that can no longer connect; clearing alone is theatre, because
  /// admission is account trust and the row rebuilds itself on the next hello.
  /// The local clear is best-effort — a failed one leaves a stale row, which is
  /// cosmetic, while a failed revoke means access is still live and must be
  /// said out loud.
  Future<void> _signOut(DeviceSummary account) async {
    final devices = ref.read(devicesApiProvider);
    final roster = ref.read(remoteDevicesProvider.notifier);
    final name = _nameFor(account);
    final ok = await AbConfirmDialog.show(
      context: context,
      title: 'Sign out $name?',
      body:
          'It loses access to every machine on your account, not just this '
          'one, until you sign in on it again.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final revoked = await devices.revoke(account.id);
    if (revoked) await roster.unpair(phonePubkey: phone.phonePubkey);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!revoked) {
      showAbSnackBar(context, "Couldn't sign $name out. It still has access.");
    }
  }

  /// Drop a local record with no account device behind it. Honest here and
  /// only here: there is nothing left to revoke, so clearing IS the whole
  /// remedy rather than a stand-in for one.
  Future<void> _forget() async {
    final roster = ref.read(remoteDevicesProvider.notifier);
    setState(() => _busy = true);
    await roster.unpair(phonePubkey: phone.phonePubkey);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Three states, not two. Until the account inventory resolves we cannot
    // tell "still signed in" from "already gone", and the two take opposite
    // actions — so the row waits rather than guessing a label.
    final accounts = ref.watch(accountDevicesByBridgeIdProvider).value;
    final account = accounts?[phone.phoneDeviceId];
    final named = account?.displayName ?? phone.label;

    return AbListRow(
      key: ValueKey('device-${phone.phonePubkey}'),
      density: AbRowDensity.sm,
      horizontalPadding: 0,
      leading: AbIcon(
        _glyphFor(account?.platform),
        size: 13,
        color: p.textMuted,
      ),
      title: Text(
        _nameFor(account),
        overflow: TextOverflow.ellipsis,
        // A human name is chrome (sans); the id we fall back to is data (mono).
        style: named != null
            ? AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textPrimary,
                fontWeight: FontWeight.w500,
              )
            : AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: p.textPrimary,
              ),
      ),
      subtitle: Text(
        _lastSeen(),
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXxs,
          color: p.textMuted,
        ),
      ),
      // Icon, not a labelled button: the row's job is to name a device, and a
      // word-wide action next to a name that can run long is the first thing to
      // squeeze it. What the glyph costs in explicitness the tooltip and the
      // confirm both repay — and neither action lands without a confirm.
      trailing: switch ((accounts, account)) {
        // Until the account inventory resolves we cannot tell "still signed in"
        // from "already gone", and the two do different things — so the row
        // waits rather than firing whichever we guessed.
        (null, _) => AbTooltip(
          message: 'Checking which devices are still on your account…',
          child: AbIconButton(
            key: ValueKey('signout-${phone.phonePubkey}'),
            icon: AbIcons.trash,
            tone: AbIconButtonTone.muted,
            onTap: null,
          ),
        ),
        (_, final DeviceSummary a) => AbIconButton(
          key: ValueKey('signout-${phone.phonePubkey}'),
          icon: AbIcons.trash,
          tone: AbIconButtonTone.danger,
          tooltip:
              'Sign out — revokes this device on your account, on every '
              'machine, not just here',
          onTap: _busy ? null : () => _signOut(a),
        ),
        _ => AbIconButton(
          key: ValueKey('forget-${phone.phonePubkey}'),
          icon: AbIcons.trash,
          tone: AbIconButtonTone.muted,
          tooltip:
              'Forget — this device is no longer on your account; clears the '
              'record it left behind',
          onTap: _busy ? null : _forget,
        ),
      },
    );
  }

  /// `last seen 2 mins ago`, or the raw stamp if the bridge sent something we
  /// can't parse — an unreadable timestamp is still more use than dropping the
  /// line, which is the only thing distinguishing two same-model devices.
  String _lastSeen() {
    final at = DateTime.tryParse(phone.lastSeenAt);
    return 'last seen ${at == null ? phone.lastSeenAt : relativeTime(at.toLocal())}';
  }
}

/// Platform strings come from the account record (`DeviceSummary.platform`),
/// written at provisioning by each client. Unknown falls to the phone glyph:
/// the roster's overwhelming case is a phone, and a wrong guess here is
/// cosmetic — the name below it is what identifies the device.
String _glyphFor(String? platform) => switch (platform?.toLowerCase()) {
  'macos' || 'windows' || 'linux' => AbIcons.deviceDesktop,
  _ => AbIcons.deviceMobile,
};

String _shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// One-line explanation and, where there is one, its single action — the empty
/// and error bodies, kept compact so the popup doesn't grow a full-screen
/// empty state.
class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, this.action});

  final String text;
  final Color color;

  /// Omitted when the state has no remedy the user can act on here.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: AbTokens.sansStyle(fontSize: AbTokens.fontXxs, color: color),
        ),
        if (action != null) ...[
          const SizedBox(height: AbTokens.space6),
          Align(alignment: Alignment.centerLeft, child: action!),
        ],
      ],
    );
  }
}
