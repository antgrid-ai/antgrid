import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/services/preview_handoff.dart';
import 'package:antgrid/util/external_url.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);
  tearDown(() => PreviewHandoff.shared.clear());

  testWidgets(
    'a terminal link to an open preview port asks that tab to navigate and '
    'keeps path, query and fragment',
    (tester) async {
      final session = (await tester.runAsync(
        () => newFakeProjectSession(LocalFakeAgentTransport()),
      ))!;
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
