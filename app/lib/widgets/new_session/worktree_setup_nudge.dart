import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/storage_scope.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_snack_bar.dart';
import '../../models/ab_config.dart';
import '../../models/file_tree_models.dart';
import '../../project/project_session.dart';
import '../../project/project_session_registry.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/providers.dart';
import '../../services/file_service.dart';
import '../../util/detached.dart';

/// Copy sources a starter block seeds when the project shows evidence of env
/// files. Their untracked siblings are exactly what a fresh worktree lacks.
const Set<String> _envTemplateNames = {
  '.env.example',
  '.env.sample',
  '.env.template',
  'env.example',
};

/// Root lockfile → the install command that reproduces it. Ordered: a repo
/// carrying two lockfiles is answered by the first match, which puts the
/// package managers that write a lockfile of their own ahead of npm's.
const List<(String, String)> _lockfileInstallCommands = [
  ('bun.lock', 'bun install'),
  ('bun.lockb', 'bun install'),
  ('pnpm-lock.yaml', 'pnpm install'),
  ('yarn.lock', 'yarn install'),
  ('package-lock.json', 'npm install'),
  ('pubspec.lock', 'flutter pub get'),
  ('Cargo.lock', 'cargo fetch'),
  ('uv.lock', 'uv sync'),
  ('poetry.lock', 'poetry install'),
  ('Gemfile.lock', 'bundle install'),
  ('composer.lock', 'composer install'),
  ('go.sum', 'go mod download'),
];

/// Projects whose worktree-setup nudge has been answered — dismissed, or
/// configured from here.
///
/// Persisted, and keyed per project rather than per install: the nudge explains
/// one fact about one project's checkout, so a user who has answered it for
/// this repo should never see it again for this repo, and a second repo with
/// the same gap still deserves the warning.
class WorktreeSetupNudgeSeen extends AsyncNotifier<Set<String>> {
  static final _key = scopedStorageKey('antgrid.worktree_setup_nudge.v1');

  /// Cacheless [SharedPreferencesAsync] rather than a `WithCache` store: those
  /// are opened in `main()` and injected through a throwing override, and this
  /// key has exactly one reader and one writer, both on a cold user-driven path.
  @override
  Future<Set<String>> build() async {
    final stored = await SharedPreferencesAsync().getStringList(_key);
    return stored?.toSet() ?? const <String>{};
  }

  Future<void> markSeen(String entryId) async {
    final current = state.value ?? const <String>{};
    if (current.contains(entryId)) return;
    final next = {...current, entryId};
    state = AsyncData(next);
    await SharedPreferencesAsync().setStringList(_key, next.toList());
  }
}

final worktreeSetupNudgeSeenProvider =
    AsyncNotifierProvider<WorktreeSetupNudgeSeen, Set<String>>(
      WorktreeSetupNudgeSeen.new,
    );

/// Whether [entryId]'s `antgrid.yaml` already declares a `worktree.setup`
/// block, or null when that cannot be answered from here.
///
/// Answered from the project's own `ConfigService`, which re-reads the config
/// on every establishment and holds it — so a warm project costs nothing on
/// the wire. Nothing here ever ASKS: the New Session canvas renders from cache
/// and connects only on an explicit action, and a cold project answering null
/// is the intended outcome, not a gap. The nudge then shows redundantly at
/// worst, and the write path corrects itself when it finds a block already
/// there.
final _worktreeSetupDeclaredProvider = StreamProvider.autoDispose
    .family<bool?, String>((ref, entryId) async* {
      if (!ref.watch(projectSessionRegistryProvider).contains(entryId)) {
        yield null;
        return;
      }
      final session = ref.watch(projectSessionProvider(entryId)).value;
      if (session == null) {
        yield null;
        return;
      }
      final config = session.configService;
      yield _declaresSetup(config.currentState.config);
      await for (final state in config.stateStream) {
        yield _declaresSetup(state.config);
      }
    });

/// Null where [config] is not known yet — "no config in hand" and "a config
/// with no setup block" drive opposite answers and must not collapse.
bool? _declaresSetup(AbConfig? config) =>
    config == null ? null : config.worktree?['setup'] != null;

