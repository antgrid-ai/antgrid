// Guards the panel-identity invariant in `WorkspaceShellState._buildPanels`:
// switching _PanelMode must REPARENT the two desktop panels, never remount them.
// A remount disposes the preview's platform WebView and makes PreviewScreen
// re-anchor from a null origin, so every toggle costs a full page load through
// the relay tunnel instead of a relayout.
//
// The harness mirrors _buildPanels()'s Row shapes and uses the real
// [ResizablePane] — its LayoutBuilder is the part that makes reparenting
// non-obvious, because the destination subtree is inflated during layout rather
// than during build.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/widgets/resizable_pane.dart';

enum _PanelMode { normal, contextHidden, contextExpanded }

/// Counts mounts/unmounts of the subtree standing in for a panel.
class _Panel extends StatefulWidget {
  const _Panel({super.key, required this.tally, required this.label});

  final _Tally tally;
  final String label;

  @override
  State<_Panel> createState() => _PanelState();
}

class _Tally {
  int inits = 0;
  int disposes = 0;
}

class _PanelState extends State<_Panel> {
  @override
  void initState() {
    super.initState();
    widget.tally.inits++;
  }

  @override
  void dispose() {
    widget.tally.disposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

class _Harness extends StatefulWidget {
  const _Harness({required this.agent, required this.context_});

  final _Tally agent;
  final _Tally context_;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  _PanelMode mode = _PanelMode.normal;

  void applyMode(_PanelMode next) => setState(() => mode = next);

  final _agentPanelKey = GlobalKey();
  final _contextPanelKey = GlobalKey();

  List<Widget> _buildPanels() {
    switch (mode) {
      case _PanelMode.normal:
        return [
          Expanded(
            child: ResizablePane(
              initialRatio: 0.5,
              left: _Panel(
                key: _agentPanelKey,
                tally: widget.agent,
                label: 'agent',
              ),
              right: _Panel(
                key: _contextPanelKey,
                tally: widget.context_,
                label: 'context',
              ),
            ),
          ),
        ];
      case _PanelMode.contextHidden:
        return [
          Expanded(
            child: _Panel(
              key: _agentPanelKey,
              tally: widget.agent,
              label: 'agent',
            ),
          ),
        ];
      case _PanelMode.contextExpanded:
        return [
          Expanded(
            child: _Panel(
              key: _contextPanelKey,
              tally: widget.context_,
              label: 'context',
            ),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) =>
      Row(children: [const SizedBox(width: 48), ..._buildPanels()]);
}

void main() {
  late _Tally agent;
  late _Tally context_;

  Future<void> pumpHarness(WidgetTester tester) async {
    agent = _Tally();
    context_ = _Tally();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(agent: agent, context_: context_),
        ),
      ),
    );
  }

  Future<void> setMode(WidgetTester tester, _PanelMode mode) async {
    tester.state<_HarnessState>(find.byType(_Harness)).applyMode(mode);
    await tester.pump();
  }

  testWidgets('normal <-> contextExpanded keeps the context panel mounted', (
    tester,
  ) async {
    await pumpHarness(tester);
    expect(context_.inits, 1);

    await setMode(tester, _PanelMode.contextExpanded);
    expect(context_.inits, 1, reason: 'expanding must reparent, not remount');
    expect(context_.disposes, 0);
    expect(find.text('context'), findsOneWidget);

    // Back into ResizablePane, whose LayoutBuilder inflates the destination
    // during layout — the direction most likely to silently fall back to a
    // remount.
    await setMode(tester, _PanelMode.normal);
    expect(context_.inits, 1);
    expect(context_.disposes, 0);
    expect(find.text('context'), findsOneWidget);
  });

  testWidgets('normal <-> contextHidden keeps the agent panel mounted', (
    tester,
  ) async {
    await pumpHarness(tester);
    expect(agent.inits, 1);

    await setMode(tester, _PanelMode.contextHidden);
    expect(
      agent.inits,
      1,
      reason: 'hiding the context panel must not remount the agent',
    );
    expect(agent.disposes, 0);

    await setMode(tester, _PanelMode.normal);
    expect(agent.inits, 1);
    expect(agent.disposes, 0);
    expect(find.text('agent'), findsOneWidget);
  });

  // The panels genuinely absent from a mode are torn down — that is the point of
  // hiding them, and it is what keeps a hidden WebView from holding memory.
  testWidgets('a panel absent from the mode is disposed', (tester) async {
    await pumpHarness(tester);

    await setMode(tester, _PanelMode.contextHidden);
    expect(context_.disposes, 1);

    await setMode(tester, _PanelMode.contextExpanded);
    expect(agent.disposes, 1);
    expect(context_.inits, 2);
  });
}
