import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The sample project's task backlog, served to the REAL [TasksApi] through an
/// in-memory [http.Client].
///
/// Same principle as the demo transport: the demo renders through the real
/// parsing, providers and widgets rather than a parallel set of fakes, so what
/// a reviewer sees in the demo is what a signed-in account sees. Answering at
/// the HTTP seam is also what holds the demo's no-network invariant here — this
/// client has no socket to open, and a route it does not know is a refusal,
/// never a fall-through to the real service.
///
/// A small team on purpose: tasks are account-scoped, and the thing the demo
/// has to show is a task on someone else's plate and a conversation with them.

/// The signed-in user, inside the demo. Not a real user id, so nothing the demo
/// writes can ever be mistaken for — or attributed to — a real account.
const String kDemoTaskUserId = 'demo-you';

const _you = (id: kDemoTaskUserId, name: 'You', email: 'you@demo-shop.dev');
const _priya = (
  id: 'demo-priya',
  name: 'Priya Raman',
  email: 'priya@demo-shop.dev',
);
const _marcus = (
  id: 'demo-marcus',
  name: 'Marcus Lee',
  email: 'marcus@demo-shop.dev',
);
const _team = [_you, _priya, _marcus];

/// How long the teammate takes to answer a comment. Long enough to read as a
/// person typing, short enough that nobody leaves the task before it lands.
const kDemoReplyDelay = Duration(seconds: 2);

/// What the teammate says back, in turn. Generic on purpose: they answer
/// whatever the visitor typed, and a reply that claimed to understand it would
/// be the one thing in the demo that is obviously canned.
const kDemoReplies = [
  'Thanks — I’ll pick that up next.',
  'Makes sense. I’ll update the PR and ping you when it’s ready.',
  'Good call. Adding it to the acceptance criteria.',
];

