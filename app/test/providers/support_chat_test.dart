import 'package:antgrid/providers/support_chat.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'support URI carries identity in a fragment and preserves base options',
    () {
      final uri = supportChatUri(
        'https://antgrid.ai/support?campaign=desktop',
        CurrentUser(
          userId: 'user-1',
          email: 'jane+app@example.com',
          name: ' Jane Doe ',
        ),
      );

      expect(uri.scheme, 'https');
      expect(uri.host, 'antgrid.ai');
      expect(uri.path, '/support');
      expect(uri.queryParameters, {
        'campaign': 'desktop',
        'chat': '1',
        'source': 'app',
      });
      expect(Uri.splitQueryString(uri.fragment), {
        'name': 'Jane Doe',
        'email': 'jane+app@example.com',
      });
    },
  );

  test('support URI omits absent identity without leaving a fragment', () {
    final uri = supportChatUri('https://antgrid.ai/support', null);

    expect(uri.queryParameters, {'chat': '1', 'source': 'app'});
    expect(uri.hasFragment, isFalse);
  });

  test('support URI omits a blank display name', () {
    final uri = supportChatUri(
      'https://antgrid.ai/support',
      CurrentUser(userId: 'user-1', email: 'jane@example.com', name: '  '),
    );

    expect(Uri.splitQueryString(uri.fragment), {'email': 'jane@example.com'});
  });
}
