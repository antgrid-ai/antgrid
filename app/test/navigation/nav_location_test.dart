// app/test/navigation/nav_location_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

void main() {
  test('value equality over all three fields', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    const b = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    const c = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's2',
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  test('copyWith replaces sessionId, keeps the rest', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    final b = a.copyWith(sessionId: 's2');
    expect(b.sessionId, 's2');
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
  });

  test('copyWith can null out sessionId via clearSessionId', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    final b = a.copyWith(clearSessionId: true);
    expect(b.sessionId, isNull);
  });
}
