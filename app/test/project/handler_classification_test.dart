import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_message_classification.dart';

void main() {
  test('handler:status routes to the status tier', () {
    expect(classifyAbMessageByType('handler:status'), MessageTier.status);
  });

  test('handler:escalation and handler:activity route to the heavy tier', () {
    expect(classifyAbMessageByType('handler:escalation'), MessageTier.heavy);
    expect(classifyAbMessageByType('handler:activity'), MessageTier.heavy);
  });

  test('handler:configure is NOT inbound-classified (outbound only)', () {
    expect(classifyAbMessageByType('handler:configure'), MessageTier.ignore);
  });
}
