import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_panel_header.dart';
import '../design/widgets/ab_switch.dart';
import '../design/widgets/ab_text_field.dart';
import '../models/file_tree_models.dart';
import '../models/memory.dart';
import '../providers/memory.dart';
import '../providers/memory_route_targets.dart';
import '../services/memory_service.dart';
import '../util/detached.dart';
import '../widgets/file_download.dart';
import '../widgets/memory/memory_record_details.dart';
import '../widgets/memory/memory_error.dart';

Future<void> openMemoryScreen(BuildContext context, MemoryTarget target) async {
  final route = PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => MemoryScreen(target: target),
  );
  final machineId = target.machineId;
  final release = machineId == null
      ? null
      : ProviderScope.containerOf(
          context,
          listen: false,
        ).read(memoryRouteTargetsProvider.notifier).retain(machineId);
  try {
    // push's future only yields the pop result; it can outlive a disposed
    // Navigator. completed covers both teardown and the dismissal animation.
    unawaited(Navigator.of(context).push<void>(route));
    await route.completed;
  } finally {
    release?.call();
  }
}

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key, required this.target});
  final MemoryTarget target;
  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _history = false;
  int _offset = 0;
  bool _busy = false;
  String? _actionError;
  MemoryQuery get _view => (
    target: widget.target,
    query: _query,
    history: _history,
    offset: _offset,
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() => ref.invalidate(memorySnapshotProvider(_view));

  Future<void> _act(Map<String, dynamic> operation) async {
    if (_busy) return;
    final request = ref.read(memoryRequestProvider(widget.target));
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await request(operation);
      if (!mounted) return;
      _reload();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = memoryErrorCopy(error, mutation: true));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_busy) return;
    final route = ModalRoute.of(context);
    bool isActive() => mounted && (route?.isActive ?? true);
    final request = ref.read(memoryRequestProvider(widget.target));
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final exported = await collectMemoryExport(request, isActive: isActive);
      if (!mounted || route?.isActive == false || exported == null) return;
      final text = const JsonEncoder.withIndent(
        '  ',
      ).convert(exported.toJson());
      await downloadFileContent(
        context,
        FileContent(
          path: 'antgrid-memory.json',
          content: text,
          size: utf8.encode(text).length,
          utf8Valid: true,
          mimeType: 'application/json',
        ),
      );
    } catch (error) {
      if (!mounted || route?.isActive == false) return;
      setState(() => _actionError = memoryErrorCopy(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspect(MemoryRecord record) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) =>
            MemoryRecordDetails(target: widget.target, id: record.id),
      ),
    );
    if (mounted) _reload();
  }

  void _searchNow() {
    setState(() {
      _query = _search.text.trim();
      _offset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(memorySnapshotProvider(_view));
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: SafeArea(
        child: Column(
          children: [
            AbPanelHeader(
              title: 'MEMORY · ${widget.target.label}',
              actions: [
                AbIconButton(
                  icon: AbIcons.refresh,
                  tooltip: 'Refresh memory',
                  onTap: _busy ? null : _reload,
                ),
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            if (_actionError case final error?)
              AbInlineBanner(text: error, color: context.antgrid.error),
            Expanded(
              child: snapshot.when(
                skipLoadingOnRefresh: false,
                data: _content,
                loading: () => const Center(child: AbLoading()),
                error: (error, _) => AbEmptyState.error(
                  title: 'Memory unavailable',
                  subtitle: memoryErrorCopy(error),
                  action: AbButton(
                    label: 'Reconnect and retry',
                    onTap: _reload,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(MemorySnapshot snapshot) {
    final status = snapshot.status;
    if (!status.available) {
      return AbEmptyState.error(
        title: 'Memory unavailable',
        subtitle:
            '${status.error ?? 'The memory store could not be opened. Agent sessions can continue.'}'
            '${widget.target.isProject ? '\nOpen machine Memory to retry store recovery.' : ''}',
        action: widget.target.isProject
            ? AbButton(label: 'Refresh status', onTap: _reload)
            : AbButton(
                label: 'Retry store recovery',
                onTap: _busy
                    ? null
                    : () => detached(
                        'Memory',
                        'recovery failed',
                        () => _act({'op': 'repair'}),
                      ),
              ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AbTokens.space12),
      children: [
        Text(
          widget.target.isProject
              ? 'Project and task memories on this machine.'
              : 'User memories and all project histories on this machine, including removed projects.',
          style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          'Saved findings are untrusted reference material. Repository instructions remain authoritative.',
          style: AbTokens.sansStyle(color: context.antgrid.textMuted),
        ),
        const SizedBox(height: AbTokens.space12),
        if (!status.enabled) ...[
          Text(
            'Enable local cross-agent memory',
            style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AbTokens.space8),
          Text(
            'Terminal agents with memory tools may save useful findings automatically for this local profile. Recall happens on demand. Native agent memory stays unchanged.',
            style: AbTokens.sansStyle(),
          ),
          const SizedBox(height: AbTokens.space8),
          Align(
            alignment: Alignment.centerLeft,
            child: AbButton(
              label: 'Enable memory',
              variant: AbButtonVariant.primary,
              onTap: _busy
                  ? null
                  : () => detached(
                      'Memory',
                      'enable failed',
                      () => _act({'op': 'settings', 'enabled': true}),
                    ),
            ),
          ),
        ] else ...[
          if (widget.target.isProject)
            _toggle(
              'Pause saves from this project',
              status.projectPaused,
              (value) => _act({'op': 'settings', 'project_paused': value}),
            )
          else
            _toggle(
              'Pause all agent saves',
              status.paused,
              (value) => _act({'op': 'settings', 'paused': value}),
            ),
          Text(
            'Pausing also blocks explicit remember requests. Recall, corrections and forgetting remain available.',
            style: AbTokens.sansStyle(color: context.antgrid.textMuted),
          ),
          if (widget.target.isProject && status.paused)
            Padding(
              padding: const EdgeInsets.only(top: AbTokens.space8),
              child: Text(
                'All agent saves are paused for this local profile.',
                style: AbTokens.sansStyle(color: context.antgrid.warning),
              ),
            ),
        ],
        if (status.pendingOperations > 0)
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space12),
            child: Text(
              '${status.pendingOperations} pending save operations. Recovery waits for a verified live session.',
              style: AbTokens.sansStyle(color: context.antgrid.warning),
            ),
          ),
        if (status.failedOperations > 0)
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space12),
            child: Text(
              '${status.failedOperations} save operations conflicted; inspect current findings before saving again.',
              style: AbTokens.sansStyle(color: context.antgrid.warning),
            ),
          ),
        if (status.recoveryStatus == 'cleanup_failed')
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space12),
            child: AbInlineBanner(
              text:
                  'Cleanup failed. Forgotten content is excluded from recall; storage cleanup still needs recovery.',
              color: context.antgrid.error,
              footer: widget.target.isProject
                  ? Text(
                      'Open machine Memory to retry cleanup.',
                      style: AbTokens.sansStyle(),
                    )
                  : AbButton(
                      label: 'Retry storage cleanup',
                      onTap: _busy
                          ? null
                          : () => detached(
                              'Memory',
                              'cleanup failed',
                              () => _act({'op': 'repair'}),
                            ),
                    ),
            ),
          ),
        if (status.searchStatus != 'ready')
          Padding(
            padding: const EdgeInsets.only(top: AbTokens.space12),
            child: AbInlineBanner(
              text:
                  'Search is unavailable. Saved records remain available for inspection.',
              color: context.antgrid.warning,
              footer: widget.target.isProject
                  ? null
                  : AbButton(
                      label: 'Repair search index',
                      onTap: _busy
                          ? null
                          : () => detached(
                              'Memory',
                              'repair failed',
                              () => _act({'op': 'repair'}),
                            ),
                    ),
            ),
          ),
        const SizedBox(height: AbTokens.space16),
        Row(
          children: [
            Expanded(
              child: AbTextField(
                controller: _search,
                hintText: 'Search findings or "quoted phrases"',
                prefixIcon: AbIcons.search,
                onSubmitted: (_) => _searchNow(),
                showClearButton: true,
                onClear: _searchNow,
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            AbButton(
              label: 'Search',
              onTap: status.searchStatus == 'ready' ? _searchNow : null,
            ),
          ],
        ),
        const SizedBox(height: AbTokens.space8),
        if (snapshot.resultError case final error?) ...[
          AbInlineBanner(
            text: memoryErrorCopy(error),
            color: context.antgrid.error,
          ),
          const SizedBox(height: AbTokens.space8),
        ],
        _toggle('Include retained history', _history, (value) {
          setState(() {
            _history = value;
            _offset = 0;
          });
          return Future<void>.value();
        }),
        if (_query.isNotEmpty && _history)
          Text(
            'Search shows current findings. Clear the search to browse expired and superseded records.',
            style: AbTokens.sansStyle(color: context.antgrid.textMuted),
          ),
        const SizedBox(height: AbTokens.space8),
        if (snapshot.records.isEmpty && snapshot.resultError == null)
          const Padding(
            padding: EdgeInsets.all(AbTokens.space16),
            child: AbEmptyState.compact(title: 'No memories in this view.'),
          ),
        for (final record in snapshot.records)
          AbListRow(
            title: Text(record.content),
            titleMaxLines: 3,
            subtitle: Text(
              '${record.scope} · ${record.memoryType} · ${record.lifecycle}${record.excerpted ? ' · excerpt — open for full finding' : ''}${record.applicability.isEmpty ? '' : '\n${record.applicability}'}',
            ),
            subtitleMaxLines: 4,
            divider: true,
            onTap: () =>
                detached('Memory', 'inspection failed', () => _inspect(record)),
          ),
        const SizedBox(height: AbTokens.space12),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: AbTokens.space8,
          children: [
            if (_offset > 0)
              AbButton(
                label: 'First page',
                onTap: () => setState(() => _offset = 0),
              ),
            if (snapshot.hasMore && _query.isEmpty)
              AbButton(
                label: 'Next page',
                onTap: () => setState(() => _offset += snapshot.records.length),
              ),
            if (snapshot.hasMore && _query.isNotEmpty)
              Text(
                'More matches exist. Refine your search.',
                style: AbTokens.sansStyle(color: context.antgrid.textMuted),
              ),
            AbButton(
              label: 'Export JSON',
              onTap: _busy
                  ? null
                  : () => detached('Memory', 'export failed', _export),
            ),
          ],
        ),
      ],
    );
  }

  Widget _toggle(
    String label,
    bool value,
    Future<void> Function(bool) action,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AbTokens.sansStyle())),
        const SizedBox(width: AbTokens.space8),
        AbSwitch(
          value: value,
          semanticLabel: label,
          onChanged: _busy
              ? null
              : (next) =>
                    detached('Memory', 'setting failed', () => action(next)),
        ),
      ],
    ),
  );
}
