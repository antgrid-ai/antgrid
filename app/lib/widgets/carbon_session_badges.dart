import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/session_entry.dart';
import '../providers/session_setup.dart'
    show SessionSetupPhase, sessionSetupPhase;
import 'session_deleting_badge.dart' show kSessionDeletingTip;
import 'session_isolation_badge.dart'
    show SessionCheckoutHealth, sessionCheckoutHealth, sessionIsIsolated, sessionIsolationTip;
import 'session_shared_workspace_badge.dart' show sharedWorkspaceTip;

// Carbon renderings of the markers the drawer, title bar and agent bar draw in
// the Ab design system. Each one owns its leading gap and renders nothing when
// it does not apply, so a row mounts them unconditionally. The gating and the
// tooltip copy come from the Ab files, so the two cannot describe one session
// differently.

const _gap = EdgeInsetsDirectional.only(start: CarbonSpacing.spacing03);

/// Whether an isolated session's provisioning run is what to report. A
/// workspace the bridge cannot reach outranks the setup run inside it.
bool _preparing(SessionCheckoutHealth health, SessionSetup? setup) =>
    health != SessionCheckoutHealth.unavailable &&
    sessionSetupPhase(setup) == SessionSetupPhase.running;

/// The isolation badge's state in words, for a row that names itself to a
/// screen reader and hides the badge's tooltip; null for a shared session.
String? sessionIsolationSpoken(SessionEntry session, SessionSetup? setup) {
  if (!sessionIsIsolated(session)) return null;
  final health = sessionCheckoutHealth(session.checkoutState);
  if (_preparing(health, setup)) return 'isolated, preparing its workspace';
  return health == SessionCheckoutHealth.unavailable
      ? 'isolated, workspace unavailable'
      : 'isolated';
}

/// Marks a session that runs somewhere other than the project root. A
/// provisioning run in flight shows the in-progress glyph rather than a second
/// marker: "isolated" and "not ready yet" are one workspace's identity and
/// state. No pulse; Carbon status glyphs are static.
class CarbonSessionIsolationBadge extends StatelessWidget {
  const CarbonSessionIsolationBadge({
    super.key,
    required this.session,
    this.setup,
  });

  final SessionEntry session;

  /// The live provisioning run, or null where the caller has no trustworthy
  /// account of one (a cached row carries none).
  final SessionSetup? setup;

  @override
  Widget build(BuildContext context) {
    if (!sessionIsIsolated(session)) return const SizedBox.shrink();
    final t = CarbonTheme.of(context);
    final health = sessionCheckoutHealth(session.checkoutState);
    final preparing = _preparing(health, setup);
    final Widget glyph = preparing
        ? CarbonIcon(
            CarbonIcons.inProgress,
            size: t.iconSize,
            color: t.colors.supportInfo,
          )
        : health == SessionCheckoutHealth.unavailable
        ? CarbonStatusIcon(CarbonStatusKind.warning, size: t.iconSize)
        : CarbonIcon(
            CarbonIcons.fork,
            size: t.iconSize,
            color: t.colors.iconSecondary,
          );
    return Padding(
      padding: _gap,
      child: CarbonTooltip(
        message: sessionIsolationTip(health, preparing),
        child: glyph,
      ),
    );
  }
}

/// Marks a session approved to bypass permission prompts. The label stays in
/// capitals because it is the product's own word for the mode.
class CarbonSessionApprovalBadge extends StatelessWidget {
  const CarbonSessionApprovalBadge({super.key, required this.session});

  final SessionEntry? session;

  @override
  Widget build(BuildContext context) {
    if (session?.approvalPolicy != 'bypass') return const SizedBox.shrink();
    return const Padding(
      padding: _gap,
      child: CarbonTag(
        key: Key('session-yolo-badge'),
        label: 'YOLO',
        color: CarbonTagColor.red,
        size: CarbonTagSize.small,
      ),
    );
  }
}

/// Marks a session whose directory another session is working in too.
class CarbonSessionSharedWorkspaceBadge extends StatelessWidget {
  const CarbonSessionSharedWorkspaceBadge({super.key, required this.session});

  final SessionEntry session;

  @override
  Widget build(BuildContext context) {
    if (!session.sharedWorkspace) return const SizedBox.shrink();
    final t = CarbonTheme.of(context);
    // The bridge floors the count at 1, so an older bridge that sets the flag
    // and omits the number lands here at zero others.
    final others = session.workspaceMemberCount - 1;
    return Padding(
      padding: _gap,
      child: CarbonTooltip(
        message: sharedWorkspaceTip(others),
        child: CarbonIcon(
          CarbonIcons.folderShared,
          size: t.iconSize,
          color: t.colors.iconSecondary,
        ),
      ),
    );
  }
}

/// Marks a session being removed right now. Neutral, not an error: this is a
/// normal operation in progress.
class CarbonSessionDeletingBadge extends StatelessWidget {
  const CarbonSessionDeletingBadge({super.key, required this.deleting});

  final bool deleting;

  @override
  Widget build(BuildContext context) {
    if (!deleting) return const SizedBox.shrink();
    return const Padding(
      padding: _gap,
      child: CarbonTooltip(
        message: kSessionDeletingTip,
        child: CarbonTag(label: 'Deleting', size: CarbonTagSize.small),
      ),
    );
  }
}