class DemoTasksClient extends http.BaseClient {
  DemoTasksClient({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _seed();
  }

  final DateTime Function() _clock;

  final _tasks = <int, Map<String, Object?>>{};
  final _comments = <int, List<Map<String, Object?>>>{};
  final _labels = <Map<String, Object?>>[];
  final _timers = <Timer>[];
  final _changes = StreamController<int>.broadcast();
  var _nextNumber = 1;
  var _nextId = 1;
  var _replyIndex = 0;

  /// Task numbers whose comment thread changed without the app asking — the
  /// teammate's reply. Nothing pushes to a real account's thread, so this has
  /// no live counterpart; it exists so the demo can show the reply arrive.
  Stream<int> get commentChanges => _changes.stream;

  @override
  void close() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    unawaited(_changes.close());
    super.close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request && request.body.isNotEmpty
        ? jsonDecode(request.body)
        : null;
    final (status, json) = _route(
      request.method,
      request.url,
      body is Map ? body.cast<String, Object?>() : const <String, Object?>{},
    );
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(json))),
      status,
      headers: const {'content-type': 'application/json'},
    );
  }

  (int, Object?) _route(String method, Uri url, Map<String, Object?> body) {
    final s = url.pathSegments;
    final number = s.length >= 2 && s[0] == 'tasks'
        ? _number(s[1])
        : null;

    switch ((method, s)) {
      case ('GET', ['tasks']):
        final wanted = url.queryParametersAll['status'];
        final rows = _tasks.values
            .where((t) => wanted == null || wanted.contains(t['status']))
            .toList()
          ..sort(
            (a, b) => (a['sortKey'] as String).compareTo(b['sortKey'] as String),
          );
        return (200, {'tasks': rows});
      case ('POST', ['tasks']):
        final title = '${body['title'] ?? ''}'.trim();
        if (title.isEmpty) return (400, {'error': 'INVALID_TITLE'});
        final task = _task(
          title: title,
          body: body['body'] is String ? body['body'] as String : '',
          status: body['status'] is String ? body['status'] as String : 'open',
          assignee: _assigneeFrom(body['assignee']),
          labelIds: _ids(body['labelIds']),
          createdAt: _clock(),
        );
        return (201, {'task': task});
      case ('GET', ['tasks', 'members']):
        return (
          200,
          {
            'members': [
              for (final m in _team)
                {'userId': m.id, 'name': m.name, 'email': m.email},
            ],
          },
        );
      case ('GET', ['tasks', 'integrations', 'status']):
        return (200, {'connected': false});
      case ('GET', ['tasks', 'publish-targets']):
        return (200, {'targets': const <Object?>[]});
      case ('GET', ['account', 'projects']):
        return (200, {'projects': const <Object?>[], 'unlinkedRepos': const <Object?>[]});
      case ('GET', ['labels']):
        return (200, {'labels': _labels});
      case ('POST', ['labels']):
        final name = '${body['name'] ?? ''}'.trim();
        final existing = _labels
            .where((l) => '${l['name']}'.toLowerCase() == name.toLowerCase())
            .firstOrNull;
        if (existing != null) return (200, {'label': existing});
        if (name.isEmpty) return (400, {'error': 'INVALID_LABEL_NAME'});
        final label = _label(name, '${body['color'] ?? '8b8b8b'}');
        return (201, {'label': label});
      case ('DELETE', ['labels', final id]):
        _labels.removeWhere((l) => l['id'] == id);
        for (final t in _tasks.values) {
          t['labels'] = [
            for (final l in t['labels']! as List)
              if ((l as Map)['id'] != id) l,
          ];
        }
        return (200, {'ok': true});
    }

    final task = number == null ? null : _tasks[number];
    if (task == null) return (404, {'error': 'NOT_FOUND'});

    switch ((method, s.sublist(2))) {
      case ('GET', []):
        return (200, {'task': task});
      case ('PATCH', []):
        _patch(task, body);
        return (200, {'task': task});
      case ('DELETE', []):
        _tasks.remove(number);
        _comments.remove(number);
        return (200, {'ok': true});
      case ('POST', ['move']):
        return (200, {'task': task});
      case ('PUT', ['labels']):
        task['labels'] = _labelsFor(_ids(body['labelIds']));
        _touch(task);
        return (200, {'task': task});
      case ('POST', ['labels']):
        final ids = [
          for (final l in task['labels']! as List) (l as Map)['id'] as String,
          if (body['labelId'] is String) body['labelId'] as String,
        ];
        task['labels'] = _labelsFor(ids.toSet().toList());
        _touch(task);
        return (200, {'task': task});
      case ('DELETE', ['labels', final labelId]):
        task['labels'] = [
          for (final l in task['labels']! as List)
            if ((l as Map)['id'] != labelId) l,
        ];
        _touch(task);
        return (200, {'task': task});
      case ('GET', ['comments']):
        return (200, {'comments': _comments[number] ?? const []});
      case ('POST', ['comments']):
        final text = '${body['body'] ?? ''}'.trim();
        if (text.isEmpty) return (400, {'error': 'EMPTY_COMMENT'});
        final comment = _comment(number!, _you, text, _clock());
        _scheduleReply(number, task);
        return (201, {'comment': comment});
      case ('PATCH', ['comments', final id]):
        final comment = _ownComment(number!, id);
        if (comment == null) return (404, {'error': 'COMMENT_NOT_FOUND'});
        final text = '${body['body'] ?? ''}'.trim();
        if (text.isEmpty) return (400, {'error': 'EMPTY_COMMENT'});
        comment['body'] = text;
        comment['updatedAt'] = _clock().toUtc().toIso8601String();
        return (200, {'comment': comment});
      case ('DELETE', ['comments', final id]):
        final comment = _ownComment(number!, id);
        if (comment == null) return (404, {'error': 'COMMENT_NOT_FOUND'});
        _comments[number]!.remove(comment);
        return (200, {'ok': true});
    }
    // Publishing, unlinking and the conflict verbs need a GitHub connection the
    // demo does not pretend to have; the UI never offers them for these tasks.
    return (404, {'error': 'NOT_FOUND'});
  }

  /// The teammate on the task answers; on a task with nobody else on it, the
  /// teammate who has been talking in the demo does.
  void _scheduleReply(int number, Map<String, Object?> task) {
    final assignee = task['assignee'];
    final assigneeId = assignee is Map ? assignee['userId'] : null;
    final replier = _team
            .where((m) => m.id == assigneeId && m.id != _you.id)
            .firstOrNull ??
        _priya;
    final text = kDemoReplies[_replyIndex++ % kDemoReplies.length];
    late final Timer timer;
    timer = Timer(kDemoReplyDelay, () {
      _timers.remove(timer);
      if (!_tasks.containsKey(number) || _changes.isClosed) return;
      _comment(number, replier, text, _clock());
      _changes.add(number);
    });
    _timers.add(timer);
  }

  Map<String, Object?>? _ownComment(int number, String id) =>
      (_comments[number] ?? const [])
          .where(
            (c) =>
                c['id'] == id && (c['author'] as Map?)?['userId'] == _you.id,
          )
          .firstOrNull;

  void _patch(Map<String, Object?> task, Map<String, Object?> body) {
    if (body['title'] is String) task['title'] = body['title'];
    if (body['body'] is String) task['body'] = body['body'];
    if (body.containsKey('priority')) task['priority'] = body['priority'];
    if (body.containsKey('projectId')) task['projectId'] = body['projectId'];
    if (body.containsKey('assignee')) {
      task['assignee'] = _assigneeFrom(body['assignee']);
    }
    if (body['labelIds'] is List) {
      task['labels'] = _labelsFor(_ids(body['labelIds']));
    }
    if (body['status'] is String) {
      final status = body['status'] as String;
      task['status'] = status;
      task['closedAt'] = status == 'done' || status == 'cancelled'
          ? _clock().toUtc().toIso8601String()
          : null;
    }
    _touch(task);
  }

  void _touch(Map<String, Object?> task) =>
      task['updatedAt'] = _clock().toUtc().toIso8601String();

  Map<String, Object?>? _assigneeFrom(Object? raw) {
    if (raw is! Map || raw['kind'] != 'member') return null;
    final userId = raw['userId'];
    if (userId is! String || !_team.any((m) => m.id == userId)) return null;
    return {'kind': 'member', 'userId': userId};
  }

  List<String> _ids(Object? raw) =>
      raw is List ? raw.whereType<String>().toList() : const [];

  List<Map<String, Object?>> _labelsFor(List<String> ids) => [
    for (final l in _labels)
      if (ids.contains(l['id'])) l,
  ];

  int? _number(String raw) {
    final digits = raw.toUpperCase().startsWith('ANT-')
        ? raw.substring(4)
        : raw;
    return int.tryParse(digits);
  }

  Map<String, Object?> _label(String name, String color) {
    final label = <String, Object?>{
      'id': 'demo-label-${_nextId++}',
      'projectId': null,
      'name': name,
      'color': color,
      'description': null,
      'createdAt': _clock().toUtc().toIso8601String(),
    };
    _labels.add(label);
    return label;
  }

  Map<String, Object?> _task({
    required String title,
    required String body,
    required String status,
    required DateTime createdAt,
    Map<String, Object?>? assignee,
    List<String> labelIds = const [],
    int? priority,
    String createdBy = kDemoTaskUserId,
  }) {
    final number = _nextNumber++;
    final stamp = createdAt.toUtc().toIso8601String();
    final task = <String, Object?>{
      'number': number,
      'displayId': 'ANT-$number',
      'title': title,
      'body': body,
      'status': status,
      'priority': priority,
      'projectId': null,
      // Newest first, the way a backlog is triaged.
      'sortKey': (1000 - number).toString().padLeft(4, '0'),
      'source': 'local',
      'assignee': assignee,
      'labels': _labelsFor(labelIds),
      'otherAssignees': const <Object?>[],
      'syncState': null,
      'conflict': null,
      'pushBlocked': null,
      'createdBy': createdBy,
      'createdAt': stamp,
      'updatedAt': stamp,
      'closedAt': status == 'done' ? stamp : null,
    };
    _tasks[number] = task;
    return task;
  }

  Map<String, Object?> _comment(
    int number,
    ({String id, String name, String email}) author,
    String body,
    DateTime at,
  ) {
    final stamp = at.toUtc().toIso8601String();
    final comment = <String, Object?>{
      'id': 'demo-comment-${_nextId++}',
      'author': {
        'kind': 'member',
        'userId': author.id,
        'name': author.name,
        'avatarUrl': null,
      },
      'body': body,
      'imported': false,
      'createdAt': stamp,
      'updatedAt': stamp,
    };
    (_comments[number] ??= []).add(comment);
    return comment;
  }

  void _seed() {
    final now = _clock();
    DateTime ago(Duration d) => now.subtract(d);
    Map<String, Object?> member(String id) => {'kind': 'member', 'userId': id};

    final bug = _label('bug', 'd73a4a')['id']! as String;
    final feature = _label('feature', 'a2eeef')['id']! as String;
    final checkout = _label('checkout', '5319e7')['id']! as String;

    _task(
      title: 'Write the local setup steps in the README',
      body: 'Node version, `npm install`, and how to seed the sample catalog.',
      status: 'done',
      assignee: member(_marcus.id),
      createdAt: ago(const Duration(days: 4)),
      createdBy: _marcus.id,
    );

    final cart = _task(
      title: 'Cart total ignores quantity changes',
      body:
          'Changing the quantity on a cart line updates the line but not the '
          'subtotal.\n\n'
          '- [ ] Recalculate the subtotal on quantity change\n'
          '- [ ] Cover it in `cart.test.ts`',
      status: 'open',
      priority: 1,
      assignee: member(_you.id),
      labelIds: [bug, checkout],
      createdAt: ago(const Duration(days: 1, hours: 3)),
      createdBy: _marcus.id,
    );
    _comment(
      cart['number']! as int,
      _marcus,
      'Repro: add two of the same item, change the quantity to 3 — the '
      'subtotal still shows two.',
      ago(const Duration(days: 1, hours: 2)),
    );

    final coupons = _task(
      title: 'Add coupon codes to checkout',
      body:
          'Let shoppers enter a coupon code on the payment step.\n\n'
          '## Acceptance\n'
          '- [x] Code field on the payment step\n'
          '- [ ] Validate against `/api/coupons`\n'
          '- [ ] Show the discount as its own line in the summary',
      status: 'in_progress',
      priority: 2,
      assignee: member(_priya.id),
      labelIds: [feature, checkout],
      createdAt: ago(const Duration(days: 2)),
    );
    final n = coupons['number']! as int;
    _comment(
      n,
      _priya,
      'Started on this. Should a coupon stack with the member discount?',
      ago(const Duration(hours: 5)),
    );
    _comment(
      n,
      _you,
      'No stacking — one code per order, and it can’t combine with the member '
      'discount.',
      ago(const Duration(hours: 4, minutes: 40)),
    );
    _comment(
      n,
      _priya,
      'Got it, single code it is. I’ll have a PR up this afternoon.',
      ago(const Duration(hours: 4, minutes: 30)),
    );

    _task(
      title: 'Rate-limit the login endpoint',
      body: 'Five attempts per minute per IP, then a 429 with `Retry-After`.',
      status: 'open',
      labelIds: [feature],
      createdAt: ago(const Duration(hours: 2)),
    );
  }
}
