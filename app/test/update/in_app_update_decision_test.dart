import 'package:antgrid/update/in_app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercises the pure hybrid-decision core only. The plugin's platform channel
// (InAppUpdate.*) does not run under `flutter test`, so the actual Play calls
// are verified manually via a Play internal-testing track — see the design doc.
void main() {
  group('decideUpdateAction', () {
    UpdateAction decide({
      bool available = true,
      bool updateInProgress = false,
      bool downloaded = false,
      int updatePriority = 0,
      int stalenessDays = 0,
      bool immediateAllowed = true,
      bool flexibleAllowed = true,
    }) =>
        decideUpdateAction(
          available: available,
          updateInProgress: updateInProgress,
          downloaded: downloaded,
          updatePriority: updatePriority,
          stalenessDays: stalenessDays,
          immediateAllowed: immediateAllowed,
          flexibleAllowed: flexibleAllowed,
        );

    test('no update available → none (even if everything else is set)', () {
      expect(
        decide(available: false, updatePriority: 5, stalenessDays: 99),
        UpdateAction.none,
      );
    });

    test('high priority + immediate allowed → immediate', () {
      expect(decide(updatePriority: 5), UpdateAction.immediate);
    });

    test('very stale + immediate allowed → immediate', () {
      expect(decide(stalenessDays: 30), UpdateAction.immediate);
    });

    test('low priority, fresh → flexible', () {
      expect(
        decide(updatePriority: 1, stalenessDays: 2),
        UpdateAction.flexible,
      );
    });

    test('important but immediate not allowed → falls back to flexible', () {
      expect(
        decide(updatePriority: 5, immediateAllowed: false),
        UpdateAction.flexible,
      );
    });

    test('important, neither flow allowed → none', () {
      expect(
        decide(
          updatePriority: 5,
          immediateAllowed: false,
          flexibleAllowed: false,
        ),
        UpdateAction.none,
      );
    });

    test('unimportant, only flexible disallowed → none', () {
      expect(
        decide(updatePriority: 0, flexibleAllowed: false),
        UpdateAction.none,
      );
    });

    group('priority boundary (threshold = 4)', () {
      test('priority 3 → not immediate (flexible)', () {
        expect(decide(updatePriority: 3), UpdateAction.flexible);
      });
      test('priority 4 → immediate', () {
        expect(decide(updatePriority: 4), UpdateAction.immediate);
      });
    });

    group('staleness boundary (threshold = 14 days)', () {
      test('13 days → not immediate (flexible)', () {
        expect(decide(stalenessDays: 13), UpdateAction.flexible);
      });
      test('14 days → immediate', () {
        expect(decide(stalenessDays: 14), UpdateAction.immediate);
      });
    });

    group('already-started updates (resume on next check)', () {
      test('downloaded flexible update → completeFlexible', () {
        expect(
          decide(available: false, downloaded: true),
          UpdateAction.completeFlexible,
        );
      });

      test('downloaded wins over an in-progress immediate', () {
        expect(
          decide(downloaded: true, updateInProgress: true),
          UpdateAction.completeFlexible,
        );
      });

      test('interrupted immediate (in progress, immediate allowed) → resume', () {
        expect(
          decide(available: false, updateInProgress: true),
          UpdateAction.resumeImmediate,
        );
      });

      test('in progress but immediate not allowed → none', () {
        expect(
          decide(
            available: false,
            updateInProgress: true,
            immediateAllowed: false,
          ),
          UpdateAction.none,
        );
      });
    });
  });
}
