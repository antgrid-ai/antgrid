import 'dart:convert';

import 'package:antgrid/storage/first_run_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

// Raw key: under `flutter test` the storage scope prefix is empty
// (see storage_scope.dart), so fixtures may seed the bare literal.
const _key = 'antgrid.first_run.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh store reads defaults', () async {
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    final s = store.read();
    expect(s.checklistDismissed, isFalse);
    expect(s.checklistCompleted, isFalse);
    expect(s.completedSteps, isEmpty);
    expect(s.nudgeSoftDismissed, isFalse);
    expect(s.nudgeDeviceDismissed, isFalse);
    expect(s.handlerArmedOnce, isFalse);
    expect(s.handlerAwayHintDismissed, isFalse);
  });

  test('write then re-open round-trips every field', () async {
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await store.write(
      const FirstRunState(
        checklistDismissed: true,
        checklistCompleted: true,
        completedSteps: {'signIn', 'openProject'},
        nudgeSoftDismissed: true,
        nudgeDeviceDismissed: true,
        handlerArmedOnce: true,
        handlerAwayHintDismissed: true,
      ),
    );

    final reopened = await FirstRunStore.open();
    final s = reopened.read();
    expect(s.checklistDismissed, isTrue);
    expect(s.checklistCompleted, isTrue);
    expect(s.completedSteps, {'signIn', 'openProject'});
    expect(s.nudgeSoftDismissed, isTrue);
    expect(s.nudgeDeviceDismissed, isTrue);
    expect(s.handlerArmedOnce, isTrue);
    expect(s.handlerAwayHintDismissed, isTrue);
  });

  test('corrupt JSON degrades to defaults instead of throwing', () async {
    useInMemoryPrefs({_key: 'not-json{{{'});
    final store = await FirstRunStore.open();
    final s = store.read();
    expect(s.checklistDismissed, isFalse);
    expect(s.completedSteps, isEmpty);
  });

  test('non-map JSON degrades to defaults', () async {
    useInMemoryPrefs({_key: jsonEncode(['a', 'b'])});
    final store = await FirstRunStore.open();
    expect(store.read().checklistDismissed, isFalse);
  });

  test('bad field types degrade per-field, keeping the good ones', () async {
    useInMemoryPrefs({
      _key: jsonEncode({
        'checklistDismissed': 'yes', // wrong type → false
        'checklistCompleted': true,
        'completedSteps': [1, 'signIn', null], // non-strings dropped
        'nudgeSoftDismissed': 42,
      }),
    });
    final store = await FirstRunStore.open();
    final s = store.read();
    expect(s.checklistDismissed, isFalse);
    expect(s.checklistCompleted, isTrue);
    expect(s.completedSteps, {'signIn'});
    expect(s.nudgeSoftDismissed, isFalse);
  });
}
