import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  test('parses notification:push with all fields', () {
    final msg = parseAbMessage({
      'type': 'notification:push',
      'id': 'm1',
      'timestamp': 42,
      'notificationType': 'permission_request',
      'message': 'Allow Bash?',
      'projectId': 'proj-a',
      'sessionTitle': 'Fix auth bug',
    });
    expect(msg, isA<NotificationPushMessage>());
    final n = msg as NotificationPushMessage;
    expect(n.notificationType, 'permission_request');
    expect(n.message, 'Allow Bash?');
    expect(n.projectId, 'proj-a');
    expect(n.sessionTitle, 'Fix auth bug');
  });

  test('returns null when notificationType missing', () {
    final msg = parseAbMessage({
      'type': 'notification:push',
      'id': 'm2',
      'timestamp': 0,
    });
    expect(msg, isNull);
  });
}
