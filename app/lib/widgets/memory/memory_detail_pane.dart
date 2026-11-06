import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_disclosure.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_scrollbar.dart';
import '../../design/widgets/ab_toast.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/agent_descriptor.dart';
import '../../models/memory.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import 'memory_edit_form.dart';
import 'memory_error.dart';
import 'memory_format.dart';
import 'memory_section_label.dart';
import 'memory_tag.dart';

/// One memory's detail: view, edit, forget, earlier versions.
///
/// Wide: the pane does not scroll, its host does. Compact: it scrolls its own
/// body above a fixed action bar, so an open keyboard in edit mode scrolls the
/// form instead of overflowing it.
class MemoryDetailPane extends ConsumerStatefulWidget {
  const MemoryDetailPane({
    super.key,
    required this.target,
    required this.id,
    required this.onSaved,
    required this.onForgotten,
    this.onGone,
    this.compact = false,
  });

  final MemoryTarget target;
  final String id;
  final ValueChanged<String> onSaved;
  final VoidCallback onForgotten;
  final VoidCallback? onGone;
  final bool compact;

  @override
  ConsumerState<MemoryDetailPane> createState() => _MemoryDetailPaneState();
}

const _sectionTop = AbTokens.space24 + AbTokens.space4;

class _MemoryDetailPaneState extends ConsumerState<MemoryDetailPane> {
  bool _editing = false;
  bool _confirming = false;
  bool _earlierOpen = false;
  bool _techOpen = false;
  bool _forgetting = false;
  String? _forgetError;
  bool _goneNotified = false;

  final _scroll = ScrollController();
  final _formKey = GlobalKey<MemoryEditFormState>();

