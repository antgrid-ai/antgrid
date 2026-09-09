// Three list surfaces label a task by reading `taskProjectNamesProvider` while
// they build, so it has to answer synchronously whatever the fetch is doing —
// including refusing. A throwing provider here would take the whole task list
// down with it.
import 'dart:convert';

import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProviderContainer _container(MockClient client) {
  final container = ProviderContainer(
    overrides: [
      tasksApiProvider.overrideWithValue(
        TasksApi(
          licenseApiUrl: 'https://api.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  // The list surfaces hold a subscription for as long as they are mounted.
  // Without one the provider is auto-disposed the moment a read returns, so its
  // state is gone before the assertion that wants it.
  container.listen(taskProjectNamesProvider, (_, _) {});
  return container;
}

void main() {
  group('taskProjectNamesProvider', () {
    test('maps project uuid to display name once the list lands', () async {
      final container = _container(
        MockClient(
          (req) async => http.Response(
            jsonEncode({
              'projects': [
                {
                  'id': 'p-1',
                  'repoKey': 'github.com/acme/site',
                  'displayName': 'Site',
                },
                {
                  'id': 'p-2',
                  'repoKey': 'github.com/acme/api',
                  'displayName': '',
                },
              ],
            }),
            200,
          ),
        ),
      );

      await container.read(taskProjectsProvider.future);
      expect(container.read(taskProjectNamesProvider), {
        'p-1': 'Site',
        'p-2': 'github.com/acme/api',
      });
    });

    test('is the empty map while the list is still in flight', () {
      final container = _container(
        MockClient((_) async => http.Response('{"projects":[]}', 200)),
      );
      expect(container.read(taskProjectNamesProvider), isEmpty);
    });

    test('a refused list reads as no names, not as an error', () async {
      final container = _container(
        MockClient((_) async => http.Response('{"error":"NO_ACCOUNT"}', 403)),
      );

      // Not `await …future`: riverpod retries a failed provider with backoff,
      // so the future of a refusal this permanent never settles.
      await Future<void>.delayed(Duration.zero);
      final state = container.read(taskProjectsProvider);
      expect(state.error, isA<TaskApiException>());
      expect(container.read(taskProjectNamesProvider), isEmpty);
    });
  });
}
