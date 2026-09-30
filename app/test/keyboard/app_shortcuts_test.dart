import 'package:antgrid/keyboard/app_shortcuts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const families = {
    'Windows/Linux': TargetPlatform.windows,
    'Apple': TargetPlatform.macOS,
  };

  for (final MapEntry(key: name, value: platform) in families.entries) {
    group(name, () {
      final chords = appShortcutChords(platform);

      test('every command has a binding', () {
        for (final command in AppCommand.values) {
          expect(chords[command], isNotEmpty, reason: '$command');
        }
      });

      // Two commands on one chord means one of them silently never fires —
      // whichever the dispatcher happens to reach second.
      test('no two app-wide commands share a chord', () {
        final seen = <KeyChord, AppCommand>{};
        for (final entry in chords.entries) {
          for (final chord in entry.value) {
            if (chord.reach == ChordReach.local) continue;
            final prior = seen[chord];
            expect(
              prior,
              isNull,
              reason: '$chord is bound to both $prior and ${entry.key}',
            );
            seen[chord] = entry.key;
          }
        }
      });
    });
  }

  // The agent's CLI owns plain Ctrl+letter. A global chord there would be
  // taken from the agent while its terminal has focus — see
  // `appShortcutChords`.
  test('off Apple, no global chord is a plain Ctrl+letter', () {
    final letters = {
      for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++)
        LogicalKeyboardKey.findKeyByKeyId(
          LogicalKeyboardKey.keyA.keyId + c - 'a'.codeUnitAt(0),
        ),
    };
    for (final entry in appShortcutChords(TargetPlatform.windows).entries) {
      for (final chord in entry.value) {
        if (chord.reach != ChordReach.global) continue;
        final plainCtrlLetter =
            chord.control &&
            !chord.shift &&
            !chord.alt &&
            letters.contains(chord.key);
        expect(plainCtrlLetter, isFalse, reason: '${entry.key}: $chord');
      }
    }
  });

  test('labels follow each platform family', () {
    expect(
      shortcutLabel(AppCommand.toggleSidebar, TargetPlatform.windows),
      'Ctrl+Shift+B',
    );
    expect(shortcutLabel(AppCommand.toggleSidebar, TargetPlatform.macOS), '⌘B');
    expect(
      shortcutLabel(AppCommand.toggleSessionMode, TargetPlatform.macOS),
      '⇧⌘M',
    );
    expect(
      shortcutLabel(AppCommand.nextSession, TargetPlatform.linux),
      'Ctrl+Tab',
    );
  });

  // The browser-style preview chords exist on both families, spelled with
  // each one's primary modifier.
  test('preview browser chords exist on every platform', () {
    const expected = {
      TargetPlatform.windows: {
        AppCommand.newPreviewTab: 'Ctrl+T',
        AppCommand.closePreviewTab: 'Ctrl+W',
        AppCommand.hardRefresh: 'Ctrl+Shift+R',
        AppCommand.previewForward: 'Alt+→',
      },
      TargetPlatform.macOS: {
        AppCommand.newPreviewTab: '⌘T',
        AppCommand.closePreviewTab: '⌘W',
        AppCommand.hardRefresh: '⇧⌘R',
        AppCommand.previewForward: '⌘→',
      },
    };
    for (final MapEntry(key: platform, value: commands) in expected.entries) {
      for (final MapEntry(key: command, value: label) in commands.entries) {
        expect(shortcutLabel(command, platform), label, reason: '$command');
      }
    }
  });

  test('withShortcut appends the primary chord', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(
        withShortcut('Hide projects', AppCommand.toggleSidebar),
        'Hide projects (Ctrl+Shift+B)',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
