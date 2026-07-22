import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_message_classification.dart';

void main() {
  group('classifyAbMessageByType', () {
    test('status whitelist — all status types classify as status', () {
      const statusTypes = <String>[
        'session:list:result',
        'session:result',
        'session:updated',
        'command:done',
        'port:detected',
        'ports:update',
        'agent:status',
        'agent:hello',
        'config:changed',
        'config:read-result',
        'config:write-result',
        'config:detect-tools-result',
        'terminal:started',
        'terminal:exited',
        'git:branches',
        'git:checkout-result',
        'git:status',
        'git:diff-content',
        'file:upload-ready',
        'file:upload-ack',
        'file:upload-result',
      ];
      expect(statusTypes.length, 21);
      for (final t in statusTypes) {
        expect(
          classifyAbMessageByType(t),
          MessageTier.status,
          reason: '$t should be status',
        );
      }
    });

    test('heavy stream — all 11 heavy types classify as heavy', () {
      const heavyTypes = <String>[
        'terminal:output',
        'terminal:snapshot',
        'tree:full',
        'tree:update',
        'file:tree:snapshot',
        'file:content',
        'preview:url',
        'preview:snapshot',
        'command:output',
        'file:search-result',
        'file:search-done',
      ];
      expect(heavyTypes.length, 11);
      for (final t in heavyTypes) {
        expect(
          classifyAbMessageByType(t),
          MessageTier.heavy,
          reason: '$t should be heavy',
        );
      }
    });

    test('snapshot replies are heavy', () {
      expect(classifyAbMessageByType('terminal:snapshot'), MessageTier.heavy);
      expect(classifyAbMessageByType('file:tree:snapshot'), MessageTier.heavy);
      expect(classifyAbMessageByType('preview:snapshot'), MessageTier.heavy);
    });

    test('agent:request-retracted classifies as status', () {
      expect(
        classifyAbMessageByType('agent:request-retracted'),
        MessageTier.status,
      );
    });

    test('handshake / ping / pong / unknown classify as ignore', () {
      const ignoreTypes = <String>[
        'ping',
        'pong',
        'handshake',
        'hello',
        'something-unknown',
        '',
        'terminal:snapshot:request',
        'file:tree:snapshot:request',
        'preview:snapshot:request',
        'client:focus-state',
      ];
      for (final t in ignoreTypes) {
        expect(
          classifyAbMessageByType(t),
          MessageTier.ignore,
          reason: '$t should be ignore',
        );
      }
    });
  });
}
