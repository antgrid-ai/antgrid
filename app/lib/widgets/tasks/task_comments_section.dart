import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_avatar.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_loading.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';
import '../../util/detached.dart';
import '../transcript/markdown_body.dart';
import 'task_body_editor.dart';
import 'task_provenance_view.dart';

/// A task's comment thread, oldest first, with a composer under it.
///
/// On a task whose issue takes pushes, a comment written here is posted there
/// too; otherwise it stays in Antgrid. The composer says which, because the
/// difference is whether a repository's watchers read it.
class TaskCommentsSection extends ConsumerStatefulWidget {
  const TaskCommentsSection({super.key, required this.task});

  final Task task;

  @override
  ConsumerState<TaskCommentsSection> createState() =>
      _TaskCommentsSectionState();
}

class _TaskCommentsSectionState extends ConsumerState<TaskCommentsSection> {
  final _draft = TextEditingController();
  final _edit = TextEditingController();

  /// Only the draft's own failure shows under the composer; an edit or delete
  /// shows its failure on the comment it was about.
  String? _draftError;
  var _sending = false;

  String? _editingId;
  String? _confirmingDeleteId;
  String? _busyId;
  String? _rowErrorId;
  String? _rowError;

  int get _number => widget.task.number;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    _draft.removeListener(_onDraftChanged);
    _draft.dispose();
    _edit.dispose();
    super.dispose();
  }

  void _onDraftChanged() => setState(() {});

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _draftError = null;
    });
    try {
      await ref.read(taskCommentsProvider(_number).notifier).add(text);
      if (!mounted) return;
      _draft.clear();
    } on TaskApiException catch (e) {
      if (mounted) setState(() => _draftError = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _beginEdit(TaskComment comment) {
    _edit.text = comment.body;
    setState(() {
      _editingId = comment.id;
      _confirmingDeleteId = null;
      _rowErrorId = null;
    });
  }

  Future<void> _saveEdit(String id) async {
    final text = _edit.text.trim();
    if (text.isEmpty) return;
    await _rowWrite(
      id,
      () => ref.read(taskCommentsProvider(_number).notifier).edit(id, text),
      onDone: () => _editingId = null,
    );
  }

  Future<void> _delete(String id) => _rowWrite(
    id,
    () => ref.read(taskCommentsProvider(_number).notifier).remove(id),
    onDone: () => _confirmingDeleteId = null,
  );

  Future<void> _rowWrite(
    String id,
    Future<void> Function() write, {
    required VoidCallback onDone,
  }) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = id;
      _rowErrorId = null;
    });
    try {
      await write();
      if (mounted) setState(onDone);
    } on TaskApiException catch (e) {
      if (mounted) {
        setState(() {
          _rowErrorId = id;
          _rowError = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final thread = ref.watch(taskCommentsProvider(_number));
    final myUserId = ref.watch(taskUserIdProvider);

    final Widget list = switch (thread) {
      AsyncData(:final value) when value.isEmpty => _muted(
        context,
        'No comments yet.',
      ),
      AsyncData(:final value) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AbTokens.space12,
        children: [
          for (final comment in value) _comment(context, comment, myUserId),
        ],
      ),
      AsyncError(:final error) => Row(
        children: [
          Expanded(
            child: Text(
              error is TaskApiException
                  ? error.message
                  : 'The comments could not be loaded.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: palette.warning,
              ),
            ),
          ),
          AbButton(
            label: 'Retry',
            compact: true,
            onTap: () => ref.invalidate(taskCommentsProvider(_number)),
          ),
        ],
      ),
      _ => const Align(
        alignment: Alignment.centerLeft,
        child: AbLoading(message: 'Loading comments…'),
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space4,
        AbTokens.space12,
        AbTokens.space12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          list,
          const SizedBox(height: AbTokens.space12),
          _composer(context),
        ],
      ),
    );
  }

  Widget _comment(BuildContext context, TaskComment comment, String? me) {
    final palette = context.antgrid;
    final mine = comment.isAuthoredBy(me);
    final busy = _busyId == comment.id;
    final editing = _editingId == comment.id;
    final confirming = _confirmingDeleteId == comment.id;
    final name = _authorName(comment);

    final header = Row(
      children: [
        AbAvatar(name: name, size: AbTokens.iconButtonGlyph + AbTokens.space4),
        const SizedBox(width: AbTokens.space8),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: palette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: AbTokens.space8),
        Text(
          _stamp(comment.createdAt),
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: palette.textMuted,
          ),
        ),
        if (comment.imported || comment.mirrored) ...[
          const SizedBox(width: AbTokens.space8),
          Text(
            comment.imported ? 'from GitHub' : 'on GitHub',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
        const Spacer(),
        if (mine && !editing && !confirming && !busy) ...[
          AbIconButton(
            icon: AbIcons.edit,
            tooltip: 'Edit comment',
            onTap: () => _beginEdit(comment),
          ),
          AbIconButton(
            icon: AbIcons.trash,
            tooltip: 'Delete comment',
            onTap: () => setState(() {
              _confirmingDeleteId = comment.id;
              _editingId = null;
              _rowErrorId = null;
            }),
          ),
        ],
      ],
    );

    final Widget body;
    if (editing) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TaskBodyEditor(
            controller: _edit,
            hintText: 'Edit your comment.',
            minLines: 3,
            maxLines: 12,
            autofocus: true,
          ),
          const SizedBox(height: AbTokens.space8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: busy ? null : () => setState(() => _editingId = null),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: busy ? 'Saving…' : 'Save',
                variant: AbButtonVariant.primary,
                onTap: busy
                    ? null
                    : () => detached(
                        'tasks',
                        'save comment',
                        () => _saveEdit(comment.id),
                      ),
              ),
            ],
          ),
        ],
      );
    } else {
      body = TranscriptMarkdown(data: comment.body);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AbTokens.space4,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(
            left: AbTokens.iconButtonGlyph + AbTokens.space12,
          ),
          child: body,
        ),
        if (confirming)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  'Delete this comment?',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: palette.textSecondary,
                  ),
                ),
              ),
              AbButton(
                label: 'Cancel',
                compact: true,
                onTap: busy
                    ? null
                    : () => setState(() => _confirmingDeleteId = null),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: busy ? 'Deleting…' : 'Delete',
                compact: true,
                color: palette.error,
                onTap: busy
                    ? null
                    : () => detached(
                        'tasks',
                        'delete comment',
                        () => _delete(comment.id),
                      ),
              ),
            ],
          ),
        if (_rowErrorId == comment.id && _rowError != null)
          Text(
            _rowError!,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.error,
            ),
          ),
      ],
    );
  }

  Widget _composer(BuildContext context) {
    final palette = context.antgrid;
    final canSend = !_sending && _draft.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TaskBodyEditor(
          controller: _draft,
          hintText: _composerHint(widget.task),
          minLines: 3,
          maxLines: 12,
        ),
        const SizedBox(height: AbTokens.space8),
        Row(
          children: [
            Expanded(
              child: _draftError == null
                  ? const SizedBox.shrink()
                  : Text(
                      _draftError!,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: palette.error,
                      ),
                    ),
            ),
            const SizedBox(width: AbTokens.space8),
            AbButton(
              label: _sending ? 'Commenting…' : 'Comment',
              variant: AbButtonVariant.primary,
              onTap: canSend
                  ? () => detached('tasks', 'add comment', _send)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _muted(BuildContext context, String text) => Text(
    text,
    style: AbTokens.sansStyle(
      fontSize: AbTokens.fontXs,
      color: context.antgrid.textMuted,
    ),
  );

  String _authorName(TaskComment comment) => switch (comment.author) {
    TaskMemberAssignee() => comment.authorName ?? 'Antgrid member',
    TaskExternalAssignee(:final login) => '@$login',
    null => comment.imported ? 'GitHub user' : 'Former member',
  };
}

/// Mirrors the account service's push gate: a linked issue whose repository
/// takes pushes, or a publish whose create is still on its way and carries the
/// thread with it.
String _composerHint(Task task) {
  final provider = taskProviderLabel(task);
  final publishing =
      task.syncState == TaskSyncState.pending && task.externalId == null;
  if ((task.isLinked || publishing) && task.pushLive == true) {
    return 'Leave a comment. It is also posted to the $provider issue.';
  }
  if (task.isLinked) {
    return 'Leave a comment. It stays in Antgrid — this task is not '
        'sending edits to $provider right now.';
  }
  return 'Leave a comment.';
}

String _stamp(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
