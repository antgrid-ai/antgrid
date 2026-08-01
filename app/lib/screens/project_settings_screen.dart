import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_panel_header.dart';
import '../models/ab_config.dart';
import '../providers/providers.dart';
import '../services/app_settings_service.dart';
import '../services/config_service.dart';

class ProjectSettingsScreen extends ConsumerStatefulWidget {
  const ProjectSettingsScreen({super.key});

  @override
  ConsumerState<ProjectSettingsScreen> createState() =>
      _ProjectSettingsScreenState();
}

class _ProjectSettingsScreenState extends ConsumerState<ProjectSettingsScreen> {
  AbConfig? _draft;
  List<DetectedTool> _detected = const [];
  String? _saveError;
  bool _saving = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: errors are routed into _saveError (and an empty draft is
    // shown) so a read/detect failure surfaces instead of stranding the loading
    // spinner forever.
    unawaited(_load());
  }

  Future<void> _load() async {
    // Nullable rather than through the throwing façade: the focused project's
    // session can be unresolved when this screen mounts (deep-linked focus) or
    // be invalidated mid-load (host restart, LRU evict). This runs
    // fire-and-forget from initState, so a throw here lands as an unhandled
    // error instead of the inline failure below.
    final svc = focusedServiceOrNull(ref.container, (s) => s.configService);
    if (svc == null) {
      _failLoad('This project is not connected.');
      return;
    }
    try {
      final results = await Future.wait([svc.read(), svc.detectTools()]);
      if (!mounted) return;
      setState(() {
        // A null read means the agent answered and has no usable config, so an
        // empty draft is the right starting point. A lost reply throws instead.
        _draft = (results[0] as AbConfig?) ?? const AbConfig();
        _detected = results[1] as List<DetectedTool>;
      });
    } catch (e) {
      _failLoad('Failed to load settings: $e');
    }
  }

  /// Render the form so the failure is visible instead of an endless spinner,
  /// but keep Save locked: this draft is a placeholder, not the project's
  /// config, and writing it would clobber the real antgrid.yaml.
  void _failLoad(String message) {
    if (!mounted) return;
    setState(() {
      _draft ??= const AbConfig();
      _loadFailed = true;
      _saveError = message;
    });
  }

