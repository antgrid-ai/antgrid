import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _host(Widget child, {double width = 320}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(width: width, child: child),
);

Finder get _editable => find.byType(EditableText);

int? _focusedIndex(WidgetTester tester) {
  final fields = tester.widgetList<EditableText>(_editable).toList();
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].focusNode.hasFocus) return i;
  }
  return null;
}

/// A field from outside the package opting in through the public registrar.
class _CustomField extends StatelessWidget {
  const _CustomField({required this.invalid, required this.focusNode});

  final bool invalid;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) => CarbonFormFieldRegistrar(
    invalid: invalid,
    focusNode: focusNode,
    child: Focus(
      focusNode: focusNode,
      child: const SizedBox(height: 32, width: 100),
    ),
  );
}

void main() {
  group('layout', () {
    testWidgets('children are separated by the form spacing', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonForm(
            children: <Widget>[
              SizedBox(key: Key('a'), height: 20),
              SizedBox(key: Key('b'), height: 20),
            ],
          ),
        ),
      );
      final a = tester.getRect(find.byKey(const Key('a')));
      final b = tester.getRect(find.byKey(const Key('b')));
      expect(b.top - a.bottom, CarbonSpacing.spacing07);
    });

    testWidgets('required note is shown first', (tester) async {
      await pumpCarbon(
        tester,
        _host(
          const CarbonForm(
            requiredNote: 'Fields marked required must be filled in.',
            children: <Widget>[CarbonTextInput(label: 'Name', required: true)],
          ),
        ),
      );
      final note = find.text('Fields marked required must be filled in.');
      expect(note, findsOneWidget);
      expect(
        tester.getRect(note).top,
        lessThan(tester.getRect(find.byType(CarbonTextInput)).top),
      );
    });

    testWidgets('section title is a heading and description is shown', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonForm(
            children: <Widget>[
              CarbonFormSection(
                title: 'Account',
                description: 'How people find you',
                children: <Widget>[CarbonTextInput(label: 'Name')],
              ),
            ],
          ),
        ),
      );
      expect(find.text('How people find you'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Account')),
        matchesSemantics(label: 'Account', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('fields keep separate semantics nodes inside a form', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonForm(
            children: <Widget>[
              CarbonFormSection(
                title: 'Account',
                children: <Widget>[
                  CarbonTextInput(label: 'First', required: true),
                  CarbonTextInput(label: 'Second', errorText: 'Bad second'),
                ],
              ),
            ],
          ),
        ),
      );
      final first = tester.getSemantics(_editable.at(0));
      final second = tester.getSemantics(_editable.at(1));
      expect(first.label, 'First');
      expect(first.hint, contains('Required'));
      expect(second.label, 'Second');
      expect(second.hint, contains('Bad second'));
      handle.dispose();
    });

    testWidgets('form announces as a form region', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCarbon(
        tester,
        _host(
          const CarbonForm(
            children: <Widget>[CarbonTextInput(label: 'Name')],
          ),
        ),
      );
      final root = tester.getSemantics(find.byType(CarbonForm));
      expect(root.role, SemanticsRole.form);
      handle.dispose();
    });

    testWidgets('enlarged text and narrow width do not overflow', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        SingleChildScrollView(child: _host(
          CarbonForm(
            requiredNote: 'A long note about required fields that wraps',
            children: <Widget>[
              const CarbonFormSection(
                title: 'A section with a rather long title for a narrow form',
                description: 'And a description that is just as long as that',
                children: <Widget>[
                  CarbonTextInput(
                    label: 'A very long label for this particular field',
                    errorText: 'An error that has quite a lot to say too',
                  ),
                ],
              ),
              CarbonFormActions(
                children: <Widget>[
                  CarbonButton(
                    label: 'Cancel',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                  CarbonButton(label: 'Save changes', onPressed: () {}),
                ],
              ),
            ],
          ),
          width: 240,
        )),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('actions', () {
    testWidgets('end aligned set sits at the end edge, RTL aware', (
      tester,
    ) async {
      Widget tree() => _host(
        CarbonForm(
          children: <Widget>[
            CarbonFormActions(
              children: <Widget>[
                CarbonButton(
                  key: const Key('cancel'),
                  label: 'Cancel',
                  kind: CarbonButtonKind.secondary,
                  onPressed: () {},
                ),
                CarbonButton(
                  key: const Key('save'),
                  label: 'Save',
                  onPressed: () {},
                ),
              ],
            ),
          ],
        ),
        width: 400,
      );
      await pumpCarbon(tester, tree());
      final host = tester.getRect(find.byType(CarbonForm));
      expect(tester.getRect(find.byKey(const Key('save'))).right, host.right);
      expect(
        tester.getRect(find.byKey(const Key('cancel'))).right,
        lessThanOrEqualTo(tester.getRect(find.byKey(const Key('save'))).left),
      );
      await pumpCarbon(tester, tree(), dir: TextDirection.rtl);
      // In RTL the form's start edge is on the right and the end edge on the
      // left, where the primary action now sits.
      final rtlHost = tester.getRect(find.byType(CarbonForm));
      expect(
        tester.getRect(find.byKey(const Key('save'))).left,
        rtlHost.left,
      );
    });

    testWidgets('busy submit button swallows a second activation', (
      tester,
    ) async {
      var presses = 0;
      await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            children: <Widget>[
              CarbonFormActions(
                children: <Widget>[
                  CarbonButton(
                    key: const Key('save'),
                    label: 'Save',
                    busy: true,
                    onPressed: () => presses++,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('save')));
      await tester.tap(find.byKey(const Key('save')));
      expect(presses, 0);
    });
  });

  group('focusFirstInvalid', () {
    Widget form(CarbonFormController controller, List<Widget> children) =>
        _host(CarbonForm(controller: controller, children: children));

    testWidgets('focuses the first invalid field in visual order', (
      tester,
    ) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(label: 'One'),
          CarbonTextInput(label: 'Two', errorText: 'Bad two'),
          CarbonTextInput(label: 'Three', errorText: 'Bad three'),
        ]),
      );
      expect(controller.invalidFieldCount, 2);
      expect(controller.focusFirstInvalid(), isTrue);
      await tester.pump();
      expect(_focusedIndex(tester), 1);
    });

    testWidgets('follows visual order, not registration order', (
      tester,
    ) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(key: ValueKey<int>(1), label: 'One', errorText: 'x'),
          CarbonTextInput(key: ValueKey<int>(2), label: 'Two', errorText: 'y'),
        ]),
      );
      // Reorder: the keyed second field is now first on screen.
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(key: ValueKey<int>(2), label: 'Two', errorText: 'y'),
          CarbonTextInput(key: ValueKey<int>(1), label: 'One', errorText: 'x'),
        ]),
      );
      controller.focusFirstInvalid();
      await tester.pump();
      expect(_focusedIndex(tester), 0);
    });

    testWidgets('returns false with no invalid field', (tester) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[CarbonTextInput(label: 'One')]),
      );
      expect(controller.invalidFieldCount, 0);
      expect(controller.focusFirstInvalid(), isFalse);
      expect(_focusedIndex(tester), isNull);
    });

    testWidgets('ignores disabled and read-only fields showing no error', (
      tester,
    ) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(label: 'One', errorText: 'x', enabled: false),
          CarbonTextInput(label: 'Two', errorText: 'y', readOnly: true),
          CarbonTextInput(label: 'Three', errorText: 'z'),
        ]),
      );
      expect(controller.invalidFieldCount, 1);
      controller.focusFirstInvalid();
      await tester.pump();
      expect(_focusedIndex(tester), 2);
    });

    testWidgets('picks up errors the host sets later', (tester) async {
      final controller = CarbonFormController();
      Widget tree(String? error) => form(controller, <Widget>[
        const CarbonTextInput(label: 'One'),
        CarbonTextInput(label: 'Two', errorText: error),
      ]);
      await pumpCarbon(tester, tree(null));
      expect(controller.focusFirstInvalid(), isFalse);
      await pumpCarbon(tester, tree('Now invalid'));
      expect(controller.focusFirstInvalid(), isTrue);
      await tester.pump();
      expect(_focusedIndex(tester), 1);
    });

    testWidgets('right to left reads the right-hand field first', (
      tester,
    ) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            controller: controller,
            children: const <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: CarbonTextInput(label: 'Start', errorText: 'x'),
                  ),
                  Expanded(child: CarbonTextInput(label: 'End', errorText: 'y')),
                ],
              ),
            ],
          ),
          width: 600,
        ),
        dir: TextDirection.rtl,
      );
      controller.focusFirstInvalid();
      await tester.pump();
      // The first child sits on the right in RTL.
      expect(_focusedIndex(tester), 0);
    });

    testWidgets('scrolls an off-screen invalid field into view', (
      tester,
    ) async {
      final controller = CarbonFormController();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await pumpCarbon(
        tester,
        SizedBox(
          height: 200,
          child: SingleChildScrollView(
            controller: scroll,
            child: CarbonForm(
              controller: controller,
              children: const <Widget>[
                SizedBox(height: 600),
                CarbonTextInput(label: 'Far', errorText: 'x'),
              ],
            ),
          ),
        ),
        size: const Size(400, 300),
      );
      expect(scroll.offset, 0);
      controller.focusFirstInvalid();
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(_focusedIndex(tester), 0);
    });

    testWidgets('CarbonForm.of reaches the same controller from below', (
      tester,
    ) async {
      late CarbonFormController found;
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            controller: controller,
            children: <Widget>[
              Builder(
                builder: (context) {
                  found = CarbonForm.of(context);
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      );
      expect(found, same(controller));
    });

    testWidgets('form-owned controller works through CarbonForm.of', (
      tester,
    ) async {
      late BuildContext inside;
      await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            children: <Widget>[
              const CarbonTextInput(label: 'One', errorText: 'x'),
              Builder(
                builder: (context) {
                  inside = context;
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      );
      expect(CarbonForm.of(inside).focusFirstInvalid(), isTrue);
      await tester.pump();
      expect(_focusedIndex(tester), 0);
    });

    testWidgets('controller replacement re-registers the fields', (
      tester,
    ) async {
      final a = CarbonFormController();
      final b = CarbonFormController();
      const fields = <Widget>[CarbonTextInput(label: 'One', errorText: 'x')];
      await pumpCarbon(tester, form(a, fields));
      expect(a.invalidFieldCount, 1);
      await pumpCarbon(tester, form(b, fields));
      expect(a.invalidFieldCount, 0);
      expect(b.invalidFieldCount, 1);
    });

    testWidgets('unmounted fields unregister', (tester) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(label: 'One', errorText: 'x'),
        ]),
      );
      expect(controller.invalidFieldCount, 1);
      await pumpCarbon(tester, form(controller, const <Widget>[]));
      expect(controller.invalidFieldCount, 0);
      expect(controller.focusFirstInvalid(), isFalse);
    });

    testWidgets('search participates too', (tester) async {
      final controller = CarbonFormController();
      await pumpCarbon(
        tester,
        form(controller, const <Widget>[
          CarbonTextInput(label: 'One'),
          CarbonSearch(errorText: 'Search failed'),
        ]),
      );
      expect(controller.focusFirstInvalid(), isTrue);
      await tester.pump();
      expect(_focusedIndex(tester), 1);
    });

    testWidgets('other fields opt in through the public registrar', (
      tester,
    ) async {
      final controller = CarbonFormController();
      final custom = FocusNode();
      addTearDown(custom.dispose);
      await pumpCarbon(
        tester,
        form(controller, <Widget>[
          _CustomField(invalid: true, focusNode: custom),
          const CarbonTextInput(label: 'Later', errorText: 'x'),
        ]),
      );
      expect(controller.invalidFieldCount, 2);
      controller.focusFirstInvalid();
      await tester.pump();
      expect(custom.hasFocus, isTrue);
    });

    testWidgets('a field outside any form is a harmless no-op', (
      tester,
    ) async {
      await pumpCarbon(
        tester,
        _host(const CarbonTextInput(label: 'Alone', errorText: 'x')),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('x'), findsOneWidget);
    });
  });

  group('lifecycle and live changes', () {
    testWidgets('theme and density switches keep the entered text', (
      tester,
    ) async {
      final controller = CarbonFormController();
      final text = TextEditingController(text: 'kept');
      addTearDown(text.dispose);
      final harness = await pumpCarbon(
        tester,
        _host(
          CarbonForm(
            controller: controller,
            children: <Widget>[
              CarbonTextInput(controller: text, label: 'One', errorText: 'x'),
            ],
          ),
        ),
      );
      await harness.setDensity(tester, CarbonDensity.touch);
      await harness.setTheme(
        tester,
        CarbonThemeData(
          scheme: CarbonThemeScheme.gray90,
          density: CarbonDensity.touch,
        ),
      );
      expect(text.text, 'kept');
      expect(controller.invalidFieldCount, 1);
    });

    testWidgets('repeated mount and unmount leaves no registrations', (
      tester,
    ) async {
      final controller = CarbonFormController();
      for (var i = 0; i < 4; i++) {
        await pumpCarbon(
          tester,
          _host(
            CarbonForm(
              controller: controller,
              children: <Widget>[
                CarbonTextInput(
                  key: ValueKey<int>(i),
                  label: 'One',
                  errorText: 'x',
                ),
              ],
            ),
          ),
        );
      }
      expect(controller.invalidFieldCount, 1);
      await tester.pumpWidget(const SizedBox());
      expect(controller.invalidFieldCount, 0);
    });
  });
}
