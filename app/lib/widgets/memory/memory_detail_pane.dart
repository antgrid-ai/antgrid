import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_toast.dart';
import '../../models/memory.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/memory.dart';
import '../../util/detached.dart';
import 'memory_edit_form.dart';
import 'memory_empty_state.dart';
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

const _sectionTop = CarbonSpacing.spacing06 + CarbonSpacing.spacing02;

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

  final _editNode = FocusNode(debugLabel: 'memory edit');
  final _forgetNode = FocusNode(debugLabel: 'memory forget');
  final _keepNode = FocusNode(debugLabel: 'memory keep');

  @override
  void dispose() {
    _scroll.dispose();
    _editNode.dispose();
    _forgetNode.dispose();
    _keepNode.dispose();
    super.dispose();
  }

  // The target button only exists once this frame has built it.
  void _focus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
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
    _focus(_editNode);
  }

  void _startConfirm() {
    setState(() {
      _confirming = true;
      _forgetError = null;
    });
    _focus(_keepNode);
  }

  void _closeConfirm() {
    if (_forgetting) return;
    setState(() {
      _confirming = false;
      _forgetError = null;
    });
    _focus(_forgetNode);
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
    final labels = ref.watch(agentLabelsProvider);
    return detail.when(
      // A refresh must not swap the body for a spinner: that would dispose an
      // open editor.
      skipLoadingOnReload: true,
      loading: () =>
          const Center(child: CarbonLoading(size: CarbonLoadingSize.small)),
      error: (error, _) {
        final code = memoryErrorCode(error);
        if (code == 'NOT_FOUND' || code == 'FORGOTTEN') {
          _notifyGone();
          return const MemoryEmptyState(
            title: 'This memory was forgotten.',
            subtitle: 'Pick another memory from the list.',
          );
        }
        return MemoryEmptyState(
          error: true,
          title: 'Memory unavailable',
          subtitle: memoryErrorCopy(error),
          action: CarbonButton(
            label: 'Retry',
            kind: CarbonButtonKind.tertiary,
            onPressed: () => ref.invalidate(memoryDetailProvider(query)),
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
          labels: labels,
          canSave: canSave,
        );
        if (!widget.compact) return body;
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                child: body,
              ),
            ),
            _bar(context, record, canSave: canSave),
          ],
        );
      },
    );
  }

  Widget _disclosure({
    required String label,
    required bool open,
    required VoidCallback onToggle,
    required Widget child,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Pulled out by the ghost button's own inset so the label lines up
      // with the text above it, as a flush Carbon accordion does; the hover
      // fill bleeds into the margin instead.
      Builder(
        builder: (context) => Transform.translate(
          offset: Offset(
            Directionality.of(context) == TextDirection.rtl
                ? CarbonSpacing.spacing05
                : -CarbonSpacing.spacing05,
            0,
          ),
          child: CarbonButton(
            label: label,
            kind: CarbonButtonKind.ghost,
            size: CarbonButtonSize.small,
            icon: CarbonIcon(
              open ? CarbonIcons.chevronUp : CarbonIcons.chevronDown,
            ),
            expanded: open,
            onPressed: onToggle,
          ),
        ),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing03),
          child: child,
        ),
    ],
  );

  Widget _body(
    BuildContext context,
    MemoryDetail data, {
    required String project,
    required bool removed,
    required Map<String, String> labels,
    required bool canSave,
  }) {
    final t = CarbonTheme.of(context);
    final record = data.record;
    final compact = widget.compact;
    final tagSize = compact
        ? MemoryTagSize.detailCompact
        : MemoryTagSize.detail;
    final lifecycle = memoryLifecycleLabel(record);
    final agent = memoryAgentName(record, labels);
    final body = t.typography.body.copyWith(color: t.colors.textPrimary);

    final tags = Padding(
      padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing05),
      child: Wrap(
        spacing: CarbonSpacing.spacing03,
        runSpacing: CarbonSpacing.spacing03,
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
        _recordText(record),
        const MemorySectionLabel('Applies when', top: _sectionTop),
        Text(memoryAppliesText(record, project: project), style: body),
        const MemorySectionLabel('Sources', top: _sectionTop),
        if (record.evidence.isEmpty)
          Text(
            "The agent didn't cite any files.",
            style: body.copyWith(color: t.colors.textSecondary),
          )
        else
          for (final path in record.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing02),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: CarbonSpacing.spacing01,
                      ),
                      child: CarbonIcon(
                        CarbonIcons.document,
                        color: t.colors.iconSecondary,
                      ),
                    ),
                    const SizedBox(width: CarbonSpacing.spacing03),
                  ],
                  Expanded(
                    child: SelectableText(
                      path,
                      style: t.typography.code.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        Padding(
          padding: const EdgeInsets.only(top: CarbonSpacing.spacing06),
          child: Text(
            memorySavedLine(
              record,
              agent: agent,
              project: project,
              projectRemoved: removed,
            ),
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: CarbonSpacing.spacing05),
          padding: const EdgeInsets.only(top: CarbonSpacing.spacing02),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.borderSubtle(1))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (data.earlier.isNotEmpty)
                _disclosure(
                  label: memoryEarlierLabel(
                    data.earlier.length,
                    more: data.earlierHasMore,
                  ),
                  open: _earlierOpen,
                  onToggle: () => setState(() => _earlierOpen = !_earlierOpen),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final earlier in data.earlier)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: CarbonSpacing.spacing04,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _recordText(earlier, earlier: true),
                              const SizedBox(height: CarbonSpacing.spacing01),
                              Text(
                                memoryEarlierWhen(
                                  earlier,
                                  agent: memoryAgentName(earlier, labels),
                                ),
                                style: t.typography.helper.copyWith(
                                  color: t.colors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              _disclosure(
                label: 'Technical details',
                open: _techOpen,
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
              top: CarbonSpacing.spacing05 + CarbonSpacing.spacing02,
            ),
            child: _confirming
                ? _confirmBox(context, record)
                : _actionRow(context, record, canSave, expand: false),
          ),
      ],
    );
  }

  Widget _recordText(MemoryRecord record, {bool earlier = false}) {
    final t = CarbonTheme.of(context);
    final secondary = t.colors.textSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (record.title case final title?) ...[
          SelectableText(
            title,
            style: (earlier ? t.typography.heading : t.typography.headingLarge)
                .copyWith(color: t.colors.textPrimary),
          ),
          const SizedBox(height: CarbonSpacing.spacing03),
        ],
        if (record.description case final description?) ...[
          SelectableText(
            description,
            style: (earlier ? t.typography.helper : t.typography.body)
                .copyWith(color: secondary),
          ),
          const SizedBox(height: CarbonSpacing.spacing03),
        ],
        SelectableText(
          record.content,
          style: (earlier ? t.typography.helper : t.typography.body).copyWith(
            color: earlier ? secondary : t.colors.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _tech(String label, String value) {
    final t = CarbonTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing03),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: CarbonSpacing.spacing08 * 2 + CarbonSpacing.spacing03,
            child: Text(
              label,
              style: t.typography.label.copyWith(color: t.colors.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: t.typography.code.copyWith(color: t.colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    MemoryRecord record,
    bool canSave, {
    required bool expand,
  }) => memoryButtonRow([
    if (record.isCurrent) _editButton(canSave),
    _forgetButton(),
  ], expand: expand);

  Widget _editButton(bool canSave) => CarbonTooltip(
    enabled: !canSave,
    message: 'Rebuild search before editing.',
    child: CarbonButton(
      label: 'Edit',
      kind: CarbonButtonKind.tertiary,
      focusNode: _editNode,
      onPressed: canSave ? _startEdit : null,
    ),
  );

  Widget _forgetButton() => CarbonButton(
    label: 'Forget',
    kind: CarbonButtonKind.dangerTertiary,
    focusNode: _forgetNode,
    onPressed: _startConfirm,
  );

  Widget _confirmBox(BuildContext context, MemoryRecord record) {
    final t = CarbonTheme.of(context);
    final compact = widget.compact;
    final replaced = record.supersededBy != null;
    final keep = CarbonButton(
      label: 'Keep it',
      kind: CarbonButtonKind.secondary,
      focusNode: _keepNode,
      onPressed: _forgetting ? null : _closeConfirm,
    );
    final forget = CarbonButton(
      label: 'Forget',
      kind: CarbonButtonKind.danger,
      busy: _forgetting,
      onPressed: _forgetting
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
        child: SizedBox(
          width: double.infinity,
          child: CarbonLayerSurface(
            border: true,
            padding: const EdgeInsets.symmetric(
              horizontal: CarbonSpacing.spacing05,
              vertical: CarbonSpacing.spacing04,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: CarbonSpacing.spacing03,
              children: [
                Text(
                  'Forget this memory?',
                  style: t.typography.heading.copyWith(
                    color: t.colors.textPrimary,
                  ),
                ),
                Text(
                  replaced
                      ? "Agents won't recall it again, and every other version of it, including the current one, is deleted too. Your files and conversations aren't touched."
                      : "Agents won't recall it again, and its earlier versions are deleted too. Your files and conversations aren't touched.",
                  style: t.typography.body.copyWith(
                    color: t.colors.textSecondary,
                  ),
                ),
                if (_forgetError case final error?)
                  CarbonNotification(
                    kind: CarbonNotificationKind.error,
                    subtitle: error,
                  ),
                memoryButtonRow([keep, forget], expand: compact),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(
    BuildContext context,
    MemoryRecord record, {
    required bool canSave,
  }) {
    final t = CarbonTheme.of(context);
    final Widget content;
    if (_confirming) {
      content = _confirmBox(context, record);
    } else if (_editing) {
      content =
          _formKey.currentState?.actions(expand: true) ??
          SizedBox(height: t.minTarget);
    } else {
      content = _actionRow(context, record, canSave, expand: true);
    }
    return Container(
      padding: EdgeInsets.fromLTRB(
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing04,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing05 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: t.colors.background,
        border: Border(top: BorderSide(color: t.borderSubtle(1))),
      ),
      child: content,
    );
  }
}