  Future<void> _save() async {
    if (_draft == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    // `save()` returns a future that can complete with an *error* (e.g. the
    // ConfigService is disposed mid-write, or a superseding write), not just a
    // value. The finally guarantees `_saving` resets so the Save button can't
    // strand on a disabled "Saving…" state.
    try {
      final svc = focusedServiceOrNull(ref.container, (s) => s.configService);
      if (svc == null) {
        setState(() => _saveError = 'This project is not connected.');
        return;
      }
      final errors = await svc.save(_draft!);
      if (!mounted) return;
      setState(() => _saveError = errors?.join('\n'));
      if (errors == null && mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    if (draft == null) {
      return const Scaffold(body: Center(child: AbLoading()));
    }
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: Column(
        children: [
          AbPanelHeader(
            title: 'PROJECT SETTINGS',
            actions: [
              AbIconButton(
                icon: AbIcons.close,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AbTokens.space12),
              children: [
                _AgentSection(
                  draft: draft,
                  detected: _detected,
                  onChanged: (next) => setState(() => _draft = next),
                ),
                const SizedBox(height: AbTokens.space12),
                _CommandsSection(
                  draft: draft,
                  onChanged: (next) => setState(() => _draft = next),
                ),
                const SizedBox(height: AbTokens.space12),
                _PortsSection(
                  draft: draft,
                  onChanged: (next) => setState(() => _draft = next),
                ),
                const SizedBox(height: AbTokens.space12),
                if (_saveError != null) ...[
                  const SizedBox(height: AbTokens.space8),
                  Text(
                    _saveError!,
                    style: AbTokens.sansStyle().copyWith(
                      color: Colors.redAccent,
                    ),
                  ),
                ],
                const SizedBox(height: AbTokens.space12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AbButton(
                      label: _saving ? 'Saving…' : 'Save',
                      onTap: _saving || _loadFailed ? null : _save,
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

// ---------------------------------------------------------------------------
// Shared section shell
// ---------------------------------------------------------------------------

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> headerActions;
  final List<Widget> body;

  const _SettingsSection({
    required this.title,
    this.headerActions = const [],
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AbTokens.space12),
      decoration: BoxDecoration(
        border: Border.all(color: context.antgrid.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: AbTokens.sansStyle()),
              ...headerActions,
            ],
          ),
          ...body,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

class _CommandsSection extends StatelessWidget {
  final AbConfig draft;
  final ValueChanged<AbConfig> onChanged;
  const _CommandsSection({required this.draft, required this.onChanged});

  void _addCommand() {
    onChanged(
      draft.copyWith(
        commands: [
          ...draft.commands,
          const AbCommand(name: 'new-command', command: ''),
        ],
      ),
    );
  }

  void _updateAt(int i, AbCommand c) {
    final next = [...draft.commands];
    next[i] = c;
    onChanged(draft.copyWith(commands: next));
  }

  void _removeAt(int i) {
    final next = [...draft.commands]..removeAt(i);
    onChanged(draft.copyWith(commands: next));
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'COMMANDS',
      headerActions: [AbIconButton(icon: AbIcons.add, onTap: _addCommand)],
      body: [
        for (var i = 0; i < draft.commands.length; i++) ...[
          const SizedBox(height: AbTokens.space8),
          _CommandRow(
            command: draft.commands[i],
            onChanged: (c) => _updateAt(i, c),
            onRemove: () => _removeAt(i),
          ),
        ],
      ],
    );
  }
}

class _CommandRow extends StatelessWidget {
  final AbCommand command;
  final ValueChanged<AbCommand> onChanged;
  final VoidCallback onRemove;
  const _CommandRow({
    required this.command,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            initialValue: command.name,
            decoration: const InputDecoration(labelText: 'name'),
            onChanged: (v) => onChanged(command.copyWith(name: v)),
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: command.command,
            decoration: const InputDecoration(labelText: 'command'),
            onChanged: (v) => onChanged(command.copyWith(command: v)),
          ),
        ),
        Checkbox(
          value: command.confirm ?? false,
          onChanged: (v) => onChanged(command.copyWith(confirm: v)),
        ),
        AbIconButton(icon: AbIcons.trash, onTap: onRemove),
      ],
    );
  }
}

class _PortsSection extends StatelessWidget {
  final AbConfig draft;
  final ValueChanged<AbConfig> onChanged;
  const _PortsSection({required this.draft, required this.onChanged});

  void _add() {
    onChanged(
      draft.copyWith(
        ports: [
          ...draft.ports,
          const AbPort(port: 3000, onDetect: OnDetect.notify),
        ],
      ),
    );
  }

  void _update(int i, AbPort p) {
    final next = [...draft.ports];
    next[i] = p;
    onChanged(draft.copyWith(ports: next));
  }

  void _remove(int i) {
    final next = [...draft.ports]..removeAt(i);
    onChanged(draft.copyWith(ports: next));
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: 'PORTS',
      headerActions: [AbIconButton(icon: AbIcons.add, onTap: _add)],
      body: [
        for (var i = 0; i < draft.ports.length; i++) ...[
          const SizedBox(height: AbTokens.space8),
          Row(
            children: [
              SizedBox(
                width: 80,
                child: TextFormField(
                  initialValue: draft.ports[i].port.toString(),
                  decoration: const InputDecoration(labelText: 'port'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n > 0) {
                      _update(i, draft.ports[i].copyWith(port: n));
                    }
                  },
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: TextFormField(
                  initialValue: draft.ports[i].name ?? '',
                  decoration: const InputDecoration(labelText: 'name'),
                  onChanged: (v) => _update(
                    i,
                    draft.ports[i].copyWith(name: v.isEmpty ? null : v),
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              DropdownButton<OnDetect>(
                value: draft.ports[i].onDetect ?? OnDetect.notify,
                items: OnDetect.values
                    .map((o) => DropdownMenuItem(value: o, child: Text(o.name)))
                    .toList(),
                onChanged: (v) => v == null
                    ? null
                    : _update(i, draft.ports[i].copyWith(onDetect: v)),
              ),
              AbIconButton(icon: AbIcons.trash, onTap: () => _remove(i)),
            ],
          ),
        ],
      ],
    );
  }
}

class _AgentSection extends ConsumerWidget {
  final AbConfig draft;
  final List<DetectedTool> detected;
  final ValueChanged<AbConfig> onChanged;

  const _AgentSection({
    required this.draft,
    required this.detected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = draft.agent ?? const AbAgentBlock();
    final detectedTools = detected.map((t) => t.tool).toList();
    final tool = agent.tool;
    final defaultRelay = ref
        .watch(appSettingsServiceProvider.select((s) => s.defaultRelayUrl));
    final relayHint = defaultRelay == null || defaultRelay.isEmpty
        ? 'Relay URL (e.g. wss://relay.example.com)'
        : 'Relay URL (default: $defaultRelay)';
    return _SettingsSection(
      title: 'AGENT',
      body: [
        const SizedBox(height: AbTokens.space8),
        DropdownButton<String>(
          value: detectedTools.contains(tool) ? tool : null,
          hint: const Text('Select agent'),
          items: detectedTools
              .map((t) => DropdownMenuItem(value: t, child: Text(t)))
              .toList(),
          onChanged: (v) =>
              onChanged(draft.copyWith(agent: agent.copyWith(tool: v))),
        ),
        const SizedBox(height: AbTokens.space8),
        TextFormField(
          initialValue: agent.command ?? '',
          decoration: const InputDecoration(
            labelText: 'Custom command (overrides tool)',
          ),
          onChanged: (v) => onChanged(
            draft.copyWith(
              agent: agent.copyWith(command: v.isEmpty ? null : v),
            ),
          ),
        ),
        TextFormField(
          initialValue: (agent.flags ?? const []).join(' '),
          decoration: const InputDecoration(
            labelText: 'Flags (space-separated)',
          ),
          onChanged: (v) {
            final flags = v.trim().isEmpty ? null : v.split(RegExp(r'\s+'));
            onChanged(draft.copyWith(agent: agent.copyWith(flags: flags)));
          },
        ),
        TextFormField(
          initialValue: draft.relayUrl ?? '',
          decoration: InputDecoration(labelText: relayHint),
          onChanged: (v) {
            final trimmed = v.trim();
            onChanged(
              trimmed.isEmpty
                  ? draft.copyWith(clearRelayUrl: true)
                  : draft.copyWith(relayUrl: trimmed),
            );
          },
        ),
      ],
    );
  }
}
