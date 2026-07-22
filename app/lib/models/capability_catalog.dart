import 'agent_event.dart';

/// The STATIC portion of an agent's capabilities — the models/modes/commands
/// catalog, minus the per-session `current*` selection ids. Static per
/// (machine, tool), so it is cached and replayed into the NEXT session's
/// composer for that tool, killing the re-discovery spinner. The live
/// `agent:capabilities` frame always overrides once it lands
/// (see [resolveComposerCapabilities]).
class CapabilityCatalog {
  final List<AgentCapabilityModel> models;
  final List<AgentCapabilityMode> modes;
  final List<AgentCapabilityCommand> commands;

  const CapabilityCatalog({
    this.models = const [],
    this.modes = const [],
    this.commands = const [],
  });

  bool get isEmpty => models.isEmpty && modes.isEmpty && commands.isEmpty;

  /// Extract the static catalog from a live frame, dropping every `current*` id.
  factory CapabilityCatalog.fromCapabilities(AgentCapabilities c) =>
      CapabilityCatalog(
        models: c.models,
        modes: c.modes,
        commands: c.commands,
      );

  Map<String, dynamic> toJson() => {
        'models': [
          for (final m in models)
            {
              'id': m.id,
              'name': m.name,
              if (m.provider != null) 'provider': m.provider,
              if (m.efforts.isNotEmpty) 'efforts': m.efforts,
              if (m.defaultEffort != null) 'defaultEffort': m.defaultEffort,
            },
        ],
        'modes': [
          for (final m in modes)
            {
              'id': m.id,
              'name': m.name,
              if (m.description != null) 'description': m.description,
            },
        ],
        'commands': [
          for (final c in commands)
            {
              'id': c.id,
              'name': c.name,
              if (c.description != null) 'description': c.description,
              if (c.argHint != null) 'argHint': c.argHint,
            },
        ],
      };

  factory CapabilityCatalog.fromJson(Map<String, dynamic> json) =>
      CapabilityCatalog(
        models: _list(
          json['models'],
          (m) => AgentCapabilityModel(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            provider: m['provider'] as String?,
            efforts: m['efforts'] is List
                ? (m['efforts'] as List).whereType<String>().toList()
                : const [],
            defaultEffort: m['defaultEffort'] as String?,
          ),
        ),
        modes: _list(
          json['modes'],
          (m) => AgentCapabilityMode(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            description: m['description'] as String?,
          ),
        ),
        commands: _list(
          json['commands'],
          (c) => AgentCapabilityCommand(
            id: c['id'] as String? ?? '',
            name: c['name'] as String? ?? '',
            description: c['description'] as String?,
            argHint: c['argHint'] as String?,
          ),
        ),
      );

  static List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) f) =>
      raw is List
          // whereType<Map>() then copy — a Map<dynamic,dynamic> (from test
          // fixtures or non-jsonDecode sources) would be dropped by a direct
          // whereType<Map<String,dynamic>>().
          ? raw
              .whereType<Map>()
              .map((e) => f(Map<String, dynamic>.from(e)))
              .toList()
          : <T>[];
}

/// Merge a live capabilities frame with a cached catalog for the composer.
/// A `ready` live frame always wins — it is authoritative, so an empty model
/// list means the machine genuinely offers nothing and the stale cache must
/// NOT be resurrected under it (that would let the user pick a model the agent
/// no longer has). Only while the live frame is still loading do we overlay the
/// cached catalog under whatever `current*` ids it carries and mark `ready:true`
/// so the composer shows the selectors instead of the discovery spinner.
/// Returns the live frame unchanged (possibly null/loading) when there is
/// nothing cached to fall back on.
AgentCapabilities? resolveComposerCapabilities({
  required AgentCapabilities? live,
  required CapabilityCatalog? cached,
}) {
  final l = live;
  if (l != null && l.ready) return l;
  if (cached == null || cached.isEmpty) return l;
  return AgentCapabilities(
    sessionId: l?.sessionId ?? '',
    ready: true,
    models: cached.models,
    modes: cached.modes,
    commands: cached.commands,
    currentModelId: l?.currentModelId,
    currentModeId: l?.currentModeId,
    currentEffortId: l?.currentEffortId,
  );
}
