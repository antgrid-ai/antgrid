import 'dart:async';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../constants/breakpoints.dart';
import '../../design/ab_carbon.dart';
import '../../design/widgets/ab_agent_mark.dart';
import '../../launcher/host_control_client.dart';
import '../../models/scheduler.dart';
import '../../providers/agent_catalog.dart' show agentLabelsProvider;
import '../../providers/scheduler.dart';
import '../../providers/scheduler_drafts.dart';
import '../../providers/scheduler_timezone.dart';
import '../../util/detached.dart';
import '../../utils/platform_utils.dart';
import 'scheduler_format.dart';
import '../ab_status_helpers.dart' show caughtErrorCopy;

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
  late final TextEditingController _name,
      _prompt,
      _branch,
      _cron,
      _time,
      _date,
      _clock;
  bool _syncingParts = false;
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

  /// A context under the pane's [AbCarbonScope]. This State's own context sits
  /// above it, so Carbon theme lookups and the discard modal's scope relay must
  /// start here.
  BuildContext? _scoped;
  CarbonThemeData get _t => CarbonTheme.of(_scoped!);
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

  static const _worktreeHint =
      'Every run continues in the same worktree. New commits on the base branch are not pulled in.';
  static const _projectFolderHint =
      'Works on the files as they are, uncommitted changes included';

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
      return 'Pick an agent installed on $_machineName.';
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
    final (date, clock) = _splitWallTime(_draft.time);
    _date = TextEditingController(text: date);
    _clock = TextEditingController(text: clock);
    _restoreChoices();
    _lastPreviewKey = _previewKey;
    for (final c in [_name, _prompt, _branch]) {
      c.addListener(_changed);
    }
    _cron.addListener(_schedulePreview);
    _time.addListener(_timeChanged);
    _date.addListener(_partsChanged);
    _clock.addListener(_partsChanged);
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
    for (final c in [_name, _prompt, _branch, _cron, _time, _date, _clock]) {
      c.dispose();
    }
    _promptFocus.dispose();
    _cronFocus.dispose();
    super.dispose();
  }

  static (String, String) _splitWallTime(String text) {
    final trimmed = text.trim();
    final at = trimmed.indexOf(' ');
    return at < 0
        ? (trimmed, '')
        : (trimmed.substring(0, at), trimmed.substring(at + 1).trim());
  }

  /// One-offs keep a single wall-time string for drafts and requests; the date
  /// and time inputs are two views of it.
  void _partsChanged() {
    if (_syncingParts) return;
    _syncingParts = true;
    final joined = '${_date.text.trim()} ${_clock.text.trim()}'.trim();
    if (_time.text != joined) _time.text = joined;
    _syncingParts = false;
  }

  void _timeChanged() {
    if (!_syncingParts) {
      _syncingParts = true;
      final (date, clock) = _splitWallTime(_time.text);
      if (_date.text != date) _date.text = date;
      if (_clock.text != clock) _clock.text = clock;
      _syncingParts = false;
    }
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
      final discard = await _confirmDiscard();
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
      setState(() => _error = 'Pick an agent installed on $_machineName.');
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
      if (mounted) {
        setState(
          () => _error =
              "Couldn't save the schedule. ${caughtErrorCopy(error, 'Try again.')}",
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    final scoped = _scoped;
    if (scoped == null || !scoped.mounted) return false;
    final discard = await showCarbonModal<bool>(
      scoped,
      builder: (dialog) => CarbonModal.confirmation(
        title: 'Discard changes?',
        body: const Text('Your draft for this schedule will be deleted.'),
        danger: true,
        secondary: CarbonModalAction(
          label: 'Keep editing',
          autofocus: true,
          onPressed: () => Navigator.of(dialog).pop(false),
        ),
        primary: CarbonModalAction(
          label: 'Discard draft',
          onPressed: () => Navigator.of(dialog).pop(true),
        ),
      ),
    );
    return discard ?? false;
  }

  void _pickAgent(String id) {
    // A pick of the selected agent must not clear a chat mode no picker shows
    // (an agent without a listed set keeps its stored one).
    if (id == _agent) return;
    final capability = widget.snapshot.capabilities.agents.firstWhere(
      (a) => a.agentId == id,
    );
    setState(() {
      _agent = id;
      _mode = capability.modes.first;
      // Mode ids belong to one agent's chat backend.
      _chatMode = null;
    });
    _persist();
  }

  // Slotted rather than keyed by text: a failed save and a capability notice
  // can carry the same sentence at once.
  Widget _notice(String slot, String text, {bool error = false}) =>
      CarbonNotification(
        key: ValueKey('scheduler-notice-$slot'),
        kind: error
            ? CarbonNotificationKind.error
            : CarbonNotificationKind.warning,
        title: text,
      );

  Widget _hint(String text) => Text(
    text,
    style: _t.typography.helper.copyWith(color: _t.colors.textSecondary),
  );

  Widget _section(String title, List<Widget> children) => CarbonLayerSurface(
    padding: const EdgeInsets.all(CarbonSpacing.spacing05),
    child: CarbonFormSection(
      title: title,
      spacing: CarbonSpacing.spacing05,
      children: children,
    ),
  );

  Widget _segmented<T>(
    String label,
    List<(T, String)> items,
    T selected,
    ValueChanged<T> select,
  ) {
    // A stored value the host no longer offers stays visible, disabled, so the
    // switcher never asserts on a selection it cannot show.
    final options = [
      for (final (value, text) in items)
        CarbonOption<T>(value: value, label: text, enabled: _editable),
      if (!items.any((i) => i.$1 == selected))
        CarbonOption<T>(value: selected, label: '$selected', enabled: false),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // Four or more segments outgrow a phone pane, and a clipped horizontal
        // scroll would hide the last option with no affordance.
        if (options.length >= 4 && box.maxWidth < kCompactBreakpoint) {
          return CarbonSelect<T>(
            label: label,
            options: options,
            value: selected,
            onChanged: _editable ? select : null,
          );
        }
        return CarbonFieldFrame(
          label: label,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: CarbonContentSwitcher<T>(
              options: options,
              value: selected,
              onChanged: select,
              // Arrows only move focus; selecting rewrites the draft (cron,
              // approvals), so it needs an explicit Enter, Space or tap.
              activation: CarbonActivationMode.manual,
              semanticLabel: label,
            ),
          ),
        );
      },
    );
  }

  Widget _choiceList(
    String label,
    List<
      ({String title, String? description, bool selected, VoidCallback onTap})
    >
    choices,
  ) => CarbonContainedList(
    label: label,
    children: [
      for (final c in choices)
        _choiceRow(c),
    ],
  );

  Widget _choiceRow(
    ({String title, String? description, bool selected, VoidCallback onTap}) c,
  ) {
    final row = CarbonContainedListRow(
      key: ValueKey('scheduler-option-${c.title}'),
      title: c.title,
      secondary: (c.description?.isEmpty ?? true) ? null : c.description,
      selected: c.selected,
      onPressed: _editable
          ? () {
              setState(c.onTap);
              _persist();
            }
          : null,
    );
    if (_editable) return row;
    // A non-interactive row emits no selected state of its own.
    return MergeSemantics(
      child: Semantics(
        selected: c.selected,
        inMutuallyExclusiveGroup: true,
        child: row,
      ),
    );
  }

  static const _modeFallbackDescriptions = <String, String>{
    'default': 'Asks before edits and commands',
    'plan': 'Read-only; proposes changes',
    'accept edits': 'Edits files without asking',
    'auto': 'Approves tool use it judges safe',
  };

  Widget _permissionMode(String agentLabel) {
    final listed = _chatModes!;
    final stored = _chatMode;
    // A mode the agent no longer lists (or one carried over from earlier
    // chats) stays selectable, so saving does not silently replace it.
    final unlisted = stored != null && !listed.any((m) => m.id == stored);
    return _choiceList('Permission mode', [
      // Not plain "Default": claude-code lists its own mode with that name,
      // and no mode (the agent's configured default) is a different setting.
      (
        title: 'Agent default',
        description: 'Whatever $agentLabel is set to',
        selected: stored == null,
        onTap: () => _chatMode = null,
      ),
      for (final m in listed)
        (
          title: m.name,
          description:
              m.description ?? _modeFallbackDescriptions[m.name.toLowerCase()],
          selected: m.id == stored,
          onTap: () => _chatMode = m.id,
        ),
      if (unlisted)
        (
          title: stored,
          description: null,
          selected: true,
          onTap: () => _chatMode = stored,
        ),
    ]);
  }

  Widget _fact(String label, String value) => CarbonFieldFrame(
    label: label,
    child: Text(
      value,
      style: _t.typography.body.copyWith(color: _t.colors.textPrimary),
    ),
  );

  Widget _readOnlyBox(String label, String text) => CarbonFieldFrame(
    label: label,
    readOnly: true,
    child: CarbonTooltip(
      message: text,
      child: CarbonActionFieldBox(
        readOnly: true,
        minHeight: _t.controlHeight,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _t.typography.code.copyWith(color: _t.colors.textPrimary),
        ),
      ),
    ),
  );

  String get _machineName =>
      ref.read(schedulerMachinesProvider)[widget.machineId] ?? 'this machine';

  Widget _summarySection(String machineName, String agentLabel) {
    final t = _t;
    final base = t.typography.body.copyWith(
      color: t.colors.textPrimary,
      height: 1.55,
    );
    final bold = base.copyWith(fontWeight: FontWeight.w600);
    final mono = t.typography.code.copyWith(color: t.colors.textPrimary);
    final zone =
        '${_timezone.trim().split('/').last.replaceAll('_', ' ')} time';
    final project =
        widget.snapshot.projects
            .where((p) => p.projectId == _project)
            .firstOrNull
            ?.name ??
        _project;
    final selectedMode = _chatModes
        ?.where((m) => m.id == _chatMode)
        .firstOrNull
        ?.name;
    final cadence = <InlineSpan>[
      if (_once) ...[
        const TextSpan(text: 'Once at '),
        TextSpan(text: _time.text.trim(), style: mono),
      ] else if (_frequency == 'Hourly')
        const TextSpan(text: 'Every hour')
      else if (_frequency == 'Custom') ...[
        const TextSpan(text: 'On cron '),
        TextSpan(text: _cron.text.trim(), style: mono),
      ] else ...[
        TextSpan(
          text: _frequency == 'Daily' ? 'Every day at ' : 'Every weekday at ',
        ),
        TextSpan(text: _time.text.trim(), style: mono),
      ],
      TextSpan(text: ' ($zone), '),
    ];
    final checking =
        _previewInputsReady && _validated == null && _previewError == null;
    return _section('Summary', [
      Text.rich(
        TextSpan(
          style: base,
          children: [
            ...cadence,
            TextSpan(text: agentLabel, style: bold),
            TextSpan(
              text: _mode == 'chat'
                  ? ' opens a chat in '
                  : ' opens a terminal in ',
            ),
            TextSpan(
              text: _workspace == 'worktree'
                  ? 'its own worktree of '
                  : 'the folder of ',
            ),
            TextSpan(text: project, style: bold),
            const TextSpan(text: ' and runs this prompt'),
            if (_carriesChatMode && selectedMode != null) ...[
              const TextSpan(text: ' in '),
              TextSpan(text: selectedMode, style: bold),
              const TextSpan(text: ' mode'),
            ],
            if (_approvals == 'bypass')
              const TextSpan(text: ' with all approvals bypassed'),
            const TextSpan(text: '.'),
          ],
        ),
      ),
      if (_validated == _previewKey)
        Row(
          spacing: CarbonSpacing.spacing03,
          children: [
            CarbonIcon(
              CarbonIcons.checkmarkFilled,
              color: t.colors.supportSuccess,
            ),
            Expanded(
              child: Text(
                'Checked on $machineName',
                style: t.typography.helper.copyWith(
                  color: t.colors.textPrimary,
                ),
              ),
            ),
          ],
        )
      else if (checking)
        CarbonInlineLoading(
          status: CarbonInlineLoadingStatus.active,
          description: 'Checking on $machineName…',
        ),
    ]);
  }

  Widget? _nextRunsSection(String localZone, bool detected) {
    if (_validated != _previewKey || _occurrences.isEmpty) return null;
    final t = _t;
    final now = DateTime.now().toUtc();
    return _section('Next runs', [
      _hint('${detected ? 'your time' : 'machine time'} · $localZone'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, time) in _occurrences.indexed)
            // Sections sit on layer 02, so their rules take that level.
            DecoratedBox(
              decoration: i == 0
                  ? const BoxDecoration()
                  : BoxDecoration(
                      border: Border(
                        top: BorderSide(color: t.borderSubtle(2)),
                      ),
                    ),
              child: Padding(
                padding: EdgeInsets.only(
                  top: i == 0 ? 0 : CarbonSpacing.spacing03,
                  bottom: CarbonSpacing.spacing03,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  spacing: CarbonSpacing.spacing04,
                  children: [
                    Flexible(
                      child: Text(
                        schedulerWallCompact(time, localZone, now),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.typography.code.copyWith(
                          color: t.colors.textPrimary,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        schedulerRelative(time, now),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.typography.helper.copyWith(
                          color: t.colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ]);
  }

  Widget _header() {
    final t = _t;
    final name = _name.text.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSubtle(1))),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CarbonSpacing.spacing05,
          vertical: CarbonSpacing.spacing03,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wraps rather than shares a row: at large text the back control
            // and the draft tag together exceed a phone's width.
            Wrap(
              spacing: CarbonSpacing.spacing04,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CarbonButton(
                  label: 'Schedules',
                  kind: CarbonButtonKind.ghost,
                  icon: const CarbonIcon(CarbonIcons.chevronLeft),
                  onPressed: _saving ? null : widget.onClose,
                ),
                if (_draft.dirty)
                  const CarbonTag(
                    label: 'Unsaved draft',
                    color: CarbonTagColor.blue,
                  ),
              ],
            ),
            Row(
              spacing: CarbonSpacing.spacing04,
              children: [
                Expanded(
                  child: Text(
                    name.isEmpty ? 'New schedule' : name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.title.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                ),
                CarbonToggle(
                  value: _enabled,
                  semanticLabel: 'Active',
                  onText: 'Active',
                  offText: 'Inactive',
                  onChanged: _editable
                      ? (v) {
                          setState(() => _enabled = v);
                          _persist();
                        }
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final t = _t;
    final cancel = CarbonButton(
      label: 'Cancel',
      kind: CarbonButtonKind.secondary,
      onPressed: _saving
          ? null
          : () => detached('ScheduleEditor', 'cancel failed', _cancel),
    );
    final save = CarbonButton(
      label: _saving
          ? 'Saving…'
          : widget.schedule == null
          ? 'Create schedule'
          : 'Save changes',
      busy: _saving,
      // Stays enabled while saving so focus survives a failed save; the busy
      // button ignores presses itself.
      onPressed: _canSave || _saving
          ? () => detached('ScheduleEditor', 'save failed', _save)
          : null,
    );
    final hint = Text(
      'Draft kept if you leave',
      style: t.typography.helper.copyWith(color: t.colors.textSecondary),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colors.layer01,
        border: Border(top: BorderSide(color: t.borderSubtle(1))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(CarbonSpacing.spacing05),
          child: LayoutBuilder(
            builder: (context, box) => box.maxWidth >= kCompactBreakpoint
                ? Row(
                    spacing: CarbonSpacing.spacing05,
                    children: [
                      Expanded(child: hint),
                      CarbonButtonSet(children: [cancel, save]),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: CarbonSpacing.spacing04,
                    children: [
                      hint,
                      CarbonButtonSet(children: [cancel, save]),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localTimezone = ref.watch(schedulerLocalTimezoneProvider);
    final machineName =
        ref.watch(schedulerMachinesProvider)[widget.machineId] ??
        'this machine';
    final labels = ref.watch(agentLabelsProvider);
    final localZone =
        localTimezone.value ?? widget.snapshot.capabilities.timezone;
    final agents = widget.snapshot.capabilities.agents;
    final modes =
        agents.where((a) => a.agentId == _agent).firstOrNull?.modes ??
        const <String>[];
    String agentName(String id) => labels[id] ?? id;
    final isGit =
        widget.snapshot.projects
            .where((p) => p.projectId == _project)
            .firstOrNull
            ?.isGitRepository ??
        false;
    return AbCarbonScope(
      child: Builder(
        builder: (scoped) {
          _scoped = scoped;
          // Subscribing here, not only in the helpers, is what rebuilds the
          // pane when the app theme or density changes.
          final t = CarbonTheme.of(scoped);
          const fieldWidth = CarbonSpacing.spacing09;
          final task = _section('Task', [
            CarbonTextInput(
              controller: _name,
              enabled: _editable,
              label: 'Name',
              placeholder: 'Schedule name',
            ),
            CarbonTextInput(
              controller: _prompt,
              focusNode: _promptFocus,
              variant: CarbonTextInputVariant.multiline,
              minLines: 3,
              label: 'Prompt',
              placeholder: 'What should the agent do each run?',
              enabled: _editable || _deleted,
              readOnly: !_editable,
            ),
          ]);
          final when = _section('When', [
            Wrap(
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing04,
              children: [
                if (widget.snapshot.capabilities.supportsOneOff || _once)
                  _segmented<String>(
                    'Runs',
                    const [('Repeats', 'Repeats'), ('Once', 'Once')],
                    _once ? 'Once' : 'Repeats',
                    _selectKind,
                  ),
                if (!_once)
                  _segmented<String>(
                    'Every',
                    const [
                      ('Hourly', 'Hour'),
                      ('Daily', 'Day'),
                      ('Weekdays', 'Weekday'),
                      ('Custom', 'Custom'),
                    ],
                    _frequency,
                    _selectFrequency,
                  ),
              ],
            ),
            Wrap(
              spacing: CarbonSpacing.spacing04,
              runSpacing: CarbonSpacing.spacing04,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                if (_once) ...[
                  SizedBox(
                    width: fieldWidth * 4,
                    child: CarbonTextInput(
                      controller: _date,
                      enabled: _editable,
                      label: 'Date',
                      autocorrect: false,
                      enableSuggestions: false,
                      placeholder: 'yyyy-MM-dd',
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth * 3,
                    child: CarbonTextInput(
                      controller: _clock,
                      enabled: _editable,
                      label: 'Time',
                      autocorrect: false,
                      enableSuggestions: false,
                      placeholder: 'HH:mm',
                    ),
                  ),
                ] else if (_frequency == 'Daily' || _frequency == 'Weekdays')
                  SizedBox(
                    width: fieldWidth * 3,
                    child: CarbonTextInput(
                      controller: _time,
                      enabled: _editable,
                      label: 'At',
                      autocorrect: false,
                      enableSuggestions: false,
                      placeholder: '09:00',
                    ),
                  ),
                SizedBox(
                  width: fieldWidth * 5,
                  child: _readOnlyBox('Timezone', _timezone),
                ),
                if (!_once && _frequency != 'Custom')
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: CarbonSpacing.spacing03,
                    ),
                    child: Text.rich(
                      TextSpan(
                        style: t.typography.helper.copyWith(
                          color: t.colors.textSecondary,
                        ),
                        children: [
                          const TextSpan(text: 'cron '),
                          TextSpan(
                            text: _cron.text,
                            style: t.typography.code.copyWith(
                              color: t.colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (!_once && _frequency == 'Custom')
              CarbonTextInput(
                controller: _cron,
                focusNode: _cronFocus,
                enabled: _editable,
                label: 'Cron',
                autocorrect: false,
                enableSuggestions: false,
                placeholder: '0 9 * * 1-5',
                helperText: 'minute hour day-of-month month day-of-week',
              ),
            if (_invalidTime)
              _notice(
                'time',
                _once
                    ? 'Enter a date and time like 2026-10-09 09:00.'
                    : 'Enter a valid time from 00:00 to 23:59.',
                error: true,
              ),
            if (_previewError != null) ...[
              _notice('preview', _previewError!, error: _invalidPreview),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: CarbonButton(
                  label: 'Retry validation',
                  kind: CarbonButtonKind.tertiary,
                  onPressed: _editable
                      ? () => detached(
                          'ScheduleEditor',
                          'preview failed',
                          _preview,
                        )
                      : null,
                ),
              ),
            ],
          ]);
          final agent = _section('Agent', [
            CarbonSelect<String>(
              label: 'Agent',
              placeholder: 'Choose an agent',
              enabled: _editable,
              options: [
                for (final a in agents)
                  CarbonOption<String>(
                    value: a.agentId,
                    label: agentName(a.agentId),
                    icon: AbAgentMark(
                      toolKey: a.agentId,
                      label: agentName(a.agentId),
                      size: t.iconSize,
                      color: t.colors.iconPrimary,
                    ),
                  ),
              ],
              value: agents.any((a) => a.agentId == _agent) ? _agent : null,
              onChanged: _pickAgent,
            ),
            Wrap(
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing04,
              children: [
                _segmented<String>(
                  'Opens as',
                  [
                    for (final m in {...modes, _mode})
                      (m, m == 'chat' ? 'Chat' : 'Terminal'),
                  ],
                  _mode,
                  (v) {
                    setState(() => _mode = v);
                    _persist();
                  },
                ),
                _segmented<String>(
                  'Approvals',
                  const [('default', 'Ask as usual'), ('bypass', 'Bypass all')],
                  _approvals,
                  (v) {
                    setState(() => _approvals = v);
                    _persist();
                  },
                ),
              ],
            ),
            if (_carriesChatMode && _chatModes != null)
              _permissionMode(agentName(_agent)),
          ]);
          final workspace = _section('Workspace', [
            if (_locked) ...[
              Text(
                'Workspace settings locked',
                style: t.typography.heading.copyWith(
                  color: t.colors.textPrimary,
                ),
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
                    ? 'Own worktree'
                    : 'Project folder',
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
              _hint(
                _current!.workspace == 'worktree'
                    ? _worktreeHint
                    : _projectFolderHint,
              ),
            ] else ...[
              CarbonSelect<String>(
                label: 'Project',
                placeholder: 'Choose a project',
                enabled: _editable,
                options: [
                  for (final p in widget.snapshot.projects)
                    CarbonOption<String>(value: p.projectId, label: p.name),
                ],
                value:
                    widget.snapshot.projects.any((p) => p.projectId == _project)
                    ? _project
                    : null,
                onChanged: (v) {
                  setState(() {
                    _project = v;
                    _workspace =
                        widget.snapshot.projects
                            .firstWhere((p) => p.projectId == v)
                            .isGitRepository
                        ? 'worktree'
                        : 'shared';
                  });
                  _persist();
                },
              ),
              if (_workspace == 'worktree')
                CarbonTextInput(
                  controller: _branch,
                  enabled: _editable,
                  label: 'Base branch',
                  autocorrect: false,
                  enableSuggestions: false,
                  placeholder: 'current branch',
                ),
              _choiceList('Run in', [
                if (isGit)
                  (
                    title: 'Own worktree',
                    description: _worktreeHint,
                    selected: _workspace == 'worktree',
                    onTap: () => _workspace = 'worktree',
                  ),
                (
                  title: 'Project folder',
                  description: _projectFolderHint,
                  selected: _workspace == 'shared',
                  onTap: () => _workspace = 'shared',
                ),
              ]),
            ],
          ]);
          final catchUp = widget.snapshot.capabilities.supportsCatchUp
              ? _section('If Antgrid was closed', [
                  _choiceList('Missed runs', [
                    (
                      title: schedulerCatchUpOnceLabel,
                      description: _once
                          ? 'Runs when Antgrid next opens'
                          : 'Runs the latest missed time when Antgrid opens',
                      selected: _catchUp != 'skip',
                      onTap: () => _catchUp = 'latest',
                    ),
                    (
                      title: schedulerCatchUpSkipLabel,
                      description: _once
                          ? 'Skipped if Antgrid is not open then'
                          : 'Waits for the next scheduled time',
                      selected: _catchUp == 'skip',
                      onTap: () => _catchUp = 'skip',
                    ),
                  ]),
                  _hint(
                    'Schedules run only while Antgrid is open on $machineName.',
                  ),
                ])
              : null;
          final summary = _summarySection(machineName, agentName(_agent));
          final nextRuns = _nextRunsSection(
            localZone,
            localTimezone.value != null,
          );
          final notices = [
            if (_error != null) _notice('error', _error!, error: true),
            if (!_deleted && _executionError != null)
              _notice('execution', _executionError!, error: true),
            if (!widget.writable)
              _notice(
                'offline',
                '$machineName is offline. Changes are paused until it reconnects.',
              ),
            if (_deleted)
              _notice(
                'deleted',
                'This schedule was deleted. Your draft is retained for copying; Save is unavailable.',
              ),
            if (_unsupportedClear)
              _notice(
                'branch-clear',
                'Update Antgrid on $machineName to clear the saved base branch. Other edits remain available.',
              ),
            if (_conflict) ...[
              _notice(
                'conflict',
                _locked
                    ? 'This schedule changed and its workspace is now locked. Keep mine uses the saved workspace settings.'
                    : 'This schedule changed while you were editing.',
              ),
              Wrap(
                spacing: CarbonSpacing.spacing03,
                runSpacing: CarbonSpacing.spacing03,
                children: [
                  CarbonButton(
                    label: 'Use saved version',
                    kind: CarbonButtonKind.tertiary,
                    onPressed: _saving ? null : _reload,
                  ),
                  CarbonButton(
                    label: 'Keep mine',
                    kind: CarbonButtonKind.secondary,
                    onPressed: _saving ? null : _keepChanges,
                  ),
                ],
              ),
            ],
          ];
          return ColoredBox(
            color: t.colors.background,
            child: LayoutBuilder(
              builder: (context, c) {
                final wide =
                    c.maxWidth >= kMediumBreakpoint && !isMobilePlatform;
                final form = CarbonForm(
                  spacing: CarbonSpacing.spacing05,
                  children: [
                    ...notices,
                    task,
                    when,
                    if (!wide) ...[summary, ?nextRuns],
                    agent,
                    workspace,
                    ?catchUp,
                  ],
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    Expanded(
                      child: wide
                          ? Align(
                              alignment: Alignment.topLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: CarbonSpacing.spacing06,
                                children: [
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: CarbonSpacing.spacing06 * 31,
                                      ),
                                      child: SingleChildScrollView(
                                        padding: const EdgeInsets.fromLTRB(
                                          CarbonSpacing.spacing06,
                                          CarbonSpacing.spacing06,
                                          0,
                                          CarbonSpacing.spacing06,
                                        ),
                                        child: form,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: CarbonSpacing.spacing06 * 16,
                                    child: SingleChildScrollView(
                                      padding: const EdgeInsets.fromLTRB(
                                        0,
                                        CarbonSpacing.spacing06,
                                        CarbonSpacing.spacing06,
                                        CarbonSpacing.spacing06,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        spacing: CarbonSpacing.spacing04,
                                        children: [summary, ?nextRuns],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(
                                CarbonSpacing.spacing05,
                              ),
                              child: form,
                            ),
                    ),
                    _footer(),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
