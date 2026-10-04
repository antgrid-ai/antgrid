import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/transcript_row_memo.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

AgentItem _item(String id, {String? text}) =>
    AgentItem(itemId: id, kind: 'message', role: 'assistant', text: text);

void main() {
  group('TranscriptRowWidgetMemo', () {
    late TranscriptRowWidgetMemo memo;
    var builds = 0;
    Widget build() {
      builds++;
      return const SizedBox();
    }

    setUp(() {
      memo = TranscriptRowWidgetMemo();
      builds = 0;
    });

    test('returns the same widget for an equal row, index and variant', () {
      final item = _item('a');
      final first = memo.widgetFor(
        MessageRowData(item, isUser: false),
        0,
        0,
        build,
      );
      final second = memo.widgetFor(
        MessageRowData(item, isUser: false),
        0,
        0,
        build,
      );
      expect(identical(first, second), isTrue);
      expect(builds, 1);
    });

    test('rebuilds when the item, index, variant or weight offset moves', () {
      final item = _item('a');
      MessageRowData row(AgentItem i) => MessageRowData(i, isUser: false);
      memo.widgetFor(row(item), 0, 0, build);
      expect(builds, 1);

      memo.widgetFor(row(_item('a')), 0, 0, build);
      expect(builds, 2);
      final next = _item('a');
      memo.widgetFor(row(next), 1, 0, build);
      expect(builds, 3);
      memo.widgetFor(row(next), 1, 1, build);
      expect(builds, 4);
      memo.widgetFor(row(next), 1, 1, build);
      expect(builds, 4);

      AbTokens.activeWeightOffset = 1;
      addTearDown(() => AbTokens.activeWeightOffset = 0);
      memo.widgetFor(row(next), 1, 1, build);
      expect(builds, 5);
    });

    test('retainOnly drops rows that left the list', () {
      final a = MessageRowData(_item('a'), isUser: false);
      final b = MessageRowData(_item('b'), isUser: false);
      memo.widgetFor(a, 0, 0, build);
      memo.widgetFor(b, 1, 0, build);
      expect(memo.length, 2);

      memo.retainOnly([b]);
      expect(memo.length, 1);
      memo.widgetFor(a, 0, 0, build);
      expect(builds, 3);
    });

    test('clear forgets everything', () {
      final a = MessageRowData(_item('a'), isUser: false);
      memo.widgetFor(a, 0, 0, build);
      memo.clear();
      memo.widgetFor(a, 0, 0, build);
      expect(builds, 2);
    });
  });
}
