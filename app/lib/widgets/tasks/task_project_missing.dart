import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../launcher/host_control_client.dart';
import '../../providers/control_plane.dart';
import '../../providers/projects.dart';
import '../../providers/task_project_source.dart';
import '../../util/detached.dart';
import '../../utils/platform_utils.dart';
import '../open_folder_button.dart';

/// Shown in place of a dead Start button when the task's repository is not one
/// of the folders opened on this machine: either point at an existing checkout
/// or clone it. Either way the folder is registered and focused, so the session
/// the task starts lands in the right repository.
class TaskProjectMissing extends ConsumerStatefulWidget {
  const TaskProjectMissing({super.key, required this.source});

  final TaskProjectSource source;

  @override
  ConsumerState<TaskProjectMissing> createState() => _TaskProjectMissingState();
}

class _TaskProjectMissingState extends ConsumerState<TaskProjectMissing> {
  bool _busy = false;
  String? _error;

  Future<void> _open() async {
    // Captured before the first await: the picker outlives this build.
    final container = ref.container;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await openFolderPicker(container);
    } catch (e) {
      _fail('Could not open that folder: $e');
      return;
    }
    _done();
  }

  Future<void> _clone() async {
    final container = ref.container;
    final url = widget.source.cloneUrl;
    if (url == null) return;

    final parent = await getDirectoryPath(confirmButtonText: 'Clone here');
    if (parent == null) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    HostControlClient? client;
    try {
      final host = await container.read(hostControllerProvider).ensureHost();
      client = HostControlClient(port: host.controlPort, token: host.token);
      final path = await client.gitClone(url: url, parentDir: parent);
      final id = await registerPickedFolder(container, path);
      // The host only reports a repository key once the folder's transport
      // opens, so seed it now: otherwise this task still reads as
      // "not on this machine" until then.
      if (id != null) {
        final key = widget.source.project.repoKey;
        for (final p in container.read(projectsProvider)) {
          if (p.projectId != id || p.repoKey == key) continue;
          p.repoKey = key;
          await container.read(projectsProvider.notifier).upsert(p);
          break;
        }
      }
    } on HostControlException catch (e) {
      _fail(e.message);
      return;
    } catch (e) {
      _fail('Clone failed: $e');
      return;
    } finally {
      client?.close();
    }
    _done();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  void _done() {
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final name = widget.source.project.displayName;

    if (isMobilePlatform) {
      return Text(
        '$name isn’t open on any machine you’re connected to. Expand a '
        'machine that has it in the sidebar to start from here, or open or '
        'clone it from a desktop.',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXxs,
          color: palette.textMuted,
        ),
      );
    }

    final canClone = widget.source.cloneUrl != null;
    final error = _error;
    final message = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Repository not on this machine',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            fontWeight: FontWeight.w500,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: AbTokens.space4),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: name,
                style: AbTokens.monoStyle(fontSize: AbTokens.fontXs),
              ),
              TextSpan(
                text: canClone
                    ? ' needs to be cloned or opened before you can start a '
                          'session.'
                    : ' needs to be opened before you can start a session.',
              ),
            ],
          ),
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: palette.textSecondary,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: AbTokens.space6),
          Text(
            error,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.error,
            ),
          ),
        ],
      ],
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbButton(
          label: 'Open folder…',
          onTap: _busy ? null : () => detached('tasks', 'open folder', _open),
        ),
        if (canClone) ...[
          const SizedBox(width: AbTokens.space8),
          AbButton(
            label: _busy ? 'Working…' : 'Clone repo',
            variant: AbButtonVariant.primary,
            onTap: _busy
                ? null
                : () => detached('tasks', 'clone project', _clone),
          ),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space14,
      ),
      decoration: BoxDecoration(
        // Warning-tinted rather than an error: nothing failed, there is a step
        // to take first.
        color: palette.warning.withValues(alpha: _tintAlpha),
        borderRadius: AbTokens.borderRadius8,
        border: Border.all(
          color: palette.warning.withValues(alpha: _edgeAlpha),
        ),
      ),
      // Side by side while the buttons fit beside the message; stacked under
      // it otherwise, so the message never squeezes to a word per line.
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= _sideBySideMinWidth
            ? Row(
                children: [
                  Expanded(child: message),
                  const SizedBox(width: AbTokens.space16),
                  buttons,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  message,
                  const SizedBox(height: AbTokens.space12),
                  buttons,
                ],
              ),
      ),
    );
  }
}

const _tintAlpha = 0.08;
const _edgeAlpha = 0.3;
const _sideBySideMinWidth = 520.0;
