import 'dart:convert';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../design/widgets/ab_toast.dart';
import '../../models/memory.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import 'memory_error.dart';
import 'memory_section_label.dart';

const kMaxEvidenceReferences = 8;

/// Lays out a row of buttons in Carbon's reading order (secondary first,
/// primary last): inline on wide layouts, a full-width set that stacks when
/// narrow on compact ones.
Widget memoryButtonRow(List<Widget> buttons, {required bool expand}) => expand
    ? CarbonButtonSet(
        alignment: CarbonButtonSetAlignment.fill,
        children: buttons,
      )
    : Wrap(
        spacing: CarbonSpacing.spacing03,
        runSpacing: CarbonSpacing.spacing03,
        children: buttons,
      );

/// Edits one memory by saving a correction that supersedes it.
///
/// In compact layouts the pane hosts [MemoryEditFormState.actions] in a bar that
/// must stay put above the keyboard, reading the form through a `GlobalKey` and
/// learning of changes through [onChanged].
class MemoryEditForm extends ConsumerStatefulWidget {
  const MemoryEditForm({
    super.key,
    required this.target,
    required this.record,
    required this.onSaved,
    required this.onCancel,
    this.compact = false,
    this.onChanged,
  });

  final MemoryTarget target;
  final MemoryRecord record;
  final ValueChanged<String> onSaved;
  final VoidCallback onCancel;
  final bool compact;
  final VoidCallback? onChanged;

  @override
  ConsumerState<MemoryEditForm> createState() => MemoryEditFormState();
}

class MemoryEditFormState extends ConsumerState<MemoryEditForm> {
  late final _title = TextEditingController(text: widget.record.title);
  late final _description = TextEditingController(
    text: widget.record.description,
  );
  late final _content = TextEditingController(text: widget.record.content);
  late final _applicability = TextEditingController(
    text: widget.record.applicability,
  );
  final _sourceInput = TextEditingController();
  late final List<String> _sources = [...widget.record.evidence];
  bool _busy = false;
  String? _error;
  String? _pendingPayload;
  String? _operationKey;

  Map<String, dynamic> get _save => widget.record.correction(
    title: _title.text,
    description: _description.text,
    content: _content.text.trim(),
    applicability: _applicability.text.trim(),
    evidence: List.of(_sources),
  );

  String? get _validationError => memorySaveValidation(_save);

  bool get _canSave {
    if (_busy || _validationError != null) return false;
    final record = widget.record;
    return memoryOptionalText(_title.text) != record.title ||
        memoryOptionalText(_description.text) != record.description ||
        _content.text.trim() != record.content ||
        _applicability.text.trim() != record.applicability ||
        !listEquals(_sources, record.evidence);
  }

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _description.addListener(_changed);
    _content.addListener(_changed);
    _applicability.addListener(_changed);
    _sourceInput.addListener(_changed);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _content.dispose();
    _applicability.dispose();
    _sourceInput.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  bool get _atLimit => _sources.length >= kMaxEvidenceReferences;

  bool get _canAdd => !_atLimit && _sourceInput.text.trim().isNotEmpty;

  void _addSource() {
    if (!_canAdd) return;
    _sources.add(_sourceInput.text.trim());
    _sourceInput.clear();
    _changed();
  }

  void _removeSource(String source) {
    _sources.remove(source);
    _changed();
  }

  Future<void> save() async {
    if (!_canSave) return;
    final request = ref.read(memoryRequestProvider(widget.target));
    final save = _save;
    // A retry of the same payload must reuse its key, or a save whose reply was
    // lost would be written twice.
    final payload = jsonEncode(save);
    if (payload != _pendingPayload) {
      _pendingPayload = payload;
      _operationKey = const Uuid().v4();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onChanged?.call();
    try {
      final result = await request({
        'op': 'save',
        'operation_key': _operationKey,
        'save': save,
      });
      if (!mounted) return;
      showAbToast(
        context,
        'Changes saved',
        duration: const Duration(milliseconds: 2400),
      );
      widget.onSaved(result['id'] as String);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = memoryErrorCopy(error, mutation: true));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onChanged?.call();
      }
    }
  }

  /// Save and Cancel, shared by this form's own footer and the compact pane's
  /// fixed bar so the enabled rules live in one place.
  Widget actions({required bool expand}) => memoryButtonRow([
    CarbonButton(
      label: 'Cancel',
      kind: CarbonButtonKind.secondary,
      onPressed: _busy ? null : widget.onCancel,
    ),
    CarbonButton(
      label: 'Save changes',
      busy: _busy,
      onPressed: _canSave ? () => detached('Memory', 'save failed', save) : null,
    ),
  ], expand: expand);

  Widget _sourceRow(String source) {
    final t = CarbonTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            source,
            style: t.typography.code.copyWith(color: t.colors.textPrimary),
          ),
        ),
        CarbonButton.iconOnly(
          icon: const CarbonIcon(CarbonIcons.close),
          semanticLabel: 'Remove $source',
          size: CarbonButtonSize.small,
          onPressed: _busy ? null : () => _removeSource(source),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final helper = t.typography.helper.copyWith(color: t.colors.textHelper);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_busy) widget.onCancel();
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: CarbonSpacing.spacing05,
        children: [
          if ((_validationError ?? _error) case final error?)
            CarbonNotification(
              kind: CarbonNotificationKind.error,
              subtitle: error,
            ),
          CarbonTextInput(
            key: const Key('memory-edit-title'),
            controller: _title,
            label: 'Title',
            showOptional: true,
            placeholder: 'A short name for this finding',
            clearable: true,
            enabled: !_busy,
          ),
          CarbonTextInput(
            key: const Key('memory-edit-description'),
            controller: _description,
            variant: CarbonTextInputVariant.multiline,
            label: 'Description',
            showOptional: true,
            placeholder: 'When this finding is useful',
            minLines: 2,
            maxLines: 4,
            clearable: true,
            enabled: !_busy,
          ),
          CarbonTextInput(
            key: const Key('memory-edit-content'),
            controller: _content,
            variant: CarbonTextInputVariant.multiline,
            label: 'Memory',
            minLines: 4,
            maxLines: 12,
            autofocus: true,
            enabled: !_busy,
          ),
          CarbonTextInput(
            key: const Key('memory-edit-applicability'),
            controller: _applicability,
            label: 'Applies when',
            placeholder: 'For example: Windows builds only',
            enabled: !_busy,
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MemorySectionLabel('Sources'),
              for (final source in _sources) _sourceRow(source),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: CarbonSpacing.spacing03,
                children: [
                  Expanded(
                    child: CarbonTextInput(
                      key: const Key('memory-edit-source'),
                      controller: _sourceInput,
                      semanticLabel: 'Add a source',
                      placeholder: 'path/to/file.ts or docs/page.md#section',
                      enabled: !_busy && !_atLimit,
                      onSubmitted: (_) => _addSource(),
                    ),
                  ),
                  CarbonButton(
                    label: 'Add',
                    kind: CarbonButtonKind.tertiary,
                    onPressed: _busy || !_canAdd ? null : _addSource,
                  ),
                ],
              ),
              const SizedBox(height: CarbonSpacing.spacing02),
              Text(
                _atLimit
                    ? 'That’s the limit of $kMaxEvidenceReferences sources. Remove one to add another.'
                    : 'Files or doc sections that back this memory up.',
                style: helper,
              ),
            ],
          ),
          Text('Saving keeps the current text as an earlier version.', style: helper),
          if (!widget.compact) actions(expand: false),
        ],
      ),
    );
  }
}