/// One-time warning that an isolated session starts from a tree holding only
/// tracked files, offered on the New Session canvas the moment the user opts
/// into one.
///
/// Mounted unconditionally and self-gating, like the remote-access nudge
/// beside it, so the call site stays one stable line.
///
/// The gate is deliberately asymmetric: the nudge hides on PROOF that the
/// project already declares setup steps and shows on the absence of proof.
/// Only a warm project holds that proof, and the canvas will not warm one to
/// ask; showing a redundant warning once costs a dismissal, while suppressing
/// a real one costs a broken checkout the user gets no explanation for.
class WorktreeSetupNudge extends ConsumerWidget {
  const WorktreeSetupNudge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Isolation is an ephemeral opt-in, so this tracks the toggle rather than
    // the project: nothing is claimed about a shared session, whose working
    // tree is the one the user is already looking at.
    if (!ref.watch(newSessionIsolatedProvider)) return const SizedBox.shrink();
    // A target whose bridge cannot make worktrees at all never reaches the
    // create path this warns about.
    if (!ref.watch(newSessionIsolationReadyProvider)) {
      return const SizedBox.shrink();
    }
    final target = ref.watch(selectedTargetProjectProvider);
    if (target == null) return const SizedBox.shrink();

    // Null covers both the first frames of the async read and a storage
    // failure: an unanswerable "has this been dismissed" must not flash the
    // nudge at a user who already dismissed it.
    final seen = ref.watch(worktreeSetupNudgeSeenProvider).value;
    if (seen == null || seen.contains(target.id)) {
      return const SizedBox.shrink();
    }
    if (ref.watch(_worktreeSetupDeclaredProvider(target.id)).value == true) {
      return const SizedBox.shrink();
    }

