import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/util/external_url.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

class _LocalFakeTransport extends FakeAgentTransport {
  @override
  bool get isLocal => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);
  tearDown(() => PreviewHandoff.shared.clear());

  testWidgets(
    'a terminal link to an open preview port asks that tab to navigate and '
    'keeps path, query and fragment',
    (tester) async {
      final transport = _LocalFakeTransport();
      final session = (await tester.runAsync(() async {
        final cache = await CachedSessionsStore.open();
        return ProjectSession(
          projectId: 'p',
          transport: transport,
          mode: ProjectSessionMode.local,
          cachedSessionsStore: cache,
          onClose: () async => await transport.dispose(),
        );
      }))!;
      final svc = session.previewService;
      await svc.openTab(3000);

      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );

      final revealed = <WorkspaceView>[];
      await openContentLink(
        context,
        'http://localhost:3000/app/route?tab=2#/inner',
        fileService: () => null,
        previewService: () => svc,
        revealView: revealed.add,
      );

      expect(revealed, [WorkspaceView.preview]);
      expect(
        svc.takeNavRequest(3000),
        Uri.parse('http://localhost:3000/app/route?tab=2#/inner'),
      );

      await tester.runAsync(session.close);
    },
  );
}
