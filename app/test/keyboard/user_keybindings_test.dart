// A rebinding replaces a command's keys everywhere the table is read, keeps
// how far the keys reach, and is refused when it would take a key from
// another command or from the agent's terminal.
import 'package:antgrid/keyboard/app_shortcuts.dart';
import 'package:antgrid/keyboard/user_keybindings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() {
    applyUserKeybindings(const {});
    debugDefaultTargetPlatformOverride = null;
  });

  test('a chord survives the round trip through storage', () {
    const chord = KeyChord(
      LogicalKeyboardKey.keyY,
      control: true,
      shift: true,
      alt: true,
    );
    expect(decodeChord(encodeChord(chord)), chord);
    expect(decodeChord('nonsense'), isNull);
  });

  test('a rebinding replaces every default and keeps the reach', () {
    const chord = KeyChord(LogicalKeyboardKey.keyY, control: true, shift: true);
    applyUserKeybindings({AppCommand.toggleSidebar: chord});

    final bound = appShortcutChords()[AppCommand.toggleSidebar]!;
    expect(bound, [chord]);
    expect(bound.single.reach, ChordReach.global);
    expect(shortcutLabel(AppCommand.toggleSidebar), 'Ctrl+Shift+Y');
  });

  test("another platform's table never carries this machine's rebinding", () {
    applyUserKeybindings({
      AppCommand.toggleSidebar: const KeyChord(
        LogicalKeyboardKey.keyY,
        control: true,
        shift: true,
      ),
    });
    expect(shortcutLabel(AppCommand.toggleSidebar, TargetPlatform.macOS), '⌘B');
  });

  test('keys handled outside the table cannot be rebound', () {
    applyUserKeybindings({
      AppCommand.terminalPaste: const KeyChord(
        LogicalKeyboardKey.keyY,
        control: true,
        shift: true,
      ),
    });
    expect(userKeybindings, isEmpty);
    expect(isRebindable(AppCommand.sendMessage), isFalse);
    expect(isRebindable(AppCommand.goToSession), isFalse);
    expect(isRebindable(AppCommand.toggleSidebar), isTrue);
  });

  group('keybindingProblem', () {
    test('refuses a key another command already has', () {
      final problem = keybindingProblem(
        AppCommand.toggleSidebar,
        const KeyChord(LogicalKeyboardKey.keyK, control: true, shift: true),
      );
      expect(problem, contains(AppCommand.searchSessions.label));
    });

    test('refuses plain Ctrl+letter for an app-wide command', () {
      expect(
        keybindingProblem(
          AppCommand.toggleSidebar,
          const KeyChord(LogicalKeyboardKey.keyY, control: true),
        ),
        contains("agent's terminal"),
      );
    });

    test('refuses a bare key for an app-wide command, but not F-keys', () {
      expect(
        keybindingProblem(
          AppCommand.toggleSidebar,
          const KeyChord(LogicalKeyboardKey.keyY),
        ),
        isNotNull,
      );
      expect(
        keybindingProblem(
          AppCommand.toggleSidebar,
          const KeyChord(LogicalKeyboardKey.f8),
        ),
        isNull,
      );
    });

    test('lets two panel-bound commands share a key', () {
      // Ctrl+W already closes a file; a preview tab is another area.
      expect(
        keybindingProblem(
          AppCommand.closePreviewTab,
          const KeyChord(LogicalKeyboardKey.keyW, control: true),
        ),
        isNull,
      );
    });

    test('accepts a free Ctrl+Shift chord', () {
      expect(
        keybindingProblem(
          AppCommand.toggleSidebar,
          const KeyChord(LogicalKeyboardKey.keyY, control: true, shift: true),
        ),
        isNull,
      );
    });
  });
}