  // The design-system buttons take no FocusNode, so each button sits inside an
  // inert Focus wrapper and focus is sent to the first focusable inside it.
  final _editNode = FocusNode(
    debugLabel: 'memory edit',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final _forgetNode = FocusNode(
    debugLabel: 'memory forget',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final _keepNode = FocusNode(
    debugLabel: 'memory keep',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void dispose() {
    _scroll.dispose();
    _editNode.dispose();
    _forgetNode.dispose();
    _keepNode.dispose();
    super.dispose();
  }

  void _focusInside(FocusNode wrapper) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final node in wrapper.traversalDescendants) {
        node.requestFocus();
        return;
      }
    });
  }

  void _startEdit() {
    setState(() => _editing = true);
    // The compact bar reads the form through its key, which resolves only after
    // this frame has built it.
    if (widget.compact) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _cancelEdit() {
    setState(() => _editing = false);
    _focusInside(_editNode);
  }

  void _startConfirm() {
    setState(() {
      _confirming = true;
      _forgetError = null;
    });
    _focusInside(_keepNode);
  }

  void _closeConfirm() {
    if (_forgetting) return;
    setState(() {
      _confirming = false;
      _forgetError = null;
    });
    _focusInside(_forgetNode);
  }

  Future<void> _forget() async {
    if (_forgetting) return;
    final request = ref.read(memoryRequestProvider(widget.target));
    setState(() {
      _forgetting = true;
      _forgetError = null;
    });
    var done = false;
    try {
      await request({'op': 'forget', 'id': widget.id});
      done = true;
    } catch (error) {
      // The row is already deleted; the problems strip carries the cleanup line.
      if (memoryErrorCode(error) == 'CLEANUP_FAILED') {
        done = true;
      } else if (mounted) {
        setState(() => _forgetError = memoryErrorCopy(error, mutation: true));
      }
    } finally {
      if (mounted) setState(() => _forgetting = false);
    }
    if (!done || !mounted) return;
    showAbToast(
      context,
      'Memory forgotten',
      duration: const Duration(milliseconds: 2400),
    );
    widget.onForgotten();
  }

  void _notifyGone() {
    if (_goneNotified) return;
    _goneNotified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onGone?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = (target: widget.target, id: widget.id);
    final detail = ref.watch(memoryDetailProvider(query));
    final canSave =
        ref.watch(memoryStatusProvider(widget.target)).value?.searchReady ??
        false;
    final projects =
        ref.watch(memoryProjectsProvider(widget.target)).value ??
        MemoryProjects.empty;
    final catalog = ref.watch(agentCatalogProvider);
    return detail.when(
      // A refresh must not swap the body for a spinner: that would dispose an
      // open editor.
      skipLoadingOnReload: true,
      loading: () => const Center(child: AbLoading()),
      error: (error, _) {
        final code = memoryErrorCode(error);
        if (code == 'NOT_FOUND' || code == 'FORGOTTEN') {
          _notifyGone();
          return const AbEmptyState(
            title: 'This memory was forgotten.',
            subtitle: 'Pick another memory from the list.',
          );
        }
        return AbEmptyState.error(
          title: 'Memory unavailable',
          subtitle: memoryErrorCopy(error),
          action: AbButton(
            label: 'Retry',
            onTap: () => ref.invalidate(memoryDetailProvider(query)),
          ),
        );
      },
      data: (data) {
        final record = data.record;
        final project = projects.labelFor(record.projectId);
        final removed = projects.isRemoved(record.projectId);
        final body = _body(
          context,
          data,
          project: project,
          removed: removed,
          catalog: catalog,
          canSave: canSave,
        );
        if (!widget.compact) return body;
        return Column(
          children: [
            Expanded(
              child: AbScrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(AbTokens.space16),
                  child: body,
                ),
              ),
            ),
            _bar(context, record, canSave: canSave),
          ],
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    MemoryDetail data, {
    required String project,
    required bool removed,
    required Map<String, AgentDescriptor> catalog,
    required bool canSave,
  }) {
    final p = context.antgrid;
    final record = data.record;
    final compact = widget.compact;
    final tagSize = compact
        ? MemoryTagSize.detailCompact
        : MemoryTagSize.detail;
    final lifecycle = memoryLifecycleLabel(record);
    final agent = memoryAgentName(record, catalog);

    final tags = Padding(
      padding: const EdgeInsets.only(bottom: AbTokens.space16),
      child: Wrap(
        spacing: AbTokens.space8,
        runSpacing: AbTokens.space8,
        children: [
          MemoryTag(label: record.kindLabel, size: tagSize),
          MemoryTag(label: memoryScopeLabel(record), size: tagSize),
          if (lifecycle != null)
            MemoryTag(label: lifecycle, filled: true, size: tagSize),
        ],
      ),
    );

    if (_editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tags,
          MemoryEditForm(
            key: _formKey,
            target: widget.target,
            record: record,
            compact: compact,
            onSaved: widget.onSaved,
            onCancel: _cancelEdit,
            onChanged: () {
              if (compact && mounted) setState(() {});
            },
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tags,
        SelectableText(
          record.content,
          style: AbTokens.sansStyle(fontSize: AbTokens.fontLg, height: 1.6),
        ),
        const MemorySectionLabel('Applies when', top: _sectionTop),
        Text(
          memoryAppliesText(record, project: project),
          style: AbTokens.sansStyle(fontSize: AbTokens.fontBody, height: 1.5),
        ),
        const MemorySectionLabel('Sources', top: _sectionTop),
        if (record.evidence.isEmpty)
          Text(
            "The agent didn't cite any files.",
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              color: p.textMuted,
            ),
          )
        else
          for (final path in record.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: AbTokens.space4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: AbTokens.space2),
                      child: AbIcon(AbIcons.file, size: 14, color: p.textMuted),
                    ),
                    const SizedBox(width: AbTokens.space8),
                  ],
                  Expanded(
                    child: SelectableText(
                      path,
                      style: AbTokens.monoStyle(
                        fontSize: compact ? AbTokens.fontMd : AbTokens.fontSm,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        Padding(
          padding: const EdgeInsets.only(top: AbTokens.space24),
          child: Text(
            memorySavedLine(
              record,
              agent: agent,
              project: project,
              projectRemoved: removed,
            ),
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              color: p.textSecondary,
            ),
          ),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: AbTokens.space16),
          padding: const EdgeInsets.only(top: AbTokens.space4),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.borderSubtle)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (data.earlier.isNotEmpty)
                AbDisclosure(
                  label: memoryEarlierLabel(
                    data.earlier.length,
                    more: data.earlierHasMore,
                  ),
                  expanded: _earlierOpen,
                  onToggle: () => setState(() => _earlierOpen = !_earlierOpen),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final earlier in data.earlier)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: AbTokens.space12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                earlier.content,
                                style: AbTokens.sansStyle(
                                  fontSize: AbTokens.fontMd,
                                  color: p.textSecondary,
                                ),
                              ),
                              const SizedBox(height: AbTokens.space2),
                              Text(
                                memoryEarlierWhen(
                                  earlier,
                                  agent: memoryAgentName(earlier, catalog),
                                ),
                                style: AbTokens.sansStyle(
                                  fontSize: AbTokens.fontSm,
                                  color: p.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              AbDisclosure(
                label: 'Technical details',
                expanded: _techOpen,
                onToggle: () => setState(() => _techOpen = !_techOpen),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tech('Memory id', record.id),
                    _tech('Project id', record.projectId),
                    _tech('Session', record.taskId ?? 'Any session'),
                    _tech('Checkout', record.checkoutId ?? 'Any checkout'),
                    _tech('Saved by', memoryTechSavedBy(record)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(
              top: AbTokens.space16 + AbTokens.space4,
            ),
            child: _confirming
                ? _confirmBox(context, record)
                : _actionRow(context, record, canSave, expand: false),
          ),
      ],
    );
  }

  Widget _tech(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: AbTokens.space6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textMuted,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: AbTokens.monoStyle(fontSize: AbTokens.fontSm),
          ),
        ),
      ],
    ),
  );

  Widget _actionRow(
    BuildContext context,
    MemoryRecord record,
    bool canSave, {
    required bool expand,
  }) => memoryButtonRow([
    if (record.isCurrent) _editButton(canSave, expand: expand),
    _forgetButton(context, expand: expand),
  ], expand: expand);

  Widget _editButton(bool canSave, {required bool expand}) {
    final button = AbButton(
      label: 'Edit',
      expand: expand,
      onTap: canSave ? _startEdit : null,
    );
    return Focus(
      focusNode: _editNode,
      canRequestFocus: false,
      skipTraversal: true,
      child: canSave
          ? button
          : AbTooltip(message: 'Rebuild search before editing.', child: button),
    );
  }

  Widget _forgetButton(BuildContext context, {required bool expand}) => Focus(
    focusNode: _forgetNode,
    canRequestFocus: false,
    skipTraversal: true,
    child: AbButton(
      label: 'Forget',
      color: context.antgrid.error,
      expand: expand,
      onTap: _startConfirm,
    ),
  );

  Widget _confirmBox(BuildContext context, MemoryRecord record) {
    final p = context.antgrid;
    final compact = widget.compact;
    final replaced = record.supersededBy != null;
    final keep = Focus(
      focusNode: _keepNode,
      canRequestFocus: false,
      skipTraversal: true,
      child: AbButton(
        label: 'Keep it',
        expand: compact,
        onTap: _forgetting ? null : _closeConfirm,
      ),
    );
    final forget = AbButton(
      label: 'Forget',
      color: p.error,
      expand: compact,
      onTap: _forgetting
          ? null
          : () => detached('Memory', 'forget failed', _forget),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeConfirm,
      },
      child: Semantics(
        liveRegion: true,
        label: 'Forget this memory?',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space16,
            vertical: AbTokens.space12,
          ),
          decoration: BoxDecoration(
            color: p.bgSurface,
            border: Border.all(color: p.borderStrong),
            borderRadius: AbTokens.borderRadius8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Forget this memory?',
                style: AbTokens.sansStyle(fontSize: AbTokens.fontBody),
              ),
              const SizedBox(height: AbTokens.space6),
              Text(
                replaced
                    ? "Agents won't recall it again, and every other version of it, including the current one, is deleted too. Your files and conversations aren't touched."
                    : "Agents won't recall it again, and its earlier versions are deleted too. Your files and conversations aren't touched.",
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  color: p.textSecondary,
                  height: 1.5,
                ),
              ),
              if (_forgetError case final error?) ...[
                const SizedBox(height: AbTokens.space12),
                AbInlineBanner(text: error, color: p.error),
              ],
              const SizedBox(height: AbTokens.space12),
              memoryButtonRow([forget, keep], expand: compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, MemoryRecord record, {required bool canSave}) {
    final p = context.antgrid;
    final Widget content;
    if (_confirming) {
      content = _confirmBox(context, record);
    } else if (_editing) {
      content =
          _formKey.currentState?.actions(expand: true) ??
          const SizedBox(height: AbTokens.tapTargetMin);
    } else {
      content = _actionRow(context, record, canSave, expand: true);
    }
    return Container(
      padding: EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space16 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: p.bgDeepest,
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      child: content,
    );
  }
}
