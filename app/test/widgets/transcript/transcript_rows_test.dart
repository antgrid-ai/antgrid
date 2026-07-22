import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/services/agent_session_service.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

AgentItem _item(
  String id,
  String kind, {
  String? role,
  String? text,
  DateTime? timestamp,
}) => AgentItem(
  itemId: id,
  kind: kind,
  role: role,
  text: text,
  timestamp: timestamp,
);

void main() {
  test('active turn: all items + WorkingRow at end', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('u1', 'message', role: 'user', text: 'do it'),
            _item('r1', 'reasoning', text: 'hmm'),
            _item('c1', 'tool_call'),
          ],
          startedAt: DateTime(2026),
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: const {});
    expect(rows.map((r) => r.runtimeType).toList(), [
      MessageRowData,
      ReasoningRowData,
      ToolCallRowData,
      WorkingRowData,
    ]);
    expect((rows.last as WorkingRowData).turnId, 't1');
  });

  test('settled turn folds work; keeps user prompt + trailing answer', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('u1', 'message', role: 'user', text: 'do it'),
            _item('r1', 'reasoning'),
            _item('c1', 'tool_call'),
            _item('m1', 'message', role: 'assistant', text: 'done'),
          ],
          stopReason: 'end_turn',
          startedAt: DateTime(2026, 1, 1, 0, 0, 0),
          endedAt: DateTime(2026, 1, 1, 0, 2, 35),
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: const {});
    expect(rows.map((r) => r.runtimeType).toList(), [
      MessageRowData,
      TurnFoldRowData,
      MessageRowData,
    ]);
    final fold = rows[1] as TurnFoldRowData;
    expect(fold.hiddenCount, 2);
    expect(fold.duration, const Duration(minutes: 2, seconds: 35));
    expect(fold.cancelled, isFalse);
  });

  test('expandedTurnIds unfolds a settled turn', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('c1', 'tool_call'),
            _item('m1', 'message', role: 'assistant'),
          ],
          stopReason: 'end_turn',
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: {'t1'});
    expect(rows.map((r) => r.runtimeType).toList(), [
      ToolCallRowData,
      MessageRowData,
    ]);
  });

  test('error turn emits ErrorRow; fold flags item errors', () {
    final err = AgentError(category: 'api', message: 'boom', retryable: false);
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            AgentItem(itemId: 'c1', kind: 'tool_call', error: err),
            _item('m1', 'message', role: 'assistant'),
          ],
          stopReason: 'error',
          error: err,
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: const {});
    expect(rows.whereType<ErrorRowData>().single.error.message, 'boom');
    expect(rows.whereType<TurnFoldRowData>().single.hasError, isTrue);
  });

  test('cancelled turn folds with cancelled flag', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [_item('c1', 'tool_call')],
          stopReason: 'cancelled',
        ),
      ],
    );
    final fold = deriveRows(
      state,
      expandedTurnIds: const {},
    ).whereType<TurnFoldRowData>().single;
    expect(fold.cancelled, isTrue);
  });

  test('compaction surfaces even when folded', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('c1', 'tool_call'),
            const AgentItem(itemId: 'k1', kind: 'compaction'),
            _item('m1', 'message', role: 'assistant'),
          ],
          stopReason: 'end_turn',
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: const {});
    expect(rows.whereType<CompactionRowData>(), hasLength(1));
  });

  test(
    'live compaction waits for turn end before showing completed divider',
    () {
      final live = AgentSessionState(
        turns: [
          AgentTurn(
            turnId: 't1',
            items: [const AgentItem(itemId: 'k1', kind: 'compaction')],
          ),
        ],
      );

      final liveRows = deriveRows(live, expandedTurnIds: const {});

      expect(liveRows.whereType<CompactionRowData>(), isEmpty);
      expect(liveRows.whereType<WorkingRowData>(), hasLength(1));

      final settled = AgentSessionState(
        turns: [
          AgentTurn(
            turnId: 't1',
            items: const [AgentItem(itemId: 'k1', kind: 'compaction')],
            stopReason: 'end_turn',
          ),
        ],
      );

      final settledRows = deriveRows(settled, expandedTurnIds: const {});

      expect(settledRows.whereType<CompactionRowData>(), hasLength(1));
      expect(settledRows.whereType<WorkingRowData>(), isEmpty);
    },
  );

  test('pending prompts become markers before the working row', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(turnId: 't1', items: [_item('c1', 'tool_call')]),
      ],
      pendingPermissions: const [
        AgentPermissionRequest(
          sessionId: 's',
          permissionId: 'p1',
          title: 'Run?',
          options: [],
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: const {});
    final marker = rows.whereType<PromptMarkerRowData>().single;
    expect(marker.isPermission, isTrue);
    expect(rows.indexOf(marker), lessThan(rows.length - 1));
    expect(rows.last, isA<WorkingRowData>());
    expect((rows.last as WorkingRowData).waitingOnUser, isTrue);
  });

  test('unknown kinds fall back, plan/subtask map to their rows', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('p1', 'plan'),
            _item('s1', 'subtask'),
            _item('x1', 'someNewKind'),
          ],
          stopReason: 'end_turn',
        ),
      ],
    );
    final rows = deriveRows(state, expandedTurnIds: {'t1'});
    expect(rows.map((r) => r.runtimeType).toList(), [
      PlanRowData,
      SubtaskRowData,
      UnknownRowData,
    ]);
  });

  test('message rows carry each item own timestamp', () {
    final userAt = DateTime(2026, 1, 1, 9, 0, 0);
    final asstAt = DateTime(2026, 1, 1, 9, 5, 0);
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('u1', 'message', role: 'user', text: 'hi', timestamp: userAt),
            _item(
              'm1',
              'message',
              role: 'assistant',
              text: 'yo',
              timestamp: asstAt,
            ),
          ],
          stopReason: 'end_turn',
        ),
      ],
    );
    final msgs = deriveRows(
      state,
      expandedTurnIds: {'t1'},
    ).whereType<MessageRowData>().toList();
    expect(msgs[0].isUser, isTrue);
    expect(msgs[0].timestamp, userAt);
    expect(msgs[1].isUser, isFalse);
    expect(msgs[1].timestamp, asstAt);
  });

  test('message timestamp is null when the item has none', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [_item('m1', 'message', role: 'assistant', text: 'partial')],
          startedAt: DateTime(2026),
        ),
      ],
    );
    final msg = deriveRows(
      state,
      expandedTurnIds: const {},
    ).whereType<MessageRowData>().single;
    expect(msg.timestamp, isNull);
  });

  test('rowKeys are unique and stable', () {
    final state = AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          items: [
            _item('a', 'message', role: 'user'),
            _item('b', 'tool_call'),
          ],
        ),
      ],
    );
    final keys = deriveRows(
      state,
      expandedTurnIds: const {},
    ).map((r) => r.rowKey).toList();
    expect(keys.toSet().length, keys.length);
  });

  group('usage footers', () {
    AgentSessionState settledTurn({
      Map<String, AgentTokenUsage> usageByItem = const {},
      Map<String, AgentTokenUsage> usageByTurn = const {},
    }) => AgentSessionState(
      turns: [
        AgentTurn(
          turnId: 't1',
          stopReason: 'end_turn',
          items: [
            _item('u1', 'message', role: 'user', text: 'go'),
            _item('c1', 'tool_call'),
            _item('a1', 'message', role: 'assistant', text: 'done'),
          ],
        ),
      ],
      usageByItem: usageByItem,
      usageByTurn: usageByTurn,
    );

    test('turn-level usage attaches to the last assistant message', () {
      final rows = deriveRows(
        settledTurn(
          usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
        ),
        expandedTurnIds: const {'t1'},
      );
      final assistant = rows.whereType<MessageRowData>().last;
      expect(assistant.rowKey, 'msg:a1');
      expect(assistant.usage?.totalTokens, 1200);
    });

    test('item-anchored usage attaches to its assistant message', () {
      final rows = deriveRows(
        settledTurn(
          usageByItem: {'a1': const AgentTokenUsage(totalTokens: 900)},
        ),
        expandedTurnIds: const {'t1'},
      );
      final message = rows.whereType<MessageRowData>().singleWhere(
        (row) => row.rowKey == 'msg:a1',
      );
      expect(message.usage?.totalTokens, 900);
    });

    test('item-anchored footer suppresses the turn-level one', () {
      final rows = deriveRows(
        settledTurn(
          usageByItem: {'a1': const AgentTokenUsage(totalTokens: 900)},
          usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
        ),
        expandedTurnIds: const {'t1'},
      );
      final usages = rows.whereType<MessageRowData>().where(
        (row) => row.usage != null,
      );
      expect(usages.length, 1);
      expect(usages.single.usage?.totalTokens, 900);
    });

    test('folded turn keeps its turn-level footer', () {
      final rows = deriveRows(
        settledTurn(
          usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
        ),
        expandedTurnIds: const {},
      );
      final assistant = rows.whereType<MessageRowData>().last;
      expect(assistant.usage?.totalTokens, 1200);
    });

    test('folded tool-only turn keeps a standalone usage fallback', () {
      final rows = deriveRows(
        AgentSessionState(
          turns: [
            AgentTurn(
              turnId: 't1',
              stopReason: 'end_turn',
              items: [_item('c1', 'tool_call')],
            ),
          ],
          usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
        ),
        expandedTurnIds: const {},
      );

      expect(rows.first, isA<TurnFoldRowData>());
      expect(rows.last, isA<UsageRowData>());
      expect((rows.last as UsageRowData).usage.totalTokens, 1200);
    });

    test('folded item usage stays with visible anchors and never orphans', () {
      final visibleRows = deriveRows(
        settledTurn(
          usageByItem: {'a1': const AgentTokenUsage(totalTokens: 900)},
        ),
        expandedTurnIds: const {},
      );
      final visibleMessage = visibleRows.indexWhere(
        (row) => row.rowKey == 'msg:a1',
      );
      expect(
        (visibleRows[visibleMessage] as MessageRowData).usage?.totalTokens,
        900,
      );

      final hiddenRows = deriveRows(
        AgentSessionState(
          turns: [
            AgentTurn(
              turnId: 't1',
              stopReason: 'end_turn',
              items: [
                _item('u1', 'message', role: 'user', text: 'go'),
                _item(
                  'a-hidden',
                  'message',
                  role: 'assistant',
                  text: 'intermediate',
                ),
                _item('c1', 'tool_call'),
                _item('a-visible', 'message', role: 'assistant', text: 'done'),
              ],
            ),
          ],
          usageByItem: {'a-hidden': const AgentTokenUsage(totalTokens: 600)},
          usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
        ),
        expandedTurnIds: const {},
      );
      expect(hiddenRows.any((row) => row.rowKey == 'msg:a-hidden'), isFalse);
      final visibleAssistant = hiddenRows
          .whereType<MessageRowData>()
          .singleWhere((row) => row.rowKey == 'msg:a-visible');
      expect(visibleAssistant.usage?.totalTokens, 1200);
    });

    test('streaming (unsettled) turn shows no footer', () {
      final state = AgentSessionState(
        turns: [
          AgentTurn(
            turnId: 't1',
            items: [_item('a1', 'message', role: 'assistant', text: 'hi')],
          ),
        ],
        usageByTurn: {'t1': const AgentTokenUsage(totalTokens: 1200)},
      );
      final rows = deriveRows(state, expandedTurnIds: const {});
      expect(
        rows.whereType<MessageRowData>().where((row) => row.usage != null),
        isEmpty,
      );
    });
  });
}
