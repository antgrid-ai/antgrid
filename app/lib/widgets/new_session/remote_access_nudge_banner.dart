import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../launcher/host_control_client.dart';
import '../../providers/first_run.dart';
import '../../providers/remote_access.dart';
import '../../providers/remote_access_nudge.dart';
import '../remote_access_panel.dart' show confirmAndEnableRemoteAccess;

/// Remote-access nudge on the New Session canvas (desktop only), mounted
/// unconditionally under the top bar — it self-gates via
/// [remoteAccessNudgeProvider] (mobile / checklist visible / remote on /
/// dismissed ⇒ shrink), so the call site stays a single stable line.
///
/// The setup checklist it used to sit beneath is docked in the sidebar now
/// (`FirstRunSetupSection`); the "checklist visible" gate above is what still
/// keeps the two from saying "connect your phone" at the same time.
///
/// Two variants, one fact: the soft variant mentions remote control exists;
/// the device variant names the phone that signed in and offers the switch.
/// Enabling routes through [confirmAndEnableRemoteAccess] so the wording of
/// the grant never forks from the panel's.
class RemoteAccessNudgeBanner extends ConsumerWidget {
  const RemoteAccessNudgeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nudge = ref.watch(remoteAccessNudgeProvider);
    if (nudge == null) return const SizedBox.shrink();

    ref.listen<AsyncValue<RemoteAccessPolicy>>(remoteAccessPolicyProvider, (
      prev,
      next,
    ) {
      // Same voice as RemoteAccessControl's listener, carried here because
      // that one only lives while the title-bar chip is mounted — a failed
      // enable from this canvas must be voiced on this canvas. Transition-only,
      // so a retained error never re-toasts on rebuild. (Soft-nudge retirement
      // on enable is NOT here: a listener behind the visibility early-out above
      // misses enables performed while no nudge renders, so it lives in
      // confirmAndEnableRemoteAccess — the flow every enable routes through.)
      if (next is AsyncError && prev is! AsyncError) {
        showAbSnackBar(context, 'Could not update remote access. Try again.');
      }
    });

    // The device prompt supersedes the mention forever: retire the soft nudge
    // the moment the real prompt renders, so a later device revocation can't
    // fall back to it. Microtask because provider state must never be written
    // during build; container, not ref, because the microtask may outlive the
    // widget (same hazard as carrying a WidgetRef across an await).
    if (nudge is DeviceRemoteNudge &&
        !ref.read(firstRunProvider).nudgeSoftDismissed) {
      final container = ref.container;
      Future.microtask(
        // Synchronous state flip + fire-and-forget persist inside the
        // notifier; nothing here can throw.
        () => container.read(firstRunProvider.notifier).dismissNudgeSoft(),
      );
    }

    final t = context.antgrid;
    final message = switch (nudge) {
      SoftRemoteNudge() =>
        'Drive this machine from your phone — sign in there with this '
            'account, then turn on Remote here.',
      DeviceRemoteNudge(:final deviceName) =>
        '$deviceName signed in to your account. Turn on remote access to '
            'drive this machine from it.',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space8,
        ),
        decoration: BoxDecoration(
          color: t.bgSurface,
          border: Border.all(color: t.borderSubtle),
          borderRadius: BorderRadius.circular(AbTokens.radius8),
        ),
        child: Row(
          children: [
            // Same glyph as the title-bar chip — it reports the same fact.
            AbIcon(AbIcons.radioTower, size: 13, color: t.textMuted),
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: Text(
                message,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: t.textSecondary,
                ),
              ),
            ),
            if (nudge is DeviceRemoteNudge) ...[
              const SizedBox(width: AbTokens.space10),
              AbButton(
                label: 'Turn on',
                compact: true,
                // After a confirmed enable, policy.enabled flips true and the
                // nudge provider returns null — the banner unmounts on its
                // own, no extra state. context/ref are handed over
                // synchronously; the shared flow resolves the notifier before
                // its await.
                onTap: () => confirmAndEnableRemoteAccess(context, ref),
              ),
            ],
            // The soft variant deliberately has no action button: it is a
            // low-key mention, and the title-bar chip is the affordance it
            // points at.
            const SizedBox(width: AbTokens.space4),
            AbIconButton(
              icon: AbIcons.close,
              tone: AbIconButtonTone.muted,
              tooltip: nudge is DeviceRemoteNudge
                  ? "Dismiss — won't ask again on this machine"
                  : 'Dismiss',
              onTap: () {
                final n = ref.read(firstRunProvider.notifier);
                // Per-machine, because FirstRunStore is this install's local
                // storage — dismissing here never mutes another desktop.
                if (nudge is DeviceRemoteNudge) {
                  n.dismissNudgeDevice();
                } else {
                  n.dismissNudgeSoft();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
