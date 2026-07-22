// Classifier completeness regression test.
//
// For each service that subscribes to ProjectSession's heavy or status
// streams, the wire-type strings its `_on{Heavy,Status}Json` handler
// dispatches on MUST classify as a non-`ignore` tier — otherwise
// MessageRouter drops the frame before the service ever sees it and the
// UI silently breaks. (The bug this guards against: `git:status` and
// `git:diff-content` were handled by FileService but classified as
// `ignore`, so file-tree badges never appeared and the diff viewer hung.)
//
// Dart doesn't expose enough reflection to enumerate these statically, so
// each service has a hardcoded list below. The lists are derived from
// reading each service's `_on{Heavy,Status}Json` body.
//
// IF YOU ADD A NEW WIRE TYPE TO A SERVICE HANDLER, ADD IT HERE TOO.
// Otherwise this test won't catch the next regression.

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_message_classification.dart';

/// All wire types each service expects to receive (across either stream).
/// We assert each is classified as either heavy or status — never ignore.
/// Some services (e.g. PreviewService) defensively dispatch the same set
/// from both `_onHeavyJson` and `_onStatusJson`; we only care that the
/// classifier doesn't drop any of them.
const Map<String, List<String>> serviceWireTypes = {
  'TerminalService': [
    // heavy
    'terminal:snapshot',
    'terminal:output',
    // status
    'terminal:started',
    'terminal:exited',
    'agent:status',
    'git:branches',
    'git:checkout-result',
  ],
  'FileService': [
    // heavy
    'file:tree:snapshot',
    'tree:update',
    'tree:full',
    'file:content',
    // status
    'git:status',
    'git:diff-content',
  ],
  'CommandService': [
    // heavy
    'command:output',
    // status
    'command:done',
  ],
  'SearchService': [
    // heavy
    'file:search-result',
    'file:search-done',
  ],
  'SessionsService': [
    // status
    'session:list:result',
    'session:result',
    'session:updated',
  ],
  'ConfigService': [
    // status
    'config:read-result',
    'config:write-result',
    'config:detect-tools-result',
    'config:changed',
  ],
  'PreviewService': [
    // ports:update is status-tier, preview:snapshot is heavy-tier; the
    // service handles both from either stream defensively. Tunnel http
    // responses arrive via a direct transport subscription on the
    // 'preview' channel — they bypass classification and are not listed.
    'ports:update',
    'preview:snapshot',
  ],
  'UploadService': [
    // status
    'file:upload-ready',
    'file:upload-ack',
    'file:upload-result',
  ],
};

void main() {
  group('classifier completeness', () {
    serviceWireTypes.forEach((service, types) {
      test('$service handled wire types all classify as non-ignore', () {
        for (final t in types) {
          final tier = classifyAbMessageByType(t);
          expect(
            tier,
            isNot(MessageTier.ignore),
            reason:
                '$service handles "$t", but the classifier returns '
                'MessageTier.ignore — MessageRouter will drop it before '
                'the service ever sees it. Add "$t" to _statusTypes or '
                '_heavyTypes in project_message_classification.dart.',
          );
        }
      });
    });

    test('coverage sanity — all 8 services represented', () {
      expect(serviceWireTypes.length, 8);
    });
  });
}
