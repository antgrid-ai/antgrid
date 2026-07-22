import 'package:flutter/material.dart'
    show Dialog, Navigator, showDialog, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_text_field.dart';
import '../providers/recent_ports.dart';
import '../storage/recent_ports_store.dart';

/// Manual preview-port entry: a numeric field + "Open" action, plus
/// quick-pick chips for ports remembered for this project. Records every
/// submitted port via [recentPortsProvider]; [onSubmit] performs the actual
/// open (e.g. `previewService.selectPort`).
///
/// Used both in the preview empty state and the toolbar dialog so the two
/// entry points stay identical.
class PortEntryForm extends ConsumerStatefulWidget {
  final String projectId;
  final void Function(int port, String scheme) onSubmit;
  final bool autofocus;

  const PortEntryForm({
    super.key,
    required this.projectId,
    required this.onSubmit,
    this.autofocus = false,
  });

  @override
  ConsumerState<PortEntryForm> createState() => _PortEntryFormState();
}

class _PortEntryFormState extends ConsumerState<PortEntryForm> {
  final _controller = TextEditingController();
  bool _showError = false;
  String _scheme = 'http';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? _]) {
    final port = int.tryParse(_controller.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _showError = true);
      return;
    }
    _open(port, _scheme);
  }

  /// Records [port]/[scheme] as most-recently-used and opens it. Shared by the
  /// text field (uses the toggle scheme) and the quick-pick pills (use the
  /// remembered scheme) so reuse always promotes the port to the front of the
  /// MRU list.
  void _open(int port, String scheme) {
    ref.read(recentPortsProvider(widget.projectId).notifier).add(port, scheme);
    widget.onSubmit(port, scheme);
  }

  @override
  Widget build(BuildContext context) {
    final recent = ref.watch(recentPortsProvider(widget.projectId));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final s in const ['http', 'https']) ...[
              AbChip.toggle(
                label: s.toUpperCase(),
                selected: _scheme == s,
                onTap: () => setState(() => _scheme = s),
              ),
              const SizedBox(width: AbTokens.space4),
            ],
          ],
        ),
        const SizedBox(height: AbTokens.space8),
        Row(
          children: [
            Expanded(
              child: AbTextField(
                controller: _controller,
                autofocus: widget.autofocus,
                hintText: 'Port (e.g. 3000)',
                keyboardType: TextInputType.number,
                prefixIcon: AbIcons.link,
                onChanged: (_) {
                  if (_showError) setState(() => _showError = false);
                },
                onSubmitted: _submit,
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            AbButton(
              label: 'Open',
              variant: AbButtonVariant.primary,
              onTap: _submit,
            ),
          ],
        ),
        if (_showError) ...[
          const SizedBox(height: AbTokens.space4),
          Text(
            'Enter a port between 1 and 65535',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: context.antgrid.error,
            ),
          ),
        ],
        if (recent.isNotEmpty) ...[
          const SizedBox(height: AbTokens.space12),
          Wrap(
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space6,
            children: [
              for (final entry in recent)
                _RecentPortPill(
                  entry: entry,
                  onTap: () => _open(entry.port, entry.scheme),
                  onRemove: () => ref
                      .read(recentPortsProvider(widget.projectId).notifier)
                      .remove(entry.port),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RecentPortPill extends StatelessWidget {
  final RecentPort entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RecentPortPill({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    // Show the scheme only when it's https — http is the common default, so
    // tagging every pill would be noise.
    final label = entry.scheme == 'https'
        ? 'https://${entry.port}'
        : '${entry.port}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbChip.toggle(
          label: label,
          selected: false,
          size: AbChipSize.md,
          onTap: onTap,
        ),
        AbIconButton(
          icon: AbIcons.close,
          tone: AbIconButtonTone.muted,
          tooltip: 'Forget port ${entry.port}',
          onTap: onRemove,
        ),
      ],
    );
  }
}

/// Shows the manual port-entry form in a dialog. [onSubmit] fires with the
/// chosen port and the dialog closes.
Future<void> showPortEntryDialog(
  BuildContext context, {
  required String projectId,
  required void Function(int port, String scheme) onSubmit,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              abDialogTitle(
                'Open port',
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
              const SizedBox(height: AbTokens.space12),
              PortEntryForm(
                projectId: projectId,
                autofocus: true,
                onSubmit: (port, scheme) {
                  Navigator.of(dialogContext).pop();
                  onSubmit(port, scheme);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
