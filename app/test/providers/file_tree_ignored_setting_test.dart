// The "Hide git-ignored files" setting reaches the tree over exactly one wire:
// `fileTreeStateProvider` reads it and pushes it into the focused checkout's
// FileService. Both ends are pinned elsewhere — the switch writes the setting
// (`test/screens/app_settings_files_toggle_test.dart`) and the FileService
// stamps its flag onto every request it sends (`test/services/
// file_service_test.dart`) — so this file exists for the hop between them,
// which nothing else touches. Its failure mode is silence: the provider swallows
// a missing settings service on purpose, so a break here reverts the tree to
// show-everything and nothing anywhere says so.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart' show focusedCheckoutIdProvider;
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The focused checkout's FileService, with the tree bound the way the
  /// workspace binds it — watching `fileTreeStateProvider` is what runs the
  /// builder body that carries the setting across.
  Future<FileService> boundFileService(ProviderContainer container) async {
    enterDemoMode(container);
    final session = await container.read(
      projectSessionProvider(kDemoProjectId).future,
    );
    final sub = container.listen(
      fileTreeStateProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    return session
        .servicesForCheckout(container.read(focusedCheckoutIdProvider))
        .fileService;
  }

  test('a fresh install browses everything (D10)', () async {
    final container = await demoContainer();
    final fileService = await boundFileService(container);

    expect(
      container.read(appSettingsServiceProvider).hideGitIgnoredFiles,
      isFalse,
    );
    expect(fileService.includeIgnoredInTree, isTrue);
  });

  test('flipping the setting reaches the live FileService', () async {
    final container = await demoContainer();
    final fileService = await boundFileService(container);

    await container
        .read(appSettingsServiceProvider.notifier)
        .setHideGitIgnoredFiles(true);
    await Future<void>.delayed(Duration.zero);
    expect(fileService.includeIgnoredInTree, isFalse);

    // Back again: the setting is a live override, not a one-way latch applied
    // once at the tree's first build.
    await container
        .read(appSettingsServiceProvider.notifier)
        .setHideGitIgnoredFiles(false);
    await Future<void>.delayed(Duration.zero);
    expect(fileService.includeIgnoredInTree, isTrue);
  });

  test('a setting already on is applied before the first listing', () async {
    final container = await demoContainer();
    // Written BEFORE anything watches the tree, which is the ordinary case: the
    // setting is persisted and read back at launch, so the very first root
    // request of a session must already carry it.
    await container
        .read(appSettingsServiceProvider.notifier)
        .setHideGitIgnoredFiles(true);

    final fileService = await boundFileService(container);

    expect(fileService.includeIgnoredInTree, isFalse);
  });
}
