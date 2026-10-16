// The assignee picker, the create sheet and the detail's name lookup all read
// `taskAssigneeCandidatesProvider`. The signed-in user must stay FIRST and stay
// present whatever the member fetch does — assigning yourself needs no list.
import 'dart:convert';

import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProviderContainer _container(MockClient client) {
  final container = ProviderContainer(
    retry: noProviderRetry,
    overrides: [
      tasksApiProvider.overrideWithValue(
        TasksApi(
          licenseApiUrl: 'https://api.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      currentUserProvider.overrideWith(
        (_) async => CurrentUser(userId: 'u-me', email: 'me@test'),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(taskAssigneeCandidatesProvider, (_, _) {});
  return container;
}

Future<void> _settle(ProviderContainer container) async {
  await container.read(currentUserProvider.future);
  try {
    await container.read(taskMembersProvider.future);
  } catch (_) {}
}

void main() {
  test('me first, then teammates by name, from the members route', () async {
    final paths = <String>[];
    final container = _container(
      MockClient((req) async {
        paths.add(req.url.path);
        return http.Response(
          jsonEncode({
            'members': [
              {'userId': 'u-zed', 'name': 'Zed', 'email': 'z@test'},
              {'userId': 'u-me', 'name': 'Me Myself', 'email': 'me@test'},
              {'userId': 'u-amy', 'name': '', 'email': 'amy@test'},
            ],
          }),
          200,
        );
      }),
    );
    await _settle(container);

    final candidates = container.read(taskAssigneeCandidatesProvider);
    expect(paths, ['/tasks/members']);
    expect(candidates.map((c) => c.userId), ['u-me', 'u-amy', 'u-zed']);
    // A member with no name is shown by the address that identifies them.
    expect(candidates.map((c) => c.displayName), [
      'Me Myself',
      'amy@test',
      'Zed',
    ]);
  });

  test('a member assignee is named from the list, never by uuid', () async {
    final container = _container(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'members': [
              {'userId': 'u-amy', 'name': 'Amy Pond', 'email': 'amy@test'},
            ],
          }),
          200,
        ),
      ),
    );
    container.listen(taskMemberNameProvider('u-gone'), (_, _) {});
    // Still loading: blank, so an avatar never shows initials cut from an id.
    expect(container.read(taskMemberNameProvider('u-gone')), '');
    await _settle(container);

    expect(container.read(taskMemberNameProvider('u-amy')), 'Amy Pond');
    // Absent from a loaded list: they have left the account.
    expect(container.read(taskMemberNameProvider('u-gone')), 'Former member');
  });

  test('a failed member fetch still offers me', () async {
    final container = _container(
      MockClient((_) async => http.Response('{"error":"boom"}', 500)),
    );
    await _settle(container);

    final candidates = container.read(taskAssigneeCandidatesProvider);
    expect(candidates.map((c) => c.userId), ['u-me']);
    expect(candidates.single.displayName, 'me@test');
  });
}
