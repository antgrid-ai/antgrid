import 'dart:async';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_prompt_field.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_touch_sizing.dart';
import '../../launcher/host_control_client.dart';
import '../../models/scheduler.dart';
import '../../providers/scheduler.dart';
import '../../providers/scheduler_drafts.dart';
import '../../providers/scheduler_timezone.dart';
import '../../util/detached.dart';
import '../../utils/platform_utils.dart';
import 'scheduler_format.dart';

const schedulerPresets = <String, String>{
  'Hourly': '0 * * * *',
  'Daily': '0 9 * * *',
  'Weekdays': '0 9 * * 1-5',
};

class ScheduleEditor extends ConsumerStatefulWidget {
  const ScheduleEditor({
    super.key,
    required this.snapshot,
    required this.request,
    required this.writable,
    required this.onClose,
    required this.onSaved,
    this.schedule,
    this.machineId = 'local',
  });
  final SchedulerSnapshot snapshot;
  final SchedulerRequest request;
  final bool writable;
  final AgentSchedule? schedule;
  final String machineId;
  final VoidCallback onClose, onSaved;
  @override
  ConsumerState<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditor> {
  late final TextEditingController _name, _prompt, _branch, _cron, _time;
  final _promptFocus = FocusNode();
  final _cronFocus = FocusNode();
  late SchedulerDraft _draft;
  late String _project,
      _agent,
      _mode,
      _workspace,
      _approvals,
      _catchUp,
      _frequency,
      _timezone;
  late bool _enabled;
  String? _chatMode;
  bool _saving = false, _restoring = false, _invalidPreview = false;
  bool _closed = false;
  late String _lastPreviewKey;
  String? _error, _previewError, _validated;
  List<DateTime> _occurrences = const [];
  int _previewGeneration = 0;
  Timer? _debounce;
  SchedulerDraftKey get _key =>
      (machine: widget.machineId, scheduleId: widget.schedule?.id);
  AgentSchedule? get _current => widget.snapshot.schedules
      .where((s) => s.id == widget.schedule?.id)
      .firstOrNull;
  bool get _deleted => widget.schedule != null && _current == null;
  bool get _locked =>
      _current != null &&
      (_current!.workspaceCreated ||
          _current!.checkoutId != null ||
          widget.snapshot.runs.any(
            (run) => run.scheduleId == widget.schedule?.id && run.active,
          ));
  bool get _conflict =>
      _current != null &&
      (_draft.changedSince(_current!) ||
          (_locked &&
              (_project != _current!.projectId ||
                  _workspace != _current!.workspace ||
                  _branch.text.trim() != (_current!.baseBranch ?? ''))));
  bool get _editable => widget.writable && !_saving;
  bool get _once => _frequency == 'Once';

  /// Bypass already launches the agent with its own bypass mode, and a
  /// terminal run has no chat backend, so neither carries a permission mode.
  bool get _carriesChatMode => _mode == 'chat' && _approvals != 'bypass';
  List<SchedulerChatMode>? get _chatModes =>
      widget.snapshot.capabilities.chatModes[_agent];
  String? get _onceIso => schedulerWallIso(_time.text);
  String get _previewKey => _once
      ? 'once\n${_onceIso ?? _time.text.trim()}\n${_timezone.trim()}'
      : '${_cron.text.trim()}\n${_timezone.trim()}';
  bool get _previewInputsReady =>
      (_once ? _onceIso != null : _cron.text.trim().isNotEmpty) &&
      _timezone.trim().isNotEmpty;
  bool get _invalidTime => _once
      ? _onceIso == null
      : (_frequency == 'Daily' || _frequency == 'Weekdays') &&
            schedulerPresetCron(_frequency, _time.text) == null;

  /// The saved instant while the wall time and zone still name it, so an
  /// untouched one-off is never re-sent; any edit sends the wall-clock string.
  Object get _runAtValue {
    final saved = _draft.initialSaved;
    final stored = saved['runAt'];
    final iso = _onceIso;
    if (stored is int &&
        iso != null &&
        _timezone == saved['timezone'] &&
        schedulerWallTime(
              DateTime.fromMillisecondsSinceEpoch(stored, isUtc: true),
              _timezone,
            ) ==
            iso.replaceFirst('T', ' ')) {
      return stored;
    }
    return iso ?? _time.text.trim();
  }
  bool get _clearingBranch =>
      !_locked &&
      (_current?.baseBranch?.isNotEmpty ?? false) &&
      _branch.text.trim().isEmpty;
  bool get _unsupportedClear =>
      _clearingBranch && !widget.snapshot.capabilities.supportsBaseBranchClear;
  bool get _canSave =>
      _editable &&
      !_deleted &&
      !_conflict &&
      !_unsupportedClear &&
      !_invalidTime &&
      _timezone.trim().isNotEmpty &&
      _executionError == null &&
      _validated == _previewKey;
  String? get _executionError {
    final agent = widget.snapshot.capabilities.agents
        .where((a) => a.agentId == _agent)
        .firstOrNull;
    if (agent == null || !agent.modes.contains(_mode)) {
      return 'Select an installed agent and a mode with observable completion.';
    }
    final project = widget.snapshot.projects
        .where((p) => p.projectId == _project)
        .firstOrNull;
    if (project == null) {
      return 'The selected project is unavailable on this machine.';
    }
    if (_workspace == 'worktree' && !project.isGitRepository) {
      return 'This project no longer supports a worktree. Choose a shared workspace before its first run.';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final retained = ref.read(schedulerDraftsProvider)[_key];
    final current = _current;
    _draft = retained == null
        ? SchedulerDraft.start(
            widget.snapshot,
            widget.schedule,
            localTimezone: ref.read(schedulerLocalTimezoneProvider).value,
          )
        : current == null
        ? retained
        : retained.renewOneOff(current);
    final values = _draft.values;
    _name = TextEditingController(text: values['name'] as String);
    _prompt = TextEditingController(text: values['prompt'] as String);
    _branch = TextEditingController(
      text: values['baseBranch'] as String? ?? '',
    );
    _cron = TextEditingController(
      text: values['cron'] as String? ?? schedulerPresets['Daily']!,
    );
    _timezone = values['timezone'] as String;
    if (_timezone.trim().isEmpty) {
      _timezone =
          ref.read(schedulerLocalTimezoneProvider).value ??
          widget.snapshot.capabilities.timezone;
    }
    _time = TextEditingController(text: _draft.time);
    _restoreChoices();
    _lastPreviewKey = _previewKey;
    for (final c in [_name, _prompt, _branch]) {
      c.addListener(_changed);
    }
    _cron.addListener(_schedulePreview);
    _time.addListener(_timeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _persist();
      detached('ScheduleEditor', 'preview failed', _preview);
    });
  }

  void _restoreChoices() {
    final v = _draft.values;
    _project = v['projectId'] as String;
    _agent = v['agentId'] as String;
    _mode = v['mode'] as String;
    _workspace = v['workspace'] as String;
    _approvals = v['approvalPolicy'] as String;
    _catchUp = v['catchUp'] as String? ?? 'latest';
    _enabled = v['enabled'] as bool;
    _chatMode = v['chatMode'] as String?;
    _frequency = _draft.frequency;
  }

  Map<String, dynamic> get _values => {
    'name': _name.text,
    'prompt': _prompt.text,
    'projectId': _project,
    'agentId': _agent,
    'mode': _mode,
    'workspace': _workspace,
    'approvalPolicy': _approvals,
    'catchUp': _catchUp,
    'enabled': _enabled,
    if (_carriesChatMode && _chatMode != null) 'chatMode': _chatMode,
    if (_branch.text.trim().isNotEmpty) 'baseBranch': _branch.text.trim(),
    if (_once) 'runAt': _runAtValue else 'cron': _cron.text,
    'timezone': _timezone,
  };
  void _persist() {
    if (_closed) return;
    _draft = _draft.edit(_values, _frequency, _time.text);
    ref.read(schedulerDraftsProvider.notifier).put(_key, _draft);
  }

  void _changed() {
    if (_restoring || _closed || _saving) return;
    if (mapEquals(_values, _draft.values) &&
        _frequency == _draft.frequency &&
        _time.text == _draft.time) {
      return;
    }
    _persist();
    setState(() => _error = null);
  }

  @override
  void didUpdateWidget(ScheduleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.writable && !widget.writable) {
      _previewGeneration++;
      _debounce?.cancel();
      _validated = null;
      _previewError =
          'Could not validate on this machine. Connect it and retry.';
      _invalidPreview = false;
    } else if (!oldWidget.writable && widget.writable) {
      detached('ScheduleEditor', 'preview failed', _preview);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_name, _prompt, _branch, _cron, _time]) {
      c.dispose();
    }
    _promptFocus.dispose();
    _cronFocus.dispose();
    super.dispose();
  }

  void _timeChanged() {
    if (_restoring) return;
    if (_once) {
      _schedulePreview();
      _changed();
      return;
    }
    final cron = schedulerPresetCron(_frequency, _time.text);
    if (cron != null && _frequency != 'Custom') _cron.text = cron;
    _changed();
  }

  void _selectKind(String value) {
    if ((value == 'Once') == _once) return;
    _restoring = true;
    if (value == 'Once') {
      _time.text = schedulerWallTime(
        DateTime.now().add(const Duration(hours: 1)),
        _timezone,
      );
      setState(() => _frequency = 'Once');
    } else {
      _time.text = schedulerPresetTime(_cron.text);
      setState(() => _frequency = schedulerFrequency(_cron.text));
    }
    _restoring = false;
    _schedulePreview();
    _changed();
    _persist();
  }

  void _selectFrequency(String value) {
    setState(() => _frequency = value);
    if (value == 'Custom') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cronFocus.requestFocus();
      });
    } else {
      _cron.text =
          schedulerPresetCron(value, _time.text) ?? schedulerPresets[value]!;
    }
    _persist();
  }

  void _schedulePreview() {
    if (_restoring || _closed || _previewKey == _lastPreviewKey) return;
    _lastPreviewKey = _previewKey;
    _changed();
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
    _debounce?.cancel();
    final generation = ++_previewGeneration, key = _previewKey;
    setState(() {
      _validated = null;
      _previewError = null;
      _invalidPreview = false;
      _occurrences = const [];
    });
    if (!_previewInputsReady) return;
    try {
      final result = await widget.request('scheduler.preview', {
        if (_once) 'runAt': _onceIso else 'cron': _cron.text.trim(),
        'timezone': _timezone.trim(),
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
      if (!mounted || generation != _previewGeneration || key != _previewKey) {
        return;
      }
      final code = error is RpcException
          ? error.code
          : error is HostControlException
          ? error.code
          : '';
      final message = error is RpcException
          ? error.message
          : error is HostControlException
          ? error.message
          : '';
      setState(() {
        _validated = null;
        _invalidPreview =
            code == 'SCHEDULER_INVALID_CRON' || code == 'INVALID_RUN_AT';
        _previewError = code == 'INVALID_RUN_AT'
            ? message.trim().isEmpty
                  ? 'That date and time is not valid in this timezone.'
                  : message
            : _invalidPreview
            ? 'Invalid cron or timezone. ${message.trim().isEmpty ? 'Check the cron expression and schedule timezone.' : message}'
            : 'Could not validate on this machine. Retry when it is available.';
      });
    }
  }

  void _reload() {
    if (_current == null) return;
    _restoring = true;
    _draft = SchedulerDraft.start(widget.snapshot, _current);
    final v = _draft.values;
    _name.text = v['name'] as String;
    _prompt.text = v['prompt'] as String;
    _branch.text = v['baseBranch'] as String? ?? '';
    _cron.text = v['cron'] as String? ?? _cron.text;
    _timezone = v['timezone'] as String;
    _time.text = _draft.time;
    _restoreChoices();
    _restoring = false;
    _lastPreviewKey = _previewKey;
    _persist();
    detached('ScheduleEditor', 'preview failed', _preview);
  }

  void _keepChanges() {
    final saved = _current!;
    _draft = _draft.keepChanges(saved);
    if (_locked) {
      _restoring = true;
      _project = saved.projectId;
      _workspace = saved.workspace;
      _branch.text = saved.baseBranch ?? '';
      _restoring = false;
    }
    _persist();
    detached('ScheduleEditor', 'preview failed', _preview);
  }

  Future<void> _cancel() async {
    if (_saving) return;
    if (_draft.dirty) {
      final discard = await AbConfirmDialog.show(
        context: context,
        title: 'Discard editable changes?',
        body: 'The unsaved draft for this schedule will be deleted.',
        confirmLabel: 'Discard draft',
        cancelLabel: 'Keep editing',
        destructive: true,
      );
      if (!mounted || !discard) return;
    }
    _closed = true;
    _debounce?.cancel();
    ref.read(schedulerDraftsProvider.notifier).remove(_key);
    widget.onClose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
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
    if (!widget.snapshot.projects.any((p) => p.projectId == _project)) {
      setState(
        () => _error = 'The selected project is unavailable on this machine.',
      );
      return;
    }
    final settings = {
      ..._values,
      'name': _name.text.trim(),
      'timezone': _timezone.trim(),
      if (_clearingBranch) 'baseBranch': null,
    };
    if (_once) {
      // A patch that names runAt counts as a new time, so an untouched instant
      // is left out rather than restated.
      if (settings['runAt'] is int) settings.remove('runAt');
    } else {
      settings['cron'] = _cron.text.trim();
    }
    // An older bridge's strict schema rejects keys it does not know.
    if (!widget.snapshot.capabilities.supportsCatchUp) {
      settings.remove('catchUp');
    }
    // Omitting the key would leave the stored mode in place.
    if (_carriesChatMode &&
        _chatMode == null &&
        _draft.initialSaved['chatMode'] != null) {
      settings['chatMode'] = null;
    }
    if (_locked) {
      for (final k in ['projectId', 'workspace', 'baseBranch']) {
        settings.remove(k);
      }
    }
    final drafts = ref.read(schedulerDraftsProvider.notifier), key = _key;
    final submittedDraft = _draft;
    final request = widget.request, scheduleId = widget.schedule?.id;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (scheduleId == null) {
        await request('scheduler.create', {'schedule': settings});
      } else {
        await request('scheduler.update', {
          'id': scheduleId,
          'patch': settings,
        });
      }
      _closed = true;
      drafts.removeIfCurrent(key, submittedDraft);
      if (mounted) widget.onSaved();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not save schedule: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _notice(String text, {bool error = false}) => Semantics(
    liveRegion: true,
    child: AbInlineBanner(
      text: text,
      color: error ? context.antgrid.error : context.antgrid.warning,
    ),
  );
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
      Semantics(label: label, child: child),
      const SizedBox(height: AbTokens.space8),
    ],
  );
  Widget _choices(
    String label,
    Map<String, String> choices,
    String value,
    ValueChanged<String> select,
  ) => _field(
    label,
    Wrap(
      spacing: AbTokens.space6,
      runSpacing: AbTokens.space6,
      children: [
        for (final c in choices.entries)
          AbChip.choice(
            label: c.value,
            selected: c.key == value,
            enabled: _editable,
            onTap: () {
              setState(() => select(c.key));
              _persist();
            },
          ),
      ],
    ),
  );
  Widget _permissionsPicker() {
    final listed = _chatModes!;
    final stored = _chatMode;
    // A mode the agent no longer lists (or one carried over from earlier
    // chats) stays selectable, so saving does not silently replace it.
    final unlisted = stored != null && !listed.any((m) => m.id == stored);
    // Not plain "Default": claude-code lists its own mode with that name, and
    // no mode (the agent's configured default) is a different setting.
    final choices = {
      '': 'Agent default',
      for (final m in listed) m.id: m.name,
      if (unlisted) stored: stored,
    };
    final selected = listed.where((m) => m.id == stored).firstOrNull;
    final help = stored == null
        ? "Uses the agent's own default mode."
        : selected?.description ??
              'Some permission modes approve tool use without asking.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AbTokens.space6,
      children: [
        _choices(
          'Permissions',
          choices,
          stored ?? '',
          (v) => _chatMode = v.isEmpty ? null : v,
        ),
        Text(
          help,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: context.antgrid.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _section(String name, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: AbTokens.space8,
    children: [
      Text(
        name,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontLg,
          fontWeight: FontWeight.w600,
        ),
      ),
      ...children,
    ],
  );
  Widget _fact(String label, String value) => _field(
    label,
    Text(
      value,
      style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final localTimezone = ref.watch(schedulerLocalTimezoneProvider);
    final localZone =
        localTimezone.value ?? widget.snapshot.capabilities.timezone;
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
    final prompt = _section('Prompt', [
      _field(
        'Name',
        AbTextField(
          controller: _name,
          enabled: _editable,
          hintText: 'Schedule name',
        ),
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
            enabled: _editable || _deleted,
            readOnly: !_editable,
          ),
        ),
      ),
    ]);
    final execution = _section('Execution', [
      if (_locked) ...[
        Row(
          children: [
            AbIcon(AbIcons.lock, color: context.antgrid.textSecondary),
            const SizedBox(width: AbTokens.space6),
            Expanded(
              child: Text(
                'Workspace settings locked',
                style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        _fact(
          'Project',
          widget.snapshot.projects
                  .where((p) => p.projectId == _current!.projectId)
                  .firstOrNull
                  ?.name ??
              _current!.projectId,
        ),
        _fact(
          'Workspace',
          _current!.workspace == 'worktree'
              ? 'Schedule-owned worktree'
              : 'Shared workspace',
        ),
        _fact(
          'Base branch',
          _current!.baseBranch ?? 'Current branch at creation',
        ),
        _fact(
          'Retained checkout',
          _current!.checkoutId ??
              (_current!.workspace == 'worktree'
                  ? 'Preparing workspace'
                  : 'Shared project workspace'),
        ),
      ] else ...[
        _choices(
          'Project',
          {for (final p in widget.snapshot.projects) p.projectId: p.name},
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
        ),
        _choices(
          'Workspace',
          {
            if (isGit) 'worktree': 'Schedule-owned worktree',
            'shared': 'Shared workspace',
          },
          _workspace,
          (v) => _workspace = v,
        ),
        if (_workspace == 'worktree')
          _field(
            'Base branch (blank uses current branch)',
            AbTextField(
              controller: _branch,
              enabled: _editable,
              hintText: 'main',
            ),
          ),
      ],
      Text(
        _workspace == 'worktree'
            ? 'Later runs retain files, commits and uncommitted changes in this workspace. They do not automatically pull from the base branch.'
            : 'Runs use the shared project files, including uncommitted changes.',
        style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
      ),
      _choices(
        'Installed agent',
        {for (final a in agents) a.agentId: a.agentId},
        _agent,
        (v) {
          // A tap on the selected chip must not clear a chat mode no picker
          // shows (an agent without a listed set keeps its stored one).
          if (v == _agent) return;
          _agent = v;
          _mode = agents.firstWhere((a) => a.agentId == v).modes.first;
          // Mode ids belong to one agent's chat backend.
          _chatMode = null;
        },
      ),
      _choices(
        'Session mode',
        {for (final m in modes) m: m == 'chat' ? 'Chat' : 'Terminal'},
        _mode,
        (v) => _mode = v,
      ),
      _choices(
        'Approval policy',
        const {'default': 'Normal approvals', 'bypass': 'Bypass approvals'},
        _approvals,
        (v) => _approvals = v,
      ),
      if (_carriesChatMode && _chatModes != null) _permissionsPicker(),
    ]);
    final timing = _section('Timing', [
      if (widget.snapshot.capabilities.supportsOneOff || _once)
        _choices(
          'Runs',
          const {'Repeats': 'Repeats', 'Once': 'Once'},
          _once ? 'Once' : 'Repeats',
          _selectKind,
        ),
      if (_once)
        _field(
          'Date and time (yyyy-MM-dd HH:mm) · $_timezone',
          AbTextField(
            controller: _time,
            enabled: _editable,
            hintText: 'yyyy-MM-dd HH:mm',
            autocorrect: false,
          ),
        )
      else
        _field(
          'Frequency',
          Wrap(
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space6,
            children: [
              for (final f in [...schedulerPresets.keys, 'Custom'])
                AbChip.choice(
                  label: f,
                  selected: _frequency == f,
                  enabled: _editable,
                  onTap: () => _selectFrequency(f),
                ),
            ],
          ),
        ),
      if (_frequency == 'Daily' || _frequency == 'Weekdays')
        _field(
          'Time (HH:mm) · $_timezone',
          AbTextField(
            controller: _time,
            enabled: _editable,
            hintText: '09:00',
            autocorrect: false,
          ),
        ),
      if (_invalidTime)
        _notice(
          _once
              ? 'Enter a date and time like 2026-10-09 09:00.'
              : 'Enter a valid time from 00:00 to 23:59.',
          error: true,
        ),
      if (!_once)
        _field(
          'Cron (minute hour day-of-month month day-of-week)',
          _frequency == 'Custom'
              ? AbTextField(
                  controller: _cron,
                  focusNode: _cronFocus,
                  enabled: _editable && _frequency == 'Custom',
                  hintText: '0 9 * * 1-5',
                  autocorrect: false,
                )
              : Text(
                  _cron.text,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    color: context.antgrid.textSecondary,
                  ),
                ),
        ),
      if (_frequency == 'Hourly' || _frequency == 'Custom')
        Text(
          'Timezone: $_timezone',
          style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
        ),
      if (_previewError != null) ...[
        _notice(_previewError!, error: _invalidPreview),
        AbButton(
          label: 'Retry validation',
          onTap: _editable
              ? () => detached('ScheduleEditor', 'preview failed', _preview)
              : null,
        ),
      ],
      if (_previewInputsReady && _validated == null && _previewError == null)
        Text(
          'Validating on target machine…',
          style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
        ),
      if (_validated == _previewKey && _occurrences.isNotEmpty)
        _field(
          '${_once ? 'Runs at' : 'Next five occurrences'} · ${localTimezone.value == null ? 'machine time' : 'local time'}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AbTokens.space6,
            children: [
              for (final time in _occurrences)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      schedulerLocalTime(time, localZone),
                      style: AbTokens.sansStyle(fontSize: AbTokens.fontSm),
                    ),
                    Text(
                      'UTC: ${schedulerTime(time)}',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: context.antgrid.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      if (widget.snapshot.capabilities.supportsCatchUp) ...[
        _choices(
          'If a run is missed',
          _once
              ? const {
                  'latest': 'Run it when the desktop is next open',
                  'skip': 'Skip it if missed',
                }
              : const {
                  'latest': 'Run the latest missed run',
                  'skip': 'Skip missed runs',
                },
          _catchUp,
          (v) => _catchUp = v,
        ),
        Text(
          _once
              ? _catchUp == 'skip'
                    ? 'Runs once at the chosen time, and is skipped if the desktop app is not open then.'
                    : 'Runs once at the chosen time, however late the desktop opens. Runs need the desktop app open.'
              : 'Runs once, for the latest missed run only, and not when the next run is due within 15 minutes. Runs need the desktop app open.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: context.antgrid.textSecondary,
          ),
        ),
      ],
      _choices(
        'Schedule state',
        const {'enabled': 'Enabled', 'paused': 'Paused'},
        _enabled ? 'enabled' : 'paused',
        (v) => _enabled = v == 'enabled',
      ),
    ]);
    return AbTouchSizing(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AbTokens.space16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: AbTokens.space12,
                children: [
                  Text(
                    widget.schedule == null
                        ? 'Create schedule'
                        : 'Edit schedule',
                    style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                  ),
                  if (_error != null) _notice(_error!, error: true),
                  if (!_deleted && _executionError != null)
                    _notice(_executionError!, error: true),
                  if (!widget.writable)
                    _notice('Connect the target machine to edit or save.'),
                  if (_deleted)
                    _notice(
                      'This schedule was deleted. Your draft is retained for copying; Save is unavailable.',
                    ),
                  if (_unsupportedClear)
                    _notice(
                      'Upgrade the target bridge to clear the saved base branch. Other edits remain available.',
                    ),
                  if (_conflict) ...[
                    _notice(
                      _locked
                          ? 'Saved settings changed and the workspace is now locked. Keep editable changes to use its fixed workspace settings.'
                          : 'Saved settings changed since this draft began.',
                    ),
                    Wrap(
                      spacing: AbTokens.space8,
                      runSpacing: AbTokens.space8,
                      children: [
                        AbButton(
                          label: 'Reload saved settings',
                          onTap: _saving ? null : _reload,
                        ),
                        AbButton(
                          label: 'Keep my editable changes',
                          onTap: _saving ? null : _keepChanges,
                        ),
                      ],
                    ),
                  ],
                  LayoutBuilder(
                    builder: (context, c) =>
                        c.maxWidth >= kMediumBreakpoint && !isMobilePlatform
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  spacing: AbTokens.space16,
                                  children: [prompt, execution],
                                ),
                              ),
                              const SizedBox(width: AbTokens.space24),
                              Expanded(child: timing),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: AbTokens.space16,
                            children: [prompt, execution, timing],
                          ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(AbTokens.space12),
            decoration: BoxDecoration(
              color: context.antgrid.bgSurface,
              border: Border(
                top: BorderSide(color: context.antgrid.borderDefault),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Wrap(
                spacing: AbTokens.space8,
                runSpacing: AbTokens.space8,
                children: [
                  AbButton(
                    label: _saving ? 'Saving…' : 'Save schedule',
                    variant: AbButtonVariant.primary,
                    onTap: _canSave
                        ? () => detached('ScheduleEditor', 'save failed', _save)
                        : null,
                  ),
                  AbButton(
                    label: 'Cancel',
                    onTap: _saving
                        ? null
                        : () => detached(
                            'ScheduleEditor',
                            'cancel failed',
                            _cancel,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
