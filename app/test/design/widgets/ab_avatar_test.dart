import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_avatar.dart';
import '../test_harness.dart';

void main() {
  testWidgets('AbAvatar renders two-letter initials for two words', (
    tester,
  ) async {
    await pumpAntgrid(tester, const AbAvatar(name: 'Ray Tan'));
    expect(find.text('RT'), findsOneWidget);
  });

  testWidgets('AbAvatar renders first two chars for single word', (
    tester,
  ) async {
    await pumpAntgrid(tester, const AbAvatar(name: 'ray'));
    expect(find.text('RA'), findsOneWidget);
  });

  testWidgets('AbAvatar renders ? for empty name', (tester) async {
    await pumpAntgrid(tester, const AbAvatar(name: ''));
    expect(find.text('?'), findsOneWidget);
  });
}
