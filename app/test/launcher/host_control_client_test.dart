// app/test/launcher/host_control_client_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/launcher/host_control_client.dart';

/// Minimal stand-in for the bridge ControlListener. Echoes typed responses
/// and records the last request body + auth header.
class _StubControlServer {
  late final HttpServer _server;
  String? lastAuth;
  Map<String, dynamic>? lastBody;

  int get port => _server.port;

  Future<void> start({
    required Map<String, dynamic> Function(Map<String, dynamic> req) handler,
    int status = 200,
    // Delay before responding — simulates a wedged-but-listening host so we can
    // assert the client's request timeout fires.
    Duration responseDelay = Duration.zero,
  }) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      lastAuth = req.headers.value('authorization');
      final body = await utf8.decoder.bind(req).join();
      lastBody = jsonDecode(body) as Map<String, dynamic>;
      final res = handler(lastBody!);
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(res));
      await req.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('projectOpen sends bearer token + mode and parses connect', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'project:open',
          'running': true,
          'connect': {'port': 55001, 'token': 'loop-tok'},
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 'secret');
    final res = await client.projectOpen(
      projectId: 'p1',
      projectPath: '/tmp/p1',
    );

    expect(stub.lastAuth, 'Bearer secret');
    expect(stub.lastBody!['type'], 'project:open');
    expect(stub.lastBody!['mode'], 'local'); // desktop always opens local
    expect(stub.lastBody!['projectId'], 'p1');
    expect(res.running, isTrue);
    expect(res.connect!.port, 55001);
    expect(res.connect!.token, 'loop-tok');
  });

  test('projectResolve validates and parses host-owned repository identity', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'project:resolve',
          'projectId': 'primary-id',
          'repoPath': '/repo',
          'selectedPath': '/repo/linked',
          'label': 'repo',
          'isGitRepository': true,
        });
    addTearDown(stub.close);

    final result = await HostControlClient(port: stub.port, token: 't')
        .projectResolve('/repo/linked');
    expect(stub.lastBody!['type'], 'project:resolve');
    expect(result.projectId, 'primary-id');
    expect(result.repoPath, '/repo');
    expect(result.isGitRepository, isTrue);
  });

  test('projectResolve rejects malformed responses', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'], 'ok': true, 'type': 'project:resolve', 'projectId': 12,
        });
    addTearDown(stub.close);

    await expectLater(
      () => HostControlClient(port: stub.port, token: 't').projectResolve('/repo'),
      throwsA(isA<HostControlException>().having((e) => e.code, 'code', 'BAD_RESPONSE')),
    );
  });

  test('projectList parses summaries', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'project:list',
          'projects': [
            {'projectId': 'a', 'path': '/a', 'running': true, 'mode': 'local'},
          ],
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    final list = await client.projectList();
    expect(list, hasLength(1));
    expect(list.first.projectId, 'a');
    expect(list.first.mode, 'local');
  });

  test('toolsList parses the tool catalog', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'tools:list',
          'tools': [
            {'tool': 'claude-code', 'path': '/usr/bin/claude'},
          ],
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    final tools = await client.toolsList();
    expect(tools.single.tool, 'claude-code');
  });

  test('ok:false throws HostControlException with code', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': false,
          'error': {'code': 'NO_FOLDER', 'message': 'missing folder'},
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    expect(
      () => client.projectOpen(projectId: 'p', projectPath: '/nope'),
      throwsA(isA<HostControlException>()
          .having((e) => e.code, 'code', 'NO_FOLDER')),
    );
  });

  test('a wedged host (no response) times out as HostControlException(TRANSPORT)',
      () async {
    final stub = _StubControlServer();
    await stub.start(
      responseDelay: const Duration(seconds: 30), // host accepts but never answers
      handler: (req) => {'id': req['id'], 'ok': true, 'projects': []},
    );
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    // Short timeout keeps the test fast; the TimeoutException must surface as
    // HostControlException('TRANSPORT').
    await expectLater(
      () => client.projectList(timeout: const Duration(milliseconds: 150)),
      throwsA(isA<HostControlException>()
          .having((e) => e.code, 'code', 'TRANSPORT')),
    );
  });

  test('non-200 (e.g. 401) throws HostControlException', () async {
    final stub = _StubControlServer();
    await stub.start(
      status: 401,
      handler: (req) => {'error': 'unauthorized'},
    );
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 'wrong');
    expect(
      () => client.projectList(),
      throwsA(isA<HostControlException>()),
    );
  });

  test('gitBranches parses branch catalog', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'git:branches',
          'isRepository': true,
          'current': 'main',
          'branches': ['main', 'dev'],
          'worktreeSessionsSupported': true,
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    final catalog = await client.gitBranches(projectId: 'p1', projectPath: '/path');
    expect(catalog.isRepository, isTrue);
    expect(catalog.current, 'main');
    expect(catalog.branches, ['main', 'dev']);
    expect(catalog.worktreeSessionsSupported, isTrue);
  });

  test('gitCheckout returns checked out current branch', () async {
    final stub = _StubControlServer();
    await stub.start(handler: (req) => {
          'id': req['id'],
          'ok': true,
          'type': 'git:checkout',
          'current': 'dev',
        });
    addTearDown(stub.close);

    final client = HostControlClient(port: stub.port, token: 't');
    final current = await client.gitCheckout(
      projectId: 'p1',
      projectPath: '/path',
      branch: 'dev',
      allowActiveSessions: true,
    );
    expect(current, 'dev');
  });
}