    final t = context.antgrid;
    final entryId = target.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space8,
        ),
        decoration: BoxDecoration(
          color: t.bgSurface,
          border: Border.all(color: t.borderSubtle),
          borderRadius: BorderRadius.circular(AbTokens.radius8),
        ),
        child: Row(
          children: [
            AbIcon(AbIcons.info, size: 13, color: t.textMuted),
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: Text(
                'Isolated sessions start from a clean checkout — ignored files '
                "like .env and node_modules aren't there.",
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: t.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space10),
            AbButton(
              label: 'Add setup steps',
              compact: true,
              // The container, not `ref`: the write outlives this widget by
              // design — it retires the nudge on success, and a layout change
              // or a target switch can tear the canvas down mid-flight.
              onTap: () => detached(
                'NEW_SESSION',
                'write worktree.setup starter block',
                () => _applyStarterSetup(context, ref.container, entryId),
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            AbIconButton(
              icon: AbIcons.close,
              tone: AbIconButtonTone.muted,
              tooltip: "Dismiss — won't ask again for this project",
              onTap: () => detached(
                'NEW_SESSION',
                'dismiss worktree.setup nudge',
                () => ref
                    .read(worktreeSetupNudgeSeenProvider.notifier)
                    .markSeen(entryId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seeds a starter `worktree.setup` block from the main checkout's tracked
/// files and writes it into [entryId]'s `antgrid.yaml`.
///
/// Warms the project rather than reading it: this is an explicit button press,
/// and the windows where the canvas holds no live session for the target — a
/// remote machine it has never dialled, a project evicted from the warm set —
/// are exactly the ones the button has to work in.
Future<void> _applyStarterSetup(
  BuildContext context,
  ProviderContainer container,
  String entryId,
) async {
  void say(String message) {
    if (context.mounted) showAbSnackBar(context, message);
  }

  final session = await warmServiceFor<ProjectSession>(
    container,
    entryId,
    (s) => s,
    // Past warmServiceFor's default: a remote target may be a cold machine
    // whose socket and E2E handshake still have to come up.
    timeout: const Duration(seconds: 30),
  );
  if (session == null) {
    say("Couldn't reach this project. Open it and try again.");
    return;
  }

  // The MAIN checkout's config service, which is what `ProjectSession` exposes
  // directly: the block describes how a managed checkout is provisioned, so it
  // belongs in the project's own `antgrid.yaml` and never in a worktree's copy,
  // which is thrown away with the session.
  final configService = session.configService;
  final AbConfig config;
  try {
    final read = await configService.read();
    if (read != null) {
      config = read;
    } else {
      // A read the bridge ANSWERED with no usable config. With a raw body or a
      // parse error the file exists and does not parse — refuse, rather than
      // replace a file the user still has to fix by hand. Without either there
      // is no `antgrid.yaml` at all, and writing one is what this action is for.
      final state = configService.currentState;
      if (state.rawOnError != null || state.error != null) {
        say("Couldn't read this project's antgrid.yaml.");
        return;
      }
      config = const AbConfig();
    }
  } on TimeoutException {
    say("The machine didn't answer. Try again.");
    return;
  } on StateError {
    // The config service was torn down under the request (an LRU eviction, a
    // host restart) or a settings screen superseded the read.
    say('This project reconnected. Try again.');
    return;
  }

  if (_declaresSetup(config) == true) {
    // Configured elsewhere — another device, an editor — between the nudge
    // rendering and this press. Retire it rather than overwrite that.
    await container
        .read(worktreeSetupNudgeSeenProvider.notifier)
        .markSeen(entryId);
    say('This project already declares worktree setup steps.');
    return;
  }

  final setup = buildStarterWorktreeSetup(
    await _awaitTreeRoot(session.fileService),
  );
  final List<String>? errors;
  try {
    errors = await configService.save(
      config.copyWith(worktree: {...?config.worktree, 'setup': setup}),
    );
  } on TimeoutException {
    say("The machine didn't answer. antgrid.yaml may be unchanged.");
    return;
  } on StateError {
    say('This project reconnected. antgrid.yaml may be unchanged.');
    return;
  }
  if (errors != null) {
    say(
      errors.isEmpty
          ? 'Could not update antgrid.yaml.'
          : 'Could not update antgrid.yaml: ${errors.join(', ')}',
    );
    return;
  }
  await container
      .read(worktreeSetupNudgeSeenProvider.notifier)
      .markSeen(entryId);
  final steps = (setup['steps'] as List).length;
  say(
    steps == 0
        ? 'Added an empty worktree.setup block to antgrid.yaml — fill in the '
              'steps your checkout needs.'
        : 'Added $steps setup ${steps == 1 ? 'step' : 'steps'} to '
              'antgrid.yaml.',
  );
}

/// A starter `worktree.setup` value seeded from what [root] actually shows.
///
/// Both signals are read off the TRACKED tree, which is all the bridge sends:
/// its file tree honours `.gitignore`, so the very files this feature exists
/// for — `.env`, `node_modules` — are the ones it cannot see. What it can see
/// stands in for them:
///   - a lockfile at the root names the package manager, hence the install step;
///   - a tracked `.env.example` names a directory that almost certainly holds
///     an untracked `.env` beside it, hence the copy list.
///
/// A `copy` source that turns out not to exist is a warning on the bridge, not
/// a failure, so an over-generous list costs a line in the transcript while a
/// missed one costs a broken checkout.
///
/// Never returns null: an undetectable project still gets the block, empty, as
/// a place to write its own steps.
@visibleForTesting
Map<String, dynamic> buildStarterWorktreeSetup(FileNode? root) {
  final steps = <Map<String, dynamic>>[];
  final copies = _envCopySources(root);
  if (copies.isNotEmpty) {
    steps.add({'name': 'Copy env files', 'copy': copies});
  }
  final install = _installCommand(root);
  if (install != null) {
    steps.add({'name': 'Install dependencies', 'run': install});
  }
  return {'steps': steps};
}

List<String> _envCopySources(FileNode? root) {
  final sources = <String>{};
  void walk(FileNode node) {
    if (node.type == FileNodeType.file) {
      if (_envTemplateNames.contains(node.name.toLowerCase())) {
        final slash = node.path.lastIndexOf('/');
        sources.add(
          slash < 0 ? '.env' : '${node.path.substring(0, slash)}/.env',
        );
      }
      return;
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  if (root != null) walk(root);
  final ordered = sources.toList()..sort();
  return ordered;
}

String? _installCommand(FileNode? root) {
  if (root == null) return null;
  final topLevel = {
    for (final child in root.children)
      if (child.type == FileNodeType.file) child.name,
  };
  for (final (lockfile, command) in _lockfileInstallCommands) {
    if (topLevel.contains(lockfile)) return command;
  }
  return null;
}

/// The main checkout's file tree, waiting out its hydration when the project
/// was warmed a moment ago and the snapshot is still in flight.
Future<FileNode?> _awaitTreeRoot(FileService service) async {
  final root = service.currentState.root;
  if (root != null) return root;
  final completer = Completer<FileNode?>();
  final sub = service.stateStream.listen(
    (state) {
      if (state.root != null && !completer.isCompleted) {
        completer.complete(state.root);
      }
    },
    onError: (Object _) {},
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  try {
    return await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  } finally {
    await sub.cancel();
  }
}
