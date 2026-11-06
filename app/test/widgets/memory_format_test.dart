import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/widgets/memory/memory_error.dart';
import 'package:antgrid/widgets/memory/memory_format.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryRecord rec({
  Map<String, dynamic>? extra,
  Map<String, dynamic>? source,
}) => MemoryRecord.fromJson({
  'id': 'a',
  'content': 'c',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'p',
  'source': source ?? {'actor': 'agent', 'agent_id': 'codex'},
  'created_at': DateTime(2026, 6, 13, 9).millisecondsSinceEpoch,
  'updated_at': 1,
  'lifecycle': 'active',
  ...?extra,
});

void main() {
  final now = DateTime(2026, 6, 13, 12);
  final task = rec(extra: {'scope': 'task', 'task_id': 'abcdef012345'});

  test('memoryAgentName', () {
    expect(memoryAgentName(rec(source: {'actor': 'app'}), {}), 'you');
    expect(memoryAgentName(rec(), {}), 'codex');
    expect(memoryAgentName(rec(source: {'actor': 'agent'}), {}), 'an agent');
  });

  test('memoryAgentName uses the catalog label', () {
    final catalog = <String, AgentDescriptor>{
      'codex': const AgentDescriptor(
        tool: 'codex',
        label: 'Codex',
        chatCapable: false,
        judgeCapable: false,
        handlerTerminal: false,
        handlerChat: false,
        terminalApprovalPolicies: [],
        chatApprovalPolicies: [],
      ),
    };
    expect(memoryAgentName(rec(), catalog), 'Codex');
  });

  test('memoryMetaLine', () {
    expect(
      memoryMetaLine(project: 'P', agent: 'you', created: now.subtract(const Duration(hours: 3)), now: now),
      'P  ·  you  ·  3h ago',
    );
    expect(
      memoryMetaLine(project: 'P', agent: 'you', created: null),
      'P  ·  you',
    );
  });

  test('memoryRowTag precedence', () {
    expect(memoryRowTag(rec(extra: {'lifecycle': 'superseded', 'scope': 'task'}), projectRemoved: true), 'Replaced');
    expect(memoryRowTag(rec(extra: {'lifecycle': 'expired', 'scope': 'task'}), projectRemoved: true), 'Expired');
    expect(memoryRowTag(task, projectRemoved: true), 'This session');
    expect(memoryRowTag(rec(), projectRemoved: true), 'Removed project');
    expect(memoryRowTag(rec(), projectRemoved: false), isNull);
  });

  test('scope and lifecycle labels', () {
    expect(memoryScopeLabel(task), 'Session abcdef01 only');
    expect(memoryScopeLabel(rec()), 'Project memory');
    expect(memoryLifecycleLabel(rec(extra: {'lifecycle': 'superseded'})), 'Replaced by a newer version');
    expect(memoryLifecycleLabel(rec(extra: {'lifecycle': 'expired'})), 'Expired after 30 days without an update');
    expect(memoryLifecycleLabel(rec()), isNull);
  });

  test('memoryAppliesText', () {
    expect(memoryAppliesText(rec(extra: {'applicability': 'Windows only'}), project: 'P'), 'Windows only');
    expect(memoryAppliesText(task, project: 'P'), 'Only inside session abcdef01.');
    expect(memoryAppliesText(rec(extra: {'applicability': '  '}), project: 'P'), 'Not stated. Agents treat it as a general note for P.');
  });

  test('memorySavedLine and memoryEarlierWhen', () {
    expect(
      memorySavedLine(rec(), agent: 'codex', project: 'P', projectRemoved: false, now: now),
      'Saved by codex, 3 hours ago, in P',
    );
    expect(
      memorySavedLine(rec(), agent: 'codex', project: 'P', projectRemoved: true, now: now),
      'Saved by codex, 3 hours ago, in P (project removed from Antgrid)',
    );
    final undated = rec(extra: {'created_at': 'not a date'});
    expect(
      memorySavedLine(undated, agent: 'you', project: 'P', projectRemoved: false),
      'Saved by you, in P',
    );
    expect(memoryEarlierWhen(rec(), agent: 'codex', now: now), 'Saved by codex, 3 hours ago');
    expect(memoryEarlierWhen(undated, agent: 'codex'), 'Saved by codex');
  });

  test('counts and tech line', () {
    expect(memoryEarlierLabel(1), '1 earlier version');
    expect(memoryEarlierLabel(3), '3 earlier versions');
    expect(memoryEarlierLabel(20, more: true), '20+ earlier versions');
    expect(memoryCountLabel(1), '1 memory');
    expect(memoryCountLabel(0), '0 memories');
    expect(memoryCountLabel(2), '2 memories');
    expect(memoryTechSavedBy(rec(source: {'actor': 'app'})), 'you (app)');
    expect(memoryTechSavedBy(rec()), 'codex (agent)');
    expect(memoryTechSavedBy(rec(source: {'actor': 'agent'})), 'unknown (agent)');
  });

  group('memoryErrorCopy', () {
    const backend = 'record revision Repair operation key database';
    String copy(String code, {bool mutation = false}) =>
        memoryErrorCopy(MemoryException(code, backend), mutation: mutation);

    test('every code maps to app copy and hides the backend message', () {
      const expected = {
        'UNKNOWN_OUTCOME': 'Outcome unknown. The change may have been saved. Reconnect and check the memory before trying again.',
        'CONFLICT': 'Someone edited this memory first. Open its latest version before editing again.',
        'IDEMPOTENCY_CONFLICT': 'Someone edited this memory first. Open its latest version before editing again.',
        'CLEANUP_FAILED': "Cleanup failed. Forgotten memories are hidden, but cleanup didn't finish.",
        'EXPORT_CHANGED': 'Memory changed during export. Start the export again to save a consistent copy.',
        'SEARCH_UNAVAILABLE': "Search is off until it's rebuilt.",
        'FORGOTTEN': 'This memory was forgotten.',
        'NOT_FOUND': 'This memory no longer exists.',
        'INVALID_ARGUMENT': "This machine's Antgrid didn't understand the request. Update Antgrid on both devices and try again.",
        'BUSY': 'Memory is busy. Try again in a moment.',
        'UNAVAILABLE': "Memory storage couldn't be opened. Saved memories stay on disk.",
        'NOT_CONNECTED': "This machine isn't connected. Connect it to see its memories.",
        'NO_MACHINE': 'Open Memory from a connected machine.',
        'DEMO': 'Memory is unavailable in the sample project.',
        'DISABLED': 'Memory is off on this machine.',
        'FORBIDDEN': "This device isn't allowed to do that on this machine.",
        'WHATEVER': 'Something went wrong with Memory. Try again.',
      };
      expected.forEach((code, text) {
        expect(copy(code), text, reason: code);
        expect(copy(code), isNot(contains('record')), reason: code);
      });
    });

    test('INVALID_ARGUMENT on a mutation', () {
      expect(
        copy('INVALID_ARGUMENT', mutation: true),
        'This memory is too long to save. Shorten it or remove a source, then try again.',
      );
    });

    test('mutation timeouts read as unknown outcome', () {
      expect(
        memoryErrorCopy(const MemoryException('TIMEOUT', backend), mutation: true),
        copy('UNKNOWN_OUTCOME'),
      );
      expect(copy('TIMEOUT'), 'Something went wrong with Memory. Try again.');
    });

    test('non-memory errors keep the shared fallback', () {
      expect(memoryErrorCopy(StateError('x')), 'Memory request failed. Try again.');
    });
  });
}
