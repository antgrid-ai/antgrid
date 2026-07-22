// Tests for PendingPromptPanel: the always-visible pinned panel that hosts
// permission/question resolution (permissions/questions live in a fixed slot,
// not as inline transcript rows).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/pending_prompt_panel.dart';

const _sessionId = 'sess-1';

AgentPermissionRequest _permission({
  String permissionId = 'perm-1',
  String title = 'Run rm -rf?',
  String? reason = 'Cleans build output',
  List<PermissionOption>? options,
}) => AgentPermissionRequest(
  sessionId: _sessionId,
  permissionId: permissionId,
  title: title,
  reason: reason,
  options:
      options ??
      const [
        PermissionOption(
          optionId: 'once',
          label: 'Allow once',
          kind: 'allow_once',
        ),
        PermissionOption(
          optionId: 'always',
          label: 'Allow always',
          kind: 'allow_always',
        ),
        PermissionOption(optionId: 'no', label: 'Reject', kind: 'reject'),
      ],
);

AgentQuestion _question({
  String questionId = 'q-1',
  String kind = 'text',
  String prompt = 'What is your name?',
  List<AgentQuestionOption> options = const [],
  bool isSecret = false,
}) => AgentQuestion(
  sessionId: _sessionId,
  questionId: questionId,
  kind: kind,
  prompt: prompt,
  options: options,
  isSecret: isSecret,
);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders nothing when both lists are empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PendingPromptPanel(
          permissions: const [],
          questions: const [],
          onPermission: (req, opt) {},
          onQuestion: (req, opt) {},
        ),
      ),
    );

    expect(find.byType(PendingPromptPanel), findsOneWidget);
    expect(find.byType(SizedBox), findsOneWidget);
    final sizedBox = tester.widget<SizedBox>(find.byType(SizedBox));
    expect(sizedBox.width, 0);
    expect(sizedBox.height, 0);
  });

  group('permission', () {
    testWidgets('shows PERMISSION label, title, reason, and ordered buttons', (
      tester,
    ) async {
      final request = _permission();
      await tester.pumpWidget(
        _wrap(
          PendingPromptPanel(
            permissions: [request],
            questions: const [],
            onPermission: (req, opt) {},
            onQuestion: (req, opt) {},
          ),
        ),
      );

      expect(find.text('PERMISSION'), findsOneWidget);
      expect(find.text('Run rm -rf?'), findsOneWidget);
      expect(find.text('Cleans build output'), findsOneWidget);

      // Ordered: allow_once, allow_always, reject.
      final labels = ['Allow once', 'Allow always', 'Reject'];
      final positions = labels
          .map((l) => tester.getTopLeft(find.text(l)).dx)
          .toList();
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThan(positions[i - 1]));
      }
    });

    testWidgets('tapping a button fires onPermission with the optionId', (
      tester,
    ) async {
      final request = _permission();
      AgentPermissionRequest? gotRequest;
      String? gotOptionId;
      await tester.pumpWidget(
        _wrap(
          PendingPromptPanel(
            permissions: [request],
            questions: const [],
            onPermission: (req, optionId) {
              gotRequest = req;
              gotOptionId = optionId;
            },
            onQuestion: (req, opt) {},
          ),
        ),
      );

      await tester.tap(find.text('Allow always'));
      await tester.pump();

      expect(gotRequest, same(request));
      expect(gotOptionId, 'always');
    });

    testWidgets('two pending prompts show "1 of 2" and only the first', (
      tester,
    ) async {
      final first = _permission(permissionId: 'perm-1', title: 'First');
      final second = _permission(permissionId: 'perm-2', title: 'Second');
      await tester.pumpWidget(
        _wrap(
          PendingPromptPanel(
            permissions: [first, second],
            questions: const [],
            onPermission: (req, opt) {},
            onQuestion: (req, opt) {},
          ),
        ),
      );

      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
    });
  });

  group('question', () {
    testWidgets('text question with isSecret obscures the field', (
      tester,
    ) async {
      final question = _question(kind: 'text', isSecret: true);
      await tester.pumpWidget(
        _wrap(
          PendingPromptPanel(
            permissions: const [],
            questions: [question],
            onPermission: (req, opt) {},
            onQuestion: (req, opt) {},
          ),
        ),
      );

      expect(find.text('QUESTION'), findsOneWidget);
      final field = tester.widget<AbTextField>(find.byType(AbTextField));
      expect(field.obscureText, isTrue);
    });

    testWidgets('single_select fires onQuestion(q, optionId) on tap', (
      tester,
    ) async {
      final question = _question(
        kind: 'single_select',
        options: const [
          AgentQuestionOption(id: 'yes', label: 'Yes'),
          AgentQuestionOption(id: 'no', label: 'No'),
        ],
      );
      AgentQuestion? gotQuestion;
      Object? gotAnswer;
      await tester.pumpWidget(
        _wrap(
          PendingPromptPanel(
            permissions: const [],
            questions: [question],
            onPermission: (req, opt) {},
            onQuestion: (q, answer) {
              gotQuestion = q;
              gotAnswer = answer;
            },
          ),
        ),
      );

      await tester.tap(find.text('Yes'));
      await tester.pump();

      expect(gotQuestion, same(question));
      expect(gotAnswer, 'yes');
    });

    testWidgets(
      'resolving a question drops its ephemeral picks (no bleed into a re-ask)',
      (tester) async {
        final multi = _question(
          kind: 'multi_select',
          options: const [
            AgentQuestionOption(id: 'a', label: 'Alpha'),
            AgentQuestionOption(id: 'b', label: 'Beta'),
          ],
        );
        Object? gotAnswer;
        Widget panel(List<AgentQuestion> questions) => _wrap(
          PendingPromptPanel(
            permissions: const [],
            questions: questions,
            onPermission: (req, opt) {},
            onQuestion: (q, answer) => gotAnswer = answer,
          ),
        );

        // Ask, pick Alpha.
        await tester.pumpWidget(panel([multi]));
        await tester.tap(find.text('ALPHA'));
        await tester.pump();

        // Resolve (question leaves the pending list), then re-ask the same id.
        await tester.pumpWidget(panel(const []));
        await tester.pump();
        await tester.pumpWidget(panel([multi]));
        await tester.pump();

        // The earlier Alpha pick must not survive the resolve.
        await tester.tap(find.text('Submit'));
        await tester.pump();
        expect(gotAnswer, isA<List<String>>());
        expect((gotAnswer as List<String>), isEmpty);
      },
    );

    testWidgets(
      'multi_select toggles chips then Submit fires onQuestion with a List<String>',
      (tester) async {
        final question = _question(
          kind: 'multi_select',
          options: const [
            AgentQuestionOption(id: 'a', label: 'Alpha'),
            AgentQuestionOption(id: 'b', label: 'Beta'),
            AgentQuestionOption(id: 'c', label: 'Gamma'),
          ],
        );
        AgentQuestion? gotQuestion;
        Object? gotAnswer;
        await tester.pumpWidget(
          _wrap(
            PendingPromptPanel(
              permissions: const [],
              questions: [question],
              onPermission: (req, opt) {},
              onQuestion: (q, answer) {
                gotQuestion = q;
                gotAnswer = answer;
              },
            ),
          ),
        );

        // AbChip.toggle renders its label uppercased (mono chrome).
        await tester.tap(find.text('ALPHA'));
        await tester.pump();
        await tester.tap(find.text('GAMMA'));
        await tester.pump();
        await tester.tap(find.text('Submit'));
        await tester.pump();

        expect(gotQuestion, same(question));
        expect(gotAnswer, isA<List<String>>());
        expect(gotAnswer as List<String>, containsAll(<String>['a', 'c']));
        expect((gotAnswer as List<String>).length, 2);
      },
    );
  });
}
