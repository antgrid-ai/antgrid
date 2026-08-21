import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_message_classification.dart';

void main() {
  test('agent content + snapshot are heavy', () {
    for (final t in [
      'agent:item-added',
      'agent:item-delta',
      'agent:item-updated',
      'agent:snapshot',
    ]) {
      expect(classifyAbMessageByType(t), MessageTier.heavy, reason: t);
    }
  });

  test('agent lifecycle + interaction are status', () {
    for (final t in [
      'agent:turn-start',
      'agent:turn-end',
      'agent:capabilities',
      'agent:permission-request',
      'agent:question',
      'agent:error',
    ]) {
      expect(classifyAbMessageByType(t), MessageTier.status, reason: t);
    }
  });
}
