import 'dart:convert';

import 'package:flutter/material.dart' show Scaffold, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_panel_header.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/memory.dart';
import '../../providers/memory.dart';
import 'memory_error.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';

const kMaxEvidenceReferences = 8;

/// One reference per line; CRLF and whitespace-only lines are not references.
List<String> parseEvidenceLines(String text) => const LineSplitter()
    .convert(text)
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList(growable: false);

class MemoryRecordDetails extends ConsumerWidget {
  const MemoryRecordDetails({
    super.key,
    required this.target,
    required this.id,
  });
  final MemoryTarget target;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = (target: target, id: id);
    final record = ref.watch(memoryDetailProvider(query));
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: SafeArea(
        child: Column(
          children: [
            AbPanelHeader(
              title: 'MEMORY DETAILS',
              actions: [
                AbIconButton(
                  icon: AbIcons.refresh,
                  tooltip: 'Refresh record',
                  onTap: () => ref.invalidate(memoryDetailProvider(query)),
                ),
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Expanded(
              child: record.when(
                // A dependency rebuild or refresh must not swap the body for a
                // spinner: that would dispose an open correction editor.
                skipLoadingOnReload: true,
                data: (record) => _RecordBody(
                  key: ValueKey(record.id),
                  target: target,
                  record: record,
                ),
                loading: () => const Center(child: AbLoading()),
                error: (error, _) => AbEmptyState.error(
                  title: 'Record unavailable',
                  subtitle: memoryErrorCopy(error),
                  action: AbButton(
                    label: 'Retry',
                    onTap: () => ref.invalidate(memoryDetailProvider(query)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordBody extends ConsumerStatefulWidget {
  const _RecordBody({super.key, required this.target, required this.record});
  final MemoryTarget target;
  final MemoryRecord record;
  @override
  ConsumerState<_RecordBody> createState() => _RecordBodyState();
}

class _RecordBodyState extends ConsumerState<_RecordBody> {
  late final _content = TextEditingController(text: widget.record.content);
  late final _applicability = TextEditingController(
    text: widget.record.applicability,
  );
  late final _evidence = TextEditingController(
    text: widget.record.evidence.join('\n'),
  );
  bool _editing = false;
  bool _busy = false;
  bool _hiddenAfterForget = false;
  bool _needsRepair = false;
  String? _error;
  String? _pendingPayload;
  String? _operationKey;

  @override
  void dispose() {
    _content.dispose();
    _applicability.dispose();
    _evidence.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final request = ref.read(memoryRequestProvider(widget.target));
    final evidence = parseEvidenceLines(_evidence.text);
    if (evidence.length > kMaxEvidenceReferences) {
      setState(
        () => _error = 'Up to $kMaxEvidenceReferences evidence references',
      );
      return;
    }
    final save = widget.record.correction(
      content: _content.text,
      applicability: _applicability.text,
      evidence: evidence,
    );
    final payload = jsonEncode(save);
    if (payload != _pendingPayload) {
      _pendingPayload = payload;
      _operationKey = const Uuid().v4();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await request({
        'op': 'save',
        'operation_key': _operationKey,
        'save': save,
      });
      if (!mounted) return;
      final id = result['id'] as String;
      final target = widget.target;
      await Navigator.of(context).pushReplacement<void, void>(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => MemoryRecordDetails(target: target, id: id),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = memoryErrorCopy(error, mutation: true));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    if (_busy) return;
    final request = ref.read(memoryRequestProvider(widget.target));
    if (!_hiddenAfterForget) {
      final confirmed = await AbConfirmDialog.show(
        context: context,
        title: 'Forget this memory?',
        body:
            'Delete this finding and its retained correction history from Antgrid Memory. Original files and conversations remain unchanged.',
        confirmLabel: 'Forget memory',
        destructive: true,
      );
      if (!mounted || !confirmed) return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hiddenAfterForget = true;
    });
    try {
      await request({'op': 'forget', 'id': widget.record.id});
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = memoryErrorCopy(error, mutation: true);
        _needsRepair = memoryErrorCode(error) == 'CLEANUP_FAILED';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repair() async {
    final request = ref.read(memoryRequestProvider(widget.target));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await request({'op': 'repair'});
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = memoryErrorCopy(error, mutation: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revision(String id) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) =>
            MemoryRecordDetails(target: widget.target, id: id),
      ),
    );
    if (!mounted) return;
    ref.invalidate(
      memoryDetailProvider((target: widget.target, id: widget.record.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    return ListView(
      padding: const EdgeInsets.all(AbTokens.space12),
      children: [
        if (_error case final error?) ...[
          AbInlineBanner(text: error, color: context.antgrid.error),
          const SizedBox(height: AbTokens.space12),
        ],
        if (_hiddenAfterForget) ...[
          Text(
            'Waiting for confirmed deletion. The cached finding is hidden.',
            style: AbTokens.sansStyle(),
          ),
          const SizedBox(height: AbTokens.space12),
          if (_needsRepair && widget.target.isProject)
            Text(
              'Open machine Memory to retry storage cleanup.',
              style: AbTokens.sansStyle(),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: AbButton(
                label: _needsRepair
                    ? 'Retry storage cleanup'
                    : 'Retry forgetting',
                onTap: _busy
                    ? null
                    : () => detached(
                        'Memory',
                        'recovery failed',
                        _needsRepair ? _repair : _forget,
                      ),
              ),
            ),
        ] else ...[
          Text(
            '${record.scope} · ${record.memoryType} · ${record.lifecycle}',
            style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
          ),
          const SizedBox(height: AbTokens.space12),
          if (_editing) ...[
            _heading('Finding'),
            AbTextField(
              controller: _content,
              minLines: 4,
              maxLines: null,
              enabled: !_busy,
            ),
            _heading('Applicability and uncertainty'),
            AbTextField(
              controller: _applicability,
              minLines: 2,
              maxLines: null,
              enabled: !_busy,
            ),
            _heading('Evidence references · one per line'),
            AbTextField(
              controller: _evidence,
              minLines: 2,
              maxLines: null,
              enabled: !_busy,
            ),
            const SizedBox(height: AbTokens.space12),
            Text(
              'A correction creates a new revision and preserves this scope and checkout restriction.',
              style: AbTokens.sansStyle(color: context.antgrid.textMuted),
            ),
            const SizedBox(height: AbTokens.space12),
            Wrap(
              spacing: AbTokens.space8,
              runSpacing: AbTokens.space8,
              children: [
                AbButton(
                  label: 'Save correction',
                  variant: AbButtonVariant.primary,
                  onTap: _busy
                      ? null
                      : () => detached('Memory', 'correction failed', _save),
                ),
                AbButton(
                  label: 'Cancel editing',
                  onTap: _busy ? null : () => setState(() => _editing = false),
                ),
              ],
            ),
          ] else ...[
            SelectableText(
              record.content,
              style: AbTokens.sansStyle(fontSize: AbTokens.fontBody),
            ),
            _heading('Applicability'),
            SelectableText(
              record.applicability.isEmpty
                  ? 'Unspecified; this is not a claim of universal applicability.'
                  : record.applicability,
              style: AbTokens.sansStyle(),
            ),
            _heading('Provenance'),
            _data('Memory', record.id),
            _data('Project', record.projectId),
            if (record.taskId case final id?) _data('Durable session', id),
            if (record.checkoutId case final id?)
              _data('Checkout restriction', id),
            for (final entry in record.source.entries)
              _data(entry.key, '${entry.value}'),
            if (record.createdAt case final date?)
              _data('Created', absoluteTime(date)),
            if (record.updatedAt case final date?)
              _data('Meaningful update', absoluteTime(date)),
            _heading('Evidence references'),
            if (record.evidence.isEmpty)
              Text(
                'No supporting references were supplied.',
                style: AbTokens.sansStyle(color: context.antgrid.textMuted),
              ),
            for (final evidence in record.evidence)
              Padding(
                padding: const EdgeInsets.only(bottom: AbTokens.space8),
                child: SelectableText(evidence, style: AbTokens.monoStyle()),
              ),
            const SizedBox(height: AbTokens.space12),
            Wrap(
              spacing: AbTokens.space8,
              runSpacing: AbTokens.space8,
              children: [
                if (record.lifecycle != 'superseded')
                  AbButton(
                    label: 'Correct finding',
                    onTap: _busy ? null : () => setState(() => _editing = true),
                  ),
                if (record.supersedes case final previous?)
                  AbButton(
                    label: 'Previous revision',
                    onTap: () => detached(
                      'Memory',
                      'history failed',
                      () => _revision(previous),
                    ),
                  ),
                if (record.supersededBy case final next?)
                  AbButton(
                    label: 'Next revision',
                    onTap: () => detached(
                      'Memory',
                      'history failed',
                      () => _revision(next),
                    ),
                  ),
                AbButton(
                  label: 'Forget memory',
                  color: context.antgrid.error,
                  onTap: _busy
                      ? null
                      : () => detached('Memory', 'forget failed', _forget),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(
      top: AbTokens.space16,
      bottom: AbTokens.space8,
    ),
    child: Text(text, style: AbTokens.sansStyle(fontWeight: FontWeight.w600)),
  );

  Widget _data(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: AbTokens.space8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AbTokens.sansStyle(color: context.antgrid.textMuted),
        ),
        SelectableText(value, style: AbTokens.monoStyle()),
      ],
    ),
  );
}
