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

  test('handler:snapshot routes to the heavy tier', () {
    // Unclassified, the undo advert is dropped before HandlerService sees it
    // and the offer only ever appears after a status replay.
    expect(classifyAbMessageByType('handler:snapshot'), MessageTier.heavy);
  });

  test('handler:configure, handler:undo and handler:dismiss are outbound only', () {
    expect(classifyAbMessageByType('handler:configure'), MessageTier.ignore);
    expect(classifyAbMessageByType('handler:undo'), MessageTier.ignore);
    expect(classifyAbMessageByType('handler:dismiss'), MessageTier.ignore);
  });
}
