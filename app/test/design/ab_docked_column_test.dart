// Heights here are the measured ones from the projects drawer: 86 = the
// New Session button + PROJECTS label on desktop, 185 = the tallest first-run
// checklist (five steps + a two-line hint), 45 = UpdateRow / AccountFooter.
import 'package:antgrid/design/widgets/ab_docked_column.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _pinnedRows = [
  SizedBox(key: ValueKey('update'), height: 45),
  SizedBox(key: ValueKey('footer'), height: 45),
];

// No MaterialApp: AbDockedColumn imports package:flutter/widgets.dart only, and
// a box-layout test that needs a theme or a Scaffold to run would be the first
// place a Material dependency could creep in unnoticed.
Widget harness(
  double height, {
  double dockHeight = 171,
  double minBodyExtent = 44,
  List<Widget> pinned = _pinnedRows,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 288,
        height: height,
        child: AbDockedColumn(
          minBodyExtent: minBodyExtent,
          header: const SizedBox(key: ValueKey('header'), height: 86),
          body: ListView(
            key: const ValueKey('body'),
            children: const [SizedBox(height: 500)],
          ),
          dock: SingleChildScrollView(
            key: const ValueKey('viewport'),
            primary: false,
            child: SizedBox(key: const ValueKey('dock'), height: dockHeight),
          ),
          pinned: pinned,
        ),
      ),
    ),
  ),
);

void main() {
  double h(String key, WidgetTester t) =>
      t.getSize(find.byKey(ValueKey(key))).height;
  double y(String key, WidgetTester t) =>
      t.getTopLeft(find.byKey(ValueKey(key))).dy;

  testWidgets('roomy: every slot at natural size, the body takes the rest', (
    t,
  ) async {
    await t.pumpWidget(harness(600));
    expect(t.takeException(), isNull);
    expect(h('header', t), 86);
    expect(y('footer', t), 555);
    expect(h('footer', t), 45);
    expect(y('update', t), 510);
    expect(h('update', t), 45);
    expect(h('viewport', t), 171);
    expect(y('viewport', t), 339);
    expect(h('body', t), 253);
    expect(y('body', t), 86);
  });

  testWidgets('short: the dock scrolls, the body keeps minBodyExtent, and '
      'both pinned rows stay whole', (t) async {
    // 360 = the client height a 400px-tall window leaves the drawer; 185 + the
    // 45 update row is the chrome that overflowed the old Column.
    await t.pumpWidget(harness(360, dockHeight: 185));
    expect(t.takeException(), isNull);
    // Dock CONTENT is still 185 tall; its viewport is capped and scrolls.
    expect(h('dock', t), 185);
    expect(h('viewport', t), 140);
    expect(h('body', t), 44);
    expect(h('update', t), 45);
    expect(h('footer', t), 45);
    expect(y('footer', t), 315);
  });

  testWidgets('tiny: the pinned rows yield bottom-up and nothing overflows', (
    t,
  ) async {
    await t.pumpWidget(harness(100));
    expect(t.takeException(), isNull);
    expect(h('body', t), 0);
    expect(h('viewport', t), 0);
    // The bottom-most pinned row is the last to give: the update row above it
    // is already gone.
    expect(h('footer', t), 14);
    expect(y('footer', t), 86);
    expect(h('update', t), 0);
  });

  testWidgets('degenerate: a panel shorter than the header alone', (t) async {
    await t.pumpWidget(harness(50));
    expect(t.takeException(), isNull);
    expect(h('header', t), 86);
    expect(h('footer', t), 0);
    expect(h('body', t), 0);
  });

  testWidgets('a squeezed pinned row still gets the slot it was budgeted, '
      'whatever its content does inside it', (t) async {
    // Shaped like the real pinned rows — SizedBox > Row (update_row.dart,
    // account_footer.dart) — because the SizedBox is what makes the SLOT
    // correct, and the Row is what makes a squeeze invisible: RenderFlex
    // reports MAIN-axis overflow only, so content overrunning a 14px row
    // raises nothing here. Containing that is the host's job, which is why the
    // drawer clips (see projects_drawer.dart); `takeException` cannot see it,
    // so this test pins the slot instead of pretending to check the paint.
    await t.pumpWidget(
      harness(
        100,
        pinned: const [
          SizedBox(
            key: ValueKey('footer'),
            height: 45,
            child: Row(
              children: [SizedBox(width: 20, height: 20), Text('Account')],
            ),
          ),
        ],
      ),
    );
    expect(t.takeException(), isNull);
    expect(h('footer', t), 14);
    expect(y('footer', t), 86);
  });

  testWidgets('no pinned rows: the dock sits against the bottom edge', (
    t,
  ) async {
    await t.pumpWidget(harness(400, pinned: const []));
    expect(t.takeException(), isNull);
    expect(h('viewport', t), 171);
    expect(y('viewport', t), 229);
    expect(h('body', t), 143);
    expect(y('body', t), 86);
  });

  testWidgets('minBodyExtent defaults to zero: the dock may take everything '
      'below the header', (t) async {
    await t.pumpWidget(harness(200, pinned: const [], minBodyExtent: 0));
    expect(t.takeException(), isNull);
    expect(h('viewport', t), 114);
    expect(h('body', t), 0);
  });

  test('minBodyExtent must not be negative', () {
    expect(
      () => AbDockedColumn(
        header: const SizedBox(),
        body: const SizedBox(),
        dock: const SizedBox(),
        pinned: const [],
        minBodyExtent: -1,
      ),
      throwsAssertionError,
    );
  });
}
