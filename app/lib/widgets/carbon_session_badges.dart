import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../providers/agent_transport.dart' show selectedRegistrationIdProvider;
import '../providers/memory.dart';
import '../providers/open_checkout.dart';
import '../providers/providers.dart';
import '../providers/session_setup.dart'
    show SessionSetupPhase, sessionSetupPhase;
import 'session_deleting_badge.dart' show kSessionDeletingTip;
import 'session_isolation_badge.dart'
    show SessionCheckoutHealth, sessionCheckoutHealth, sessionIsIsolated, sessionIsolationTip;
import 'session_shared_workspace_badge.dart' show sharedWorkspaceTip;

// Carbon renderings of the markers the drawer, title bar and agent bar draw in
// the Ab design system. Each one owns its leading gap and renders nothing when
// it does not apply, so a row mounts them unconditionally. Where an Ab twin
// exists its gating and tooltip copy are shared, so the two cannot describe one
// session differently.

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

/// How many answers Handler is waiting on in one session, for the focused
/// project only.
///
/// `handlerStateProvider` follows project focus, so a row belonging to another
/// project would be answered out of this project's sessions: a count attached
/// to the wrong name, which is worse than no count. The row where a user picks
/// a session is the only place a session that is not in focus can name itself.
int watchSessionHandlerPending(
  WidgetRef ref,
  String entryId,
  String sessionId,
) {
  if (ref.watch(selectedRegistrationIdProvider) != entryId) return 0;
  return ref.watch(
    handlerStateProvider.select(
      (s) => s.value?.sessions[sessionId]?.pendingEscalations ?? 0,
    ),
  );
}

/// Whether a running local session was launched before Memory was turned on, so
/// it has none until it restarts.
///
/// Local only: the Memory status that gates it is read from this machine's own
/// host, and a remote row would be judged against the wrong machine's setting.
/// Both providers are watched only for a flagged row, so the common case costs
/// no request.
bool watchSessionStartedWithoutMemory(
  WidgetRef ref,
  String entryId,
  SessionEntry session,
) =>
    session.startedWithoutMemory &&
    session.running &&
    ref.watch(entryIsLocalCheckoutProvider(entryId)).value == true &&
    ref.watch(memoryDrawerEnabledProvider).value == true;

String handlerPendingTip(int pending) => pending == 1
    ? 'Handler is waiting on an answer in this session.'
    : 'Handler is waiting on $pending answers in this session.';

const String kSessionMemoryRestartTip =
    'Started before Memory was turned on. Restart to use Memory.';

/// The number of answers Handler is waiting on in a session. A bare count in
/// the interactive blue: the count is the actionable part and the tooltip
/// carries the sentence.
class CarbonSessionHandlerBadge extends ConsumerWidget {
  const CarbonSessionHandlerBadge({
    super.key,
    required this.entryId,
    required this.sessionId,
  });

  /// The project the row belongs to, not the focused one.
  final String entryId;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = watchSessionHandlerPending(ref, entryId, sessionId);
    if (pending == 0) return const SizedBox.shrink();
    return Padding(
      padding: _gap,
      child: CarbonTooltip(
        message: handlerPendingTip(pending),
        child: CarbonTag(
          label: '$pending',
          color: CarbonTagColor.blue,
          size: CarbonTagSize.small,
        ),
      ),
    );
  }
}

/// Marks a running local session that has no Memory until it restarts.
class CarbonSessionMemoryRestartBadge extends ConsumerWidget {
  const CarbonSessionMemoryRestartBadge({
    super.key,
    required this.entryId,
    required this.session,
  });

  final String entryId;
  final SessionEntry session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!watchSessionStartedWithoutMemory(ref, entryId, session)) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: _gap,
      child: CarbonTooltip(
        message: kSessionMemoryRestartTip,
        child: CarbonTag(
          label: 'No Memory',
          color: CarbonTagColor.gray,
          size: CarbonTagSize.small,
        ),
      ),
    );
  }
}
