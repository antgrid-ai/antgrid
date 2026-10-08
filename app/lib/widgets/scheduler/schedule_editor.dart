import 'dart:async';
import 'dart:math' as math;
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_agent_mark.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_prompt_field.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_switch.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../design/widgets/ab_touch_sizing.dart';
import '../../launcher/host_control_client.dart';
import '../../models/scheduler.dart';
import '../../providers/agent_catalog.dart';
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
      final discard = await AbConfirmDialog.show(
        context: context,
        title: 'Discard changes?',
        body: 'Your draft for this schedule will be deleted.',
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

  Widget _label(String text) => Text(
    text,
    style: AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _hint(String text) => Text(
    text,
    style: AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: context.antgrid.textSecondary,
    ),
  );

  Widget _field(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: AbTokens.space6,
    children: [
      _label(label),
      Semantics(label: label, child: child),
    ],
  );

  Widget _card(String title, List<Widget> children) => Container(
    padding: const EdgeInsets.all(AbTokens.space16),
    decoration: BoxDecoration(
      color: context.antgrid.bgSurface,
      border: Border.all(color: context.antgrid.borderDefault),
      borderRadius: AbTokens.borderRadius8,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AbTokens.space16,
      children: [
        Text(
          title,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            fontWeight: FontWeight.w600,
          ),
        ),
        ...children,
      ],
    ),
  );

  Widget _segmented<T>(
    String label,
    List<(T, String)> items,
    T selected,
    ValueChanged<T> select,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: AbTokens.space6,
    children: [
      _label(label),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: AbSegmented<T>(
          segments: [
            for (final (value, text) in items)
              AbSegment<T>(value: value, label: text, enabled: _editable),
          ],
          selected: selected,
          onSelect: select,
        ),
      ),
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

  Widget _grid(List<Widget> items, {int columns = 2}) => LayoutBuilder(
    builder: (context, box) {
      final n = box.maxWidth >= kCompactBreakpoint ? columns : 1;
      final width = (box.maxWidth - AbTokens.space8 * (n - 1)) / n;
      return Wrap(
        spacing: AbTokens.space8,
        runSpacing: AbTokens.space8,
        children: [
          for (final item in items) SizedBox(width: width, child: item),
        ],
      );
    },
  );

  Widget _option({
    required String title,
    required bool selected,
    required VoidCallback onTap,
    String? description,
    Widget? leading,
  }) {
    final colors = context.antgrid;
    return Semantics(
      key: ValueKey('scheduler-option-$title'),
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: title,
      child: MouseRegion(
        cursor: _editable ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _editable
              ? () {
                  setState(onTap);
                  _persist();
                }
              : null,
          child: Opacity(
            opacity: _editable ? 1 : AbTokens.opacityDisabled,
            child: Container(
              constraints: isMobilePlatform
                  ? const BoxConstraints(minHeight: AbTokens.tapTargetMin)
                  : null,
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space12,
                vertical: AbTokens.space10,
              ),
              decoration: BoxDecoration(
                color: selected ? colors.bgRaised : colors.bgSurface,
                border: Border.all(
                  color: selected ? colors.accent : colors.borderDefault,
                ),
                borderRadius: AbTokens.borderRadius5,
              ),
              child: Row(
                crossAxisAlignment: leading == null
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                spacing: AbTokens.space10,
                children: [
                  leading ??
                      Container(
                        width: AbTokens.space14,
                        height: AbTokens.space14,
                        margin: const EdgeInsets.only(top: AbTokens.space2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? colors.accent : colors.textMuted,
                            width: selected ? AbTokens.space4 : 1,
                          ),
                        ),
                      ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: AbTokens.space2,
                      children: [
                        Text(
                          title,
                          style: AbTokens.sansStyle(
                            fontSize: AbTokens.fontMd,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        if (description != null && description.isNotEmpty)
                          _hint(description),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
    return _field(
      'Permission mode',
      _grid([
        // Not plain "Default": claude-code lists its own mode with that name,
        // and no mode (the agent's configured default) is a different setting.
        _option(
          title: 'Agent default',
          description: 'Whatever $agentLabel is set to',
          selected: stored == null,
          onTap: () => _chatMode = null,
        ),
        for (final m in listed)
          _option(
            title: m.name,
            description:
                m.description ??
                _modeFallbackDescriptions[m.name.toLowerCase()],
            selected: m.id == stored,
            onTap: () => _chatMode = m.id,
          ),
        if (unlisted)
          _option(
            title: stored,
            selected: true,
            onTap: () => _chatMode = stored,
          ),
      ]),
    );
  }

  Widget _fact(String label, String value) => _field(
    label,
    Text(
      value,
      style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
    ),
  );

  double get _fieldHeight =>
      math.max(AbTokens.rowHeightSm, AbTouchSizing.extentOf(context));

  Widget _readOnlyBox(String text) => AbTooltip(
    message: text,
    child: Container(
      height: _fieldHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space10),
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: Border.all(color: context.antgrid.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(fontSize: AbTokens.fontMd),
      ),
    ),
  );

  String get _machineName =>
      ref.read(schedulerMachinesProvider)[widget.machineId] ?? 'this machine';

  Widget _summaryCard(String machineName, String agentLabel) {
    final colors = context.antgrid;
    final bold = AbTokens.sansStyle(
      fontSize: AbTokens.fontMd,
      fontWeight: FontWeight.w600,
    );
    final mono = AbTokens.monoStyle(fontSize: AbTokens.fontMd);
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
    return _card('Summary', [
      Text.rich(
        TextSpan(
          style: AbTokens.sansStyle(fontSize: AbTokens.fontMd, height: 1.55),
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
          spacing: AbTokens.space6,
          children: [
            AbIcon(AbIcons.check, color: colors.success),
            Expanded(
              child: Text(
                'Checked on $machineName',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: colors.success,
                ),
              ),
            ),
          ],
        )
      else if (checking)
        _hint('Checking on $machineName…'),
    ]);
  }

  Widget _nextRunsCard(String localZone, bool detected) {
    if (_validated != _previewKey || _occurrences.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.antgrid;
    final now = DateTime.now().toUtc();
    return _card('Next runs', [
      _hint('${detected ? 'your time' : 'machine time'} · $localZone'),
      for (final (i, time) in _occurrences.indexed)
        Container(
          padding: EdgeInsets.only(top: i == 0 ? 0 : AbTokens.space8),
          decoration: i == 0
              ? null
              : BoxDecoration(
                  border: Border(top: BorderSide(color: colors.borderDefault)),
                ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            spacing: AbTokens.space12,
            children: [
              Flexible(
                child: Text(
                  schedulerWallCompact(time, localZone, now),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(fontSize: AbTokens.fontMd),
                ),
              ),
              Flexible(
                child: Text(
                  schedulerRelative(time, now),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
    ]);
  }

  Widget _header() {
    final colors = context.antgrid;
    final name = _name.text.trim();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space12,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderDefault)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AbTokens.space6,
        children: [
          if (_draft.dirty)
            AbChip.label(label: 'Unsaved draft', color: colors.unread),
          Row(
            spacing: AbTokens.space10,
            children: [
              Expanded(
                child: Row(
                  spacing: AbTokens.space10,
                  children: [
                    Flexible(
                      child: AbTapTarget(
                        onTap: _saving ? null : widget.onClose,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: AbTokens.space4,
                          children: [
                            AbIcon(
                              AbIcons.chevronLeft,
                              color: colors.textSecondary,
                            ),
                            Flexible(
                              child: Text(
                                'Schedules',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AbTokens.sansStyle(
                                  fontSize: AbTokens.fontMd,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      '/',
                      style: AbTokens.sansStyle(color: colors.textMuted),
                    ),
                    Flexible(
                      child: Text(
                        name.isEmpty ? 'New schedule' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                'Active',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  color: colors.textSecondary,
                ),
              ),
              AbSwitch(
                value: _enabled,
                semanticLabel: 'Active',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final localTimezone = ref.watch(schedulerLocalTimezoneProvider);
    final machineName =
        ref.watch(schedulerMachinesProvider)[widget.machineId] ??
        'this machine';
    final catalog = ref.watch(agentCatalogProvider);
    final localZone =
        localTimezone.value ?? widget.snapshot.capabilities.timezone;
    final agents = widget.snapshot.capabilities.agents;
    final modes =
        agents.where((a) => a.agentId == _agent).firstOrNull?.modes ??
        const <String>[];
    String agentName(String id) => catalog[id]?.label ?? id;
    final isGit =
        widget.snapshot.projects
            .where((p) => p.projectId == _project)
            .firstOrNull
            ?.isGitRepository ??
        false;
    final task = _card('Task', [
      _field(
        'Name',
        AbTextField(
          controller: _name,
          enabled: _editable,
          hintText: 'Schedule name',
        ),
      ),
      _field(
        'Prompt',
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
    final when = _card('When', [
      Wrap(
        spacing: AbTokens.space16,
        runSpacing: AbTokens.space12,
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
        spacing: AbTokens.space12,
        runSpacing: AbTokens.space12,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          if (_once) ...[
            SizedBox(
              width: AbTokens.space24 * 6,
              child: _field(
                'Date',
                AbTextField(
                  controller: _date,
                  enabled: _editable,
                  height: _fieldHeight,
                  hintText: 'yyyy-MM-dd',
                  autocorrect: false,
                ),
              ),
            ),
            SizedBox(
              width: AbTokens.space24 * 4,
              child: _field(
                'Time',
                AbTextField(
                  controller: _clock,
                  enabled: _editable,
                  height: _fieldHeight,
                  hintText: 'HH:mm',
                  autocorrect: false,
                ),
              ),
            ),
          ] else if (_frequency == 'Daily' || _frequency == 'Weekdays')
            SizedBox(
              width: AbTokens.space24 * 4,
              child: _field(
                'At',
                AbTextField(
                  controller: _time,
                  enabled: _editable,
                  height: _fieldHeight,
                  hintText: '09:00',
                  autocorrect: false,
                ),
              ),
            ),
          SizedBox(
            width: AbTokens.space24 * 9,
            child: _field('Timezone', _readOnlyBox(_timezone)),
          ),
          if (!_once && _frequency != 'Custom')
            Padding(
              padding: const EdgeInsets.only(bottom: AbTokens.space12),
              child: Text.rich(
                TextSpan(
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: context.antgrid.textSecondary,
                  ),
                  children: [
                    const TextSpan(text: 'cron '),
                    TextSpan(
                      text: _cron.text,
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontSm,
                        color: context.antgrid.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      if (!_once && _frequency == 'Custom')
        _field(
          'Cron',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AbTokens.space6,
            children: [
              AbTextField(
                controller: _cron,
                focusNode: _cronFocus,
                enabled: _editable,
                hintText: '0 9 * * 1-5',
                autocorrect: false,
              ),
              _hint('minute hour day-of-month month day-of-week'),
            ],
          ),
        ),
      if (_invalidTime)
        _notice(
          _once
              ? 'Enter a date and time like 2026-10-09 09:00.'
              : 'Enter a valid time from 00:00 to 23:59.',
          error: true,
        ),
      if (_previewError != null) ...[
        _notice(_previewError!, error: _invalidPreview),
        Align(
          alignment: Alignment.centerLeft,
          child: AbButton(
            label: 'Retry validation',
            onTap: _editable
                ? () => detached('ScheduleEditor', 'preview failed', _preview)
                : null,
          ),
        ),
      ],
    ]);
    final agent = _card('Agent', [
      _grid([
        for (final a in agents)
          _option(
            title: agentName(a.agentId),
            selected: a.agentId == _agent,
            leading: AbAgentMark(
              toolKey: a.agentId,
              label: agentName(a.agentId),
              size: AbTokens.space16,
            ),
            onTap: () {
              // A tap on the selected tile must not clear a chat mode no
              // picker shows (an agent without a listed set keeps its stored
              // one).
              if (a.agentId == _agent) return;
              _agent = a.agentId;
              _mode = a.modes.first;
              // Mode ids belong to one agent's chat backend.
              _chatMode = null;
            },
          ),
      ], columns: 3),
      Wrap(
        spacing: AbTokens.space16,
        runSpacing: AbTokens.space12,
        children: [
          _segmented<String>(
            'Opens as',
            [for (final m in modes) (m, m == 'chat' ? 'Chat' : 'Terminal')],
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
    final workspace = _card('Workspace', [
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
          _current!.workspace == 'worktree' ? 'Own worktree' : 'Project folder',
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
        if (_workspace == 'worktree')
          _field(
            'Base branch',
            AbTextField(
              controller: _branch,
              enabled: _editable,
              hintText: 'current branch',
              autocorrect: false,
            ),
          ),
        _grid([
          if (isGit)
            _option(
              title: 'Own worktree',
              description: _worktreeHint,
              selected: _workspace == 'worktree',
              onTap: () => _workspace = 'worktree',
            ),
          _option(
            title: 'Project folder',
            description: _projectFolderHint,
            selected: _workspace == 'shared',
            onTap: () => _workspace = 'shared',
          ),
        ]),
      ],
    ]);
    final catchUp = widget.snapshot.capabilities.supportsCatchUp
        ? _card('If Antgrid was closed', [
            _grid([
              _option(
                title: schedulerCatchUpOnceLabel,
                description: _once
                    ? 'Runs when Antgrid next opens'
                    : 'Runs the latest missed time when Antgrid opens',
                selected: _catchUp != 'skip',
                onTap: () => _catchUp = 'latest',
              ),
              _option(
                title: schedulerCatchUpSkipLabel,
                description: _once
                    ? 'Skipped if Antgrid is not open then'
                    : 'Waits for the next scheduled time',
                selected: _catchUp == 'skip',
                onTap: () => _catchUp = 'skip',
              ),
            ]),
            _hint('Schedules run only while Antgrid is open on $machineName.'),
          ])
        : null;
    final summary = _summaryCard(machineName, agentName(_agent));
    final nextRuns = _nextRunsCard(localZone, localTimezone.value != null);
    final notices = [
      if (_error != null) _notice(_error!, error: true),
      if (!_deleted && _executionError != null)
        _notice(_executionError!, error: true),
      if (!widget.writable)
        _notice(
          '$machineName is offline. Changes are paused until it reconnects.',
        ),
      if (_deleted)
        _notice(
          'This schedule was deleted. Your draft is retained for copying; Save is unavailable.',
        ),
      if (_unsupportedClear)
        _notice(
          'Update Antgrid on $machineName to clear the saved base branch. Other edits remain available.',
        ),
      if (_conflict) ...[
        _notice(
          _locked
              ? 'This schedule changed and its workspace is now locked. Keep mine uses the saved workspace settings.'
              : 'This schedule changed while you were editing.',
        ),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          children: [
            AbButton(
              label: 'Use saved version',
              onTap: _saving ? null : _reload,
            ),
            AbButton(label: 'Keep mine', onTap: _saving ? null : _keepChanges),
          ],
        ),
      ],
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= kMediumBreakpoint && !isMobilePlatform;
        final form = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AbTokens.space16,
          children: [
            ...notices,
            task,
            when,
            if (!wide) ...[summary, nextRuns],
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
                        spacing: AbTokens.space24,
                        children: [
                          Flexible(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth:
                                    AbTokens.space24 * 30 + AbTokens.space24,
                              ),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  AbTokens.space24,
                                  AbTokens.space24,
                                  0,
                                  AbTokens.space24,
                                ),
                                child: form,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: AbTokens.space24 * 16,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                0,
                                AbTokens.space24,
                                AbTokens.space24,
                                AbTokens.space24,
                              ),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                spacing: AbTokens.space12,
                                children: [summary, nextRuns],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(AbTokens.space16),
                      child: form,
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
                child: Row(
                  spacing: AbTokens.space8,
                  children: [
                    Expanded(
                      child: Text(
                        'Draft kept if you leave',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontSm,
                          color: context.antgrid.textSecondary,
                        ),
                      ),
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
                    AbButton(
                      label: _saving
                          ? 'Saving…'
                          : widget.schedule == null
                          ? 'Create schedule'
                          : 'Save changes',
                      variant: AbButtonVariant.primary,
                      onTap: _canSave
                          ? () => detached(
                              'ScheduleEditor',
                              'save failed',
                              _save,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
