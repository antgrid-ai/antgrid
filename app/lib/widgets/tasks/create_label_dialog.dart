import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_label_chip.dart' show abLabelColor;
import '../../design/widgets/ab_text_field.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';

/// Curated swatches, not a colour wheel: a label's colour is a scan aid on a
/// crowded row, not a design choice worth a picker. Six-digit hex, no `#`,
/// matching [TaskLabel.color] and the server's [LabelColorSchema].
const _kLabelSwatches = [
  'd73a4a', // red
  'fb8500', // orange
  'fbca04', // yellow
  '2da44e', // green
  '0e8a16', // dark green
  '1d76db', // blue
  '5319e7', // purple
  'e99695', // pink
  '6a737d', // grey
  '000000', // black
];

/// Creates an account-wide label and returns it, or null if the sheet was
/// cancelled. Invalidates [taskLabelsProvider] on success so every open
/// picker's next build sees the new row without a manual refetch.
///
/// Takes no `ref` — the sheet is a [ConsumerState] and reads its own from
/// the nearest [ProviderScope], the same as any other pushed route.
Future<TaskLabel?> showCreateLabelDialog(BuildContext context) {
  return showAbAdaptiveSheet<TaskLabel>(
    context,
    child: const _CreateLabelSheet(),
  );
}

/// Confirms, deletes, and invalidates [taskLabelsProvider] — the one flow
/// [AbSelectOption.onDelete] needs, shared so the two label pickers
/// (task_create_sheet.dart, task_row_actions.dart) can't answer a refused
/// delete differently. Deleting drops the label from every task that carries
/// it — [confirmLabel] names that plainly rather than letting "Delete" read
/// as scoped to the one picker it was clicked from.
Future<bool> confirmDeleteLabel(
  BuildContext context,
  WidgetRef ref,
  TaskLabel label,
) async {
  final confirmed = await AbConfirmDialog.show(
    context: context,
    title: 'Delete "${label.name}"?',
    body: 'This removes the label from every task that has it. It cannot be '
        'undone.',
    confirmLabel: 'Delete label',
    destructive: true,
  );
  if (!confirmed) return false;
  await ref.read(tasksApiProvider).deleteLabel(label.id);
  ref.invalidate(taskLabelsProvider);
  return true;
}

class _CreateLabelSheet extends ConsumerStatefulWidget {
  const _CreateLabelSheet();

  @override
  ConsumerState<_CreateLabelSheet> createState() => _CreateLabelSheetState();
}

class _CreateLabelSheetState extends ConsumerState<_CreateLabelSheet> {
  final _name = TextEditingController();
  String _color = _kLabelSwatches.first;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final label = await ref
          .read(tasksApiProvider)
          .createLabel(name: name, color: _color);
      ref.invalidate(taskLabelsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(label);
    } on TaskApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'New label',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space8),
          AbTextField(
            controller: _name,
            hintText: 'Name',
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AbTokens.space12),
          Wrap(
            spacing: AbTokens.space8,
            runSpacing: AbTokens.space8,
            children: [
              for (final swatch in _kLabelSwatches)
                _SwatchDot(
                  colorHex: swatch,
                  selected: swatch == _color,
                  onTap: () => setState(() => _color = swatch),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AbTokens.space8),
            Text(
              _error!,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: palette.error,
              ),
            ),
          ],
          const SizedBox(height: AbTokens.space12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: _submitting ? 'Creating…' : 'Create',
                variant: AbButtonVariant.primary,
                onTap: _submitting ? null : () => _submit(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SwatchDot extends StatelessWidget {
  const _SwatchDot({
    required this.colorHex,
    required this.selected,
    required this.onTap,
  });

  final String colorHex;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final color = abLabelColor(colorHex) ?? palette.textMuted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: AbTokens.space24,
        height: AbTokens.space24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? palette.accent : palette.borderStrong,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}
