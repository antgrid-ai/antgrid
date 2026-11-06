import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/memory.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import 'memory_error.dart';
import 'memory_section_label.dart';

const kMaxEvidenceReferences = 8;

/// Lays out a row of buttons: inline on wide layouts, one full-width tap
/// target per button on compact ones. Each button carries its own `expand`.
Widget memoryButtonRow(List<Widget> buttons, {required bool expand}) => Row(
  children: [
    for (final (i, button) in buttons.indexed) ...[
      if (i > 0) const SizedBox(width: AbTokens.space8),
      if (expand)
        Expanded(
          child: SizedBox(height: AbTokens.tapTargetMin, child: button),
        )
      else
        button,
    ],
  ],
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

  bool get _canSave {
    if (_busy || _content.text.trim().isEmpty) return false;
    final record = widget.record;
    return _content.text.trim() != record.content ||
        _applicability.text.trim() != record.applicability ||
        !listEquals(_sources, record.evidence);
  }

  @override
  void initState() {
    super.initState();
    _content.addListener(_changed);
    _applicability.addListener(_changed);
    _sourceInput.addListener(_changed);
  }

  @override
  void dispose() {
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
    final save = widget.record.correction(
      content: _content.text.trim(),
      applicability: _applicability.text.trim(),
      evidence: List.of(_sources),
    );
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
    AbButton(
      label: 'Save changes',
      variant: AbButtonVariant.primary,
      expand: expand,
      onTap: _canSave ? () => detached('Memory', 'save failed', save) : null,
    ),
    AbButton(
      label: 'Cancel',
      expand: expand,
      onTap: _busy ? null : widget.onCancel,
    ),
  ], expand: expand);

  Widget _chip(String source) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space8,
        AbTokens.space2,
        AbTokens.space4,
        AbTokens.space2,
      ),
      decoration: BoxDecoration(
        color: p.bgElevated,
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              source,
              style: AbTokens.monoStyle(fontSize: AbTokens.fontSm),
            ),
          ),
          const SizedBox(width: AbTokens.space4),
          AbIconButton(
            icon: AbIcons.close,
            tooltip: 'Remove $source',
            boxSize: 20,
            onTap: _busy ? null : () => _removeSource(source),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final muted = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textMuted,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_busy) widget.onCancel();
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error case final error?) ...[
            AbInlineBanner(text: error, color: p.error),
            const SizedBox(height: AbTokens.space12),
          ],
          const MemorySectionLabel('Memory'),
          AbTextField(
            controller: _content,
            minLines: 4,
            maxLines: 12,
            autofocus: true,
            enabled: !_busy,
          ),
          const SizedBox(height: AbTokens.space16),
          const MemorySectionLabel('Applies when'),
          AbTextField(
            controller: _applicability,
            hintText: 'For example: Windows builds only',
            enabled: !_busy,
          ),
          const SizedBox(height: AbTokens.space16),
          const MemorySectionLabel('Sources'),
          if (_sources.isNotEmpty) ...[
            Wrap(
              spacing: AbTokens.space6,
              runSpacing: AbTokens.space6,
              children: [for (final source in _sources) _chip(source)],
            ),
            const SizedBox(height: AbTokens.space8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  label: 'Add a source',
                  textField: true,
                  child: AbTextField(
                    controller: _sourceInput,
                    hintText: 'path/to/file.ts or docs/page.md#section',
                    enabled: !_busy && !_atLimit,
                    onSubmitted: (_) => _addSource(),
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Add',
                onTap: _busy || !_canAdd ? null : _addSource,
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space6),
          Text(
            _atLimit
                ? 'That’s the limit of $kMaxEvidenceReferences sources. Remove one to add another.'
                : 'Files or doc sections that back this memory up.',
            style: muted,
          ),
          const SizedBox(height: AbTokens.space16),
          Text('Saving keeps the current text as an earlier version.', style: muted),
          if (!widget.compact) ...[
            const SizedBox(height: AbTokens.space16),
            actions(expand: false),
          ],
        ],
      ),
    );
  }
}
