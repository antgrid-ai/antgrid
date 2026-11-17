import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/pulse_builder.dart';
import '../models/agent_work_status.dart';
import 'agent_work_status_indicator.dart';
import 'recent_sessions/recent_sessions_summary.dart' show workStatusLabel;

/// Smallest scale of a pulsing dot. Opacity alone barely moves on a mid-tone
/// colour, so the dot also breathes in size; it is paint-time only and never
/// reflows its row.
const double _pulseMinScale = 0.7;

/// A filled dot, or a ring filled with the surface so whatever is behind it
/// does not show through. Not a Carbon component: the indicator glyphs are too
/// large to sit in a dense row.
///
/// [pulse] is an app-level addition for "something is happening or wants you"
/// dots; it is off under reduced motion. Without a [semanticLabel] the dot is
/// decoration and is excluded from semantics.
class CarbonStatusDot extends StatelessWidget {
  const CarbonStatusDot({
    super.key,
    required this.color,
    this.hollow = false,
    this.pulse = false,
    this.size,
    this.semanticLabel,
    this.hollowFill,
  });

  final Color color;
  final bool hollow;
  final bool pulse;

  /// Diameter. Defaults to 8; a touch surface passes 10.
  final double? size;

  final String? semanticLabel;

  /// What a hollow ring is filled with. Defaults to the enclosing layer, which
  /// suits a dot overlaid on a mark; a surface that is not a layer passes its
  /// own fill so the ring does not read as a disc.
  final Color? hollowFill;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final dimension = size ?? CarbonSpacing.spacing03;
    Widget dot = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? (hollowFill ?? t.layer(CarbonLayer.of(context))) : color,
        border: hollow ? Border.all(color: color) : null,
      ),
      child: SizedBox.square(dimension: dimension),
    );
    if (pulse && !CarbonMotion.reduced(context)) {
      dot = PulseBuilder(
        builder: (context, value, child) => Transform.scale(
          scale: _pulseMinScale + (1 - _pulseMinScale) * value,
          child: Opacity(opacity: 0.45 + 0.55 * value, child: child),
        ),
        child: dot,
      );
    }
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: dot);
    return Semantics(label: label, container: true, excludeSemantics: true, child: dot);
  }
}

/// The work-status dot in Carbon support colours. Only `done` is a ring, so it
/// stays distinguishable from the live states without relying on its grey.
class CarbonWorkStatusDot extends StatelessWidget {
  const CarbonWorkStatusDot({
    super.key,
    required this.status,
    this.pulse = false,
    this.size,
    this.semanticLabel,
    this.hollowFill,
  });

  final AgentWorkStatus status;
  final bool pulse;
  final double? size;
  final String? semanticLabel;
  final Color? hollowFill;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return CarbonStatusDot(
      color: agentWorkStatusDotColor(t, status) ?? t.colors.iconSecondary,
      hollow: agentWorkStatusDotHollow(status),
      pulse: pulse,
      size: size,
      semanticLabel: semanticLabel,
      hollowFill: hollowFill,
    );
  }
}

/// How reachable a machine or host is, as the drawer draws it.
enum DrawerLiveness { connected, connecting, failed, offline }

/// A machine or host liveness dot: green when up, a pulsing blue while
/// connecting, red on failure, and a hollow ring when offline.
class CarbonLivenessDot extends StatelessWidget {
  const CarbonLivenessDot({
    super.key,
    required this.liveness,
    this.size,
    required this.semanticLabel,
    this.hollowFill,
  });

  final DrawerLiveness liveness;
  final double? size;
  final String semanticLabel;
  final Color? hollowFill;

  @override
  Widget build(BuildContext context) {
    final c = CarbonTheme.of(context).colors;
    return switch (liveness) {
      DrawerLiveness.connected => CarbonStatusDot(
        color: c.supportSuccess,
        size: size,
        semanticLabel: semanticLabel,
      ),
      DrawerLiveness.connecting => CarbonStatusDot(
        color: c.supportInfo,
        pulse: true,
        size: size,
        semanticLabel: semanticLabel,
      ),
      DrawerLiveness.failed => CarbonStatusDot(
        color: c.supportError,
        size: size,
        semanticLabel: semanticLabel,
      ),
      DrawerLiveness.offline => CarbonStatusDot(
        color: c.iconSecondary,
        hollow: true,
        size: size,
        semanticLabel: semanticLabel,
        hollowFill: hollowFill,
      ),
    };
  }
}

/// A session row's whole accessible name for a surface whose content is
/// excluded from semantics: the name, status, then every fact the row shows.
///
/// [agent], [originText], [isolation] and the [extras] are skipped when null
/// or empty so each surface lists only what it draws.
String sessionSpokenName({
  required String name,
  required AgentWorkStatus status,
  String? agent,
  String? originText,
  String? relTime,
  bool bypassesApprovals = false,
  String? isolation,
  bool sharedWorkspace = false,
  bool deleting = false,
  List<String> extras = const [],
}) {
  return [
    name,
    workStatusLabel(status),
    if (agent != null && agent.isNotEmpty) agent,
    if (originText != null && originText.isNotEmpty) originText,
    if (relTime != null && relTime.isNotEmpty) relTime,
    if (bypassesApprovals) 'bypasses approvals',
    if (isolation != null && isolation.isNotEmpty) isolation,
    if (sharedWorkspace) 'shared workspace',
    if (deleting) 'deleting',
    ...extras,
  ].join(', ');
}
