import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_prompt_field.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/scheduler.dart';
import '../../providers/scheduler.dart';
import '../../util/detached.dart';

const schedulerPresets = <String, String>{
  'Hourly': '0 * * * *',
  'Daily': '0 9 * * *',
  'Weekdays': '0 9 * * 1-5',
};

class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({
    super.key,
    required this.snapshot,
    required this.request,
    required this.writable,
    required this.onClose,
    required this.onSaved,
    this.schedule,
  });
  final SchedulerSnapshot snapshot;
  final SchedulerRequest request;
  final bool writable;
  final AgentSchedule? schedule;
  final VoidCallback onClose;
  final VoidCallback onSaved;
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _branch;
  late final TextEditingController _cron;
  late final TextEditingController _timezone;
  final _promptFocus = FocusNode();
  late String _project;
  late String _agent;
  late String _mode;
  late String _workspace;
  late String _approvals;
  late bool _enabled;
  bool _saving = false;
  String? _error;
  String? _previewError;
  List<DateTime> _occurrences = const [];
  String? _validated;
  int _previewGeneration = 0;
  Timer? _debounce;
  bool get _locked =>
      widget.schedule?.workspaceCreated == true ||
      widget.schedule?.checkoutId != null;
  bool get _editable => widget.writable && !_saving;
  String get _previewKey => '${_cron.text.trim()}\n${_timezone.text.trim()}';

  @override
  void initState() {
    super.initState();
    final s = widget.schedule;
    _name = TextEditingController(text: s?.name ?? '');
    _prompt = TextEditingController(text: s?.prompt ?? '');
    _branch = TextEditingController(text: s?.baseBranch ?? '');
    _cron = TextEditingController(text: s?.cron ?? schedulerPresets['Daily']);
    _timezone = TextEditingController(
      text: s?.timezone ?? widget.snapshot.capabilities.timezone,
    );
    _project = s?.projectId ?? widget.snapshot.projects.first.projectId;
    _agent = s?.agentId ?? widget.snapshot.capabilities.agents.first.agentId;
    _mode = s?.mode ?? widget.snapshot.capabilities.agents.first.modes.first;
    _workspace =
        s?.workspace ??
        (widget.snapshot.projects.first.isGitRepository
            ? 'worktree'
            : 'shared');
    _approvals = s?.approvalPolicy ?? 'default';
    _enabled = s?.enabled ?? true;
    _cron.addListener(_schedulePreview);
    _timezone.addListener(_schedulePreview);
    detached('ScheduleEditor', 'preview failed', _preview);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _prompt.dispose();
    _branch.dispose();
    _cron.dispose();
    _timezone.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _previewGeneration++;
    setState(() {
      _validated = null;
      _occurrences = const [];
      _previewError = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => detached('ScheduleEditor', 'preview failed', _preview),
    );
  }

  Future<void> _preview() async {
    final generation = ++_previewGeneration;
    final key = _previewKey;
    try {
      final result = await widget.request('scheduler.preview', {
        'cron': _cron.text.trim(),
        'timezone': _timezone.text.trim(),
      });
      final occurrences = (result['occurrences'] as List)
          .map(
            (v) => DateTime.fromMillisecondsSinceEpoch(
              (v as num).toInt(),
              isUtc: true,
            ),
          )
          .toList();
      if (!mounted || generation != _previewGeneration || key != _previewKey) {
        return;
      }
      setState(() {
        _occurrences = occurrences;
        _validated = key;
        _previewError = null;
      });
    } catch (error) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _validated = null;
        _previewError = '$error';
      });
    }
  }

  Future<void> _save() async {
    if (!_editable || _validated != _previewKey) return;
    if (_name.text.trim().isEmpty || _prompt.text.trim().isEmpty) {
      setState(() => _error = 'Name and prompt are required.');
      return;
    }
    final capability = widget.snapshot.capabilities.agents
        .where((a) => a.agentId == _agent)
        .firstOrNull;
    if (capability == null || !capability.modes.contains(_mode)) {
      setState(
        () => _error =
            'Select an installed agent and a mode with observable completion.',
      );
      return;
    }
    final settings = <String, dynamic>{
      'name': _name.text.trim(),
      'projectId': _project,
      'agentId': _agent,
      'mode': _mode,
      'prompt': _prompt.text,
      'approvalPolicy': _approvals,
      'workspace': _workspace,
      if (_branch.text.trim().isNotEmpty) 'baseBranch': _branch.text.trim(),
      'cron': _cron.text.trim(),
      'timezone': _timezone.text.trim(),
      'enabled': _enabled,
    };
    if (_locked) {
      settings.remove('projectId');
      settings.remove('workspace');
      settings.remove('baseBranch');
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.schedule == null) {
        await widget.request('scheduler.create', {'schedule': settings});
      } else {
        await widget.request('scheduler.update', {
          'id': widget.schedule!.id,
          'patch': settings,
        });
      }
      if (mounted) widget.onSaved();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not save schedule: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: AbTokens.space6,
    children: [
      Text(
        label,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: context.antgrid.textSecondary,
        ),
      ),
      child,
      const SizedBox(height: AbTokens.space8),
    ],
  );

  Widget _choices(
    String label,
    Map<String, String> choices,
    String value,
    ValueChanged<String> select, {
    bool locked = false,
  }) => _field(
    label,
    Wrap(
      spacing: AbTokens.space6,
      runSpacing: AbTokens.space6,
      children: [
        for (final choice in choices.entries)
          AbChip.choice(
            label: choice.value,
            selected: choice.key == value,
            enabled: _editable && !locked,
            onTap: () => setState(() => select(choice.key)),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final agents = widget.snapshot.capabilities.agents;
    final modes =
        agents.where((a) => a.agentId == _agent).firstOrNull?.modes ??
        const <String>[];
    final isGit =
        widget.snapshot.projects
            .where((p) => p.projectId == _project)
            .firstOrNull
            ?.isGitRepository ??
        false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AbTokens.space16),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AbTokens.transcriptMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.schedule == null ? 'Create schedule' : 'Edit schedule',
                style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AbTokens.space12),
              if (_error != null)
                AbInlineBanner(text: _error!, color: context.antgrid.error),
              if (!_editable && !_saving)
                AbInlineBanner(
                  text: 'Connect the target machine to edit or save.',
                  color: context.antgrid.textMuted,
                ),
              _field(
                'Name',
                AbTextField(
                  controller: _name,
                  enabled: _editable,
                  hintText: 'Schedule name',
                ),
              ),
              _choices(
                'Project',
                {
                  for (final project in widget.snapshot.projects)
                    project.projectId: project.name,
                },
                _project,
                (v) {
                  _project = v;
                  _workspace =
                      widget.snapshot.projects
                          .firstWhere((p) => p.projectId == v)
                          .isGitRepository
                      ? 'worktree'
                      : 'shared';
                },
                locked: _locked,
              ),
              _choices(
                'Installed agent',
                {for (final agent in agents) agent.agentId: agent.agentId},
                _agent,
                (v) {
                  _agent = v;
                  _mode = agents.firstWhere((a) => a.agentId == v).modes.first;
                },
              ),
              _choices(
                'Session mode',
                {
                  for (final mode in modes)
                    mode: mode == 'chat' ? 'Chat' : 'Terminal',
                },
                _mode,
                (v) => _mode = v,
              ),
              _field(
                'Saved prompt',
                Container(
                  padding: const EdgeInsets.all(AbTokens.space8),
                  decoration: BoxDecoration(
                    border: Border.all(color: context.antgrid.borderDefault),
                    borderRadius: AbTokens.borderRadius5,
                  ),
                  child: AbPromptField(
                    controller: _prompt,
                    focusNode: _promptFocus,
                    hintText: 'What should the agent do each run?',
                    enabled: _editable,
                  ),
                ),
              ),
              _choices(
                'Approval policy',
                const {
                  'default': 'Normal approvals',
                  'bypass': 'Bypass approvals',
                },
                _approvals,
                (v) => _approvals = v,
              ),
              _choices(
                'Workspace',
                {
                  if (isGit) 'worktree': 'Schedule-owned worktree',
                  'shared': 'Shared workspace',
                },
                _workspace,
                (v) => _workspace = v,
                locked: _locked,
              ),
              if (_workspace == 'worktree')
                _field(
                  'Base branch (blank uses current branch)',
                  AbTextField(
                    controller: _branch,
                    enabled: _editable && !_locked,
                    hintText: 'main',
                  ),
                ),
              if (_locked)
                Padding(
                  padding: const EdgeInsets.only(bottom: AbTokens.space12),
                  child: Text(
                    'Project, workspace and base branch are fixed because this schedule already owns a workspace.',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      color: context.antgrid.textMuted,
                    ),
                  ),
                ),
              _field(
                'Frequency',
                Wrap(
                  spacing: AbTokens.space6,
                  runSpacing: AbTokens.space6,
                  children: [
                    for (final preset in schedulerPresets.entries)
                      AbChip.choice(
                        label: preset.key,
                        selected: _cron.text == preset.value,
                        enabled: _editable,
                        onTap: () => _cron.text = preset.value,
                      ),
                    AbChip.choice(
                      label: 'Custom',
                      selected: !schedulerPresets.containsValue(_cron.text),
                      enabled: _editable,
                      onTap: () => _cron.text = '* * * * *',
                    ),
                  ],
                ),
              ),
              _field(
                'Cron (minute hour day-of-month month day-of-week)',
                AbTextField(
                  controller: _cron,
                  enabled: _editable,
                  hintText: '0 9 * * 1-5',
                  autocorrect: false,
                ),
              ),
              _field(
                'IANA timezone on target machine',
                AbTextField(
                  controller: _timezone,
                  enabled: _editable,
                  autocorrect: false,
                  hintText: 'Asia/Kolkata',
                ),
              ),
              if (_previewError != null)
                AbInlineBanner(
                  text: 'Invalid cron or timezone: $_previewError',
                  color: context.antgrid.error,
                ),
              if (_validated == null && _previewError == null)
                Text(
                  'Validating on target machine…',
                  style: AbTokens.sansStyle(color: context.antgrid.textMuted),
                ),
              if (_occurrences.isNotEmpty)
                _field(
                  'Next five occurrences (UTC; evaluated in ${_timezone.text.trim()})',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final time in _occurrences)
                        Text(
                          time.toIso8601String(),
                          style: AbTokens.monoStyle(fontSize: AbTokens.fontSm),
                        ),
                    ],
                  ),
                ),
              _choices(
                'Schedule state',
                const {'enabled': 'Enabled', 'paused': 'Paused'},
                _enabled ? 'enabled' : 'paused',
                (v) => _enabled = v == 'enabled',
              ),
              Wrap(
                spacing: AbTokens.space8,
                children: [
                  AbButton(
                    label: _saving ? 'Saving…' : 'Save schedule',
                    variant: AbButtonVariant.primary,
                    onTap: _editable && _validated == _previewKey
                        ? () => detached('ScheduleEditor', 'save failed', _save)
                        : null,
                  ),
                  AbButton(
                    label: 'Cancel',
                    onTap: _saving ? null : widget.onClose,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
