import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/workspace_view.dart';

/// Where a command shows up in the shortcut sheet.
enum AppCommandGroup {
  general('General'),
  navigation('Navigation'),
  layout('Layout'),
  session('Session'),
  files('Files'),
  panels('Git & preview'),
  dialogs('Dialogs');

  const AppCommandGroup(this.label);
  final String label;
}

/// Every keyboard-reachable action in the app.
///
/// The single source for the key, the label a tooltip or menu shows, and the
/// shortcut sheet — a hint written anywhere else is a hint that drifts from
/// the binding.
enum AppCommand {
  searchSessions('Search sessions', AppCommandGroup.general),
  newSession('New session', AppCommandGroup.general),
  openSettings('Settings', AppCommandGroup.general),
  showShortcuts('Keyboard shortcuts', AppCommandGroup.general),

  goBack('Back', AppCommandGroup.navigation),
  goForward('Forward', AppCommandGroup.navigation),
  nextSession('Next session', AppCommandGroup.navigation),
  previousSession('Previous session', AppCommandGroup.navigation),
  focusAgent('Focus the agent', AppCommandGroup.navigation),
  showPreview('Preview tab', AppCommandGroup.navigation),
  showFiles('Files tab', AppCommandGroup.navigation),
  showGit('Git tab', AppCommandGroup.navigation),
  showTerminals('Terminals tab', AppCommandGroup.navigation),
  showHandler('Handler tab', AppCommandGroup.navigation),

  toggleSidebar('Show/hide projects', AppCommandGroup.layout),
  toggleContextPanel('Show/hide context panel', AppCommandGroup.layout),
  toggleMaximizePanel('Maximize/restore context panel', AppCommandGroup.layout),

  toggleSessionMode('Switch chat/terminal', AppCommandGroup.session),
  newTerminal('New terminal', AppCommandGroup.session),
  stopAgent('Stop the agent (chat composer)', AppCommandGroup.session),

  goToFile('Filter files', AppCommandGroup.files),
  searchInFiles('Search in files', AppCommandGroup.files),
  findInFile('Find in file', AppCommandGroup.files),
  findNext('Next match', AppCommandGroup.files),
  findPrevious('Previous match', AppCommandGroup.files),
  closeFile('Close file', AppCommandGroup.files),

  refresh('Refresh', AppCommandGroup.panels),
  focusAddressBar('Preview address bar', AppCommandGroup.panels),

  confirmDialog('Confirm', AppCommandGroup.dialogs),
  dismiss('Cancel / close', AppCommandGroup.dialogs);

  const AppCommand(this.label, this.group);
  final String label;
  final AppCommandGroup group;

  /// The workspace tab a `show*` command reveals, or null for any other.
  WorkspaceView? get workspaceView => switch (this) {
    showPreview => WorkspaceView.preview,
    showFiles => WorkspaceView.files,
    showGit => WorkspaceView.git,
    showTerminals => WorkspaceView.terminals,
    showHandler => WorkspaceView.handler,
    _ => null,
  };

  static AppCommand forWorkspaceView(WorkspaceView view) => switch (view) {
    WorkspaceView.preview => showPreview,
    WorkspaceView.files => showFiles,
    WorkspaceView.git => showGit,
    WorkspaceView.terminals => showTerminals,
    WorkspaceView.handler => showHandler,
  };
}

/// How far a chord reaches.
enum ChordReach {
  /// Claimed ahead of the focus tree, so it fires even while the agent's
  /// terminal has the keyboard. Reserved for chords no terminal program needs:
  /// the terminal steps aside for these (see `AppCommandRegistry.claims`).
  global,

  /// Dispatched through the focus tree like any `Shortcuts` binding, so a
  /// focused terminal or text field that wants the key keeps it. For chords
  /// that mean something to a shell — Ctrl+K, Alt+←, Ctrl+L.
  focused,

  /// Bound by the widget that owns the action, and only while focus is inside
  /// it. Listed here for its label and the shortcut sheet.
  local,
}

/// One key combination. Modifiers match exactly, as for [SingleActivator]:
/// Ctrl+Shift+K never fires a Ctrl+K binding.
@immutable
class KeyChord {
  const KeyChord(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.reach = ChordReach.global,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;
  final ChordReach reach;

  /// For `Shortcuts`/`CallbackShortcuts`. An Enter chord yields a second one
  /// for numpad Enter, which is the same key to a user.
  List<SingleActivator> get activators => [
    for (final k in [
      key,
      if (key == LogicalKeyboardKey.enter) LogicalKeyboardKey.numpadEnter,
    ])
      SingleActivator(k, control: control, shift: shift, alt: alt, meta: meta),
  ];

  /// Matches key-down AND repeat: a held global chord's repeats must be
  /// swallowed too, or the terminal behind it receives them.

  bool accepts(KeyEvent event, HardwareKeyboard keyboard) {
    if (event is KeyUpEvent) return false;
    if (event.logicalKey != key &&
        // Numpad Enter is the same key to a user.
        !(key == LogicalKeyboardKey.enter &&
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      return false;
    }
    return keyboard.isControlPressed == control &&
        keyboard.isShiftPressed == shift &&
        keyboard.isAltPressed == alt &&
        keyboard.isMetaPressed == meta;
  }

  /// `Ctrl+Shift+K` off Apple platforms, `⇧⌘K` on them (Apple's own modifier
  /// order: ⌃⌥⇧⌘).
  String label({required bool apple}) {
    final name = _keyName(key, apple: apple);
    if (apple) {
      return '${control ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}'
          '${meta ? '⌘' : ''}$name';
    }
    return [
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Win',
      name,
    ].join('+');
  }

  /// [label] split into one string per key, for [AbKbdGroup].
  List<String> keyCaps({required bool apple}) {
    final name = _keyName(key, apple: apple);
    if (apple) {
      return [
        if (control) '⌃',
        if (alt) '⌥',
        if (shift) '⇧',
        if (meta) '⌘',
        name,
      ];
    }
    return [
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Win',
      name,
    ];
  }

  static String _keyName(LogicalKeyboardKey key, {required bool apple}) {
    final special = <LogicalKeyboardKey, (String, String)>{
      LogicalKeyboardKey.enter: ('Enter', '↩'),
      LogicalKeyboardKey.escape: ('Esc', 'esc'),
      LogicalKeyboardKey.tab: ('Tab', '⇥'),
      LogicalKeyboardKey.arrowLeft: ('←', '←'),
      LogicalKeyboardKey.arrowRight: ('→', '→'),
      LogicalKeyboardKey.arrowUp: ('↑', '↑'),
      LogicalKeyboardKey.arrowDown: ('↓', '↓'),
      LogicalKeyboardKey.comma: (',', ','),
      LogicalKeyboardKey.slash: ('/', '/'),
      LogicalKeyboardKey.backquote: ('`', '`'),
      LogicalKeyboardKey.bracketLeft: ('[', '['),
      LogicalKeyboardKey.bracketRight: (']', ']'),
    }[key];
    if (special != null) return apple ? special.$2 : special.$1;
    return key.keyLabel.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, shift, alt, meta);

  @override
  String toString() => label(apple: false);
}

/// Whether [platform] takes ⌘ as its primary modifier.
bool isApplePlatform([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.macOS || p == TargetPlatform.iOS;
}

/// The bindings, per platform family.
///
/// **Off Apple platforms, a global letter chord is Ctrl+Shift+letter, never
/// Ctrl+letter.** The agent runs in a terminal, and agent CLIs, shells and
/// readline all bind plain Ctrl+letter (Ctrl+B, Ctrl+K, Ctrl+N, Ctrl+R…); a
/// global Ctrl+letter would silently take those keys away from the agent.
/// Ctrl+Shift is the convention terminal emulators themselves use for their own
/// chrome. ⌘ never reaches a terminal program, so Apple platforms use it
/// plainly.
///
/// Alt+←/→ stay [ChordReach.focused]: shells use them to move by word.
Map<AppCommand, List<KeyChord>> appShortcutChords([TargetPlatform? platform]) =>
    isApplePlatform(platform) ? _appleChords : _otherChords;

const _local = ChordReach.local;
const _focused = ChordReach.focused;

final Map<AppCommand, List<KeyChord>> _otherChords = {
  AppCommand.searchSessions: const [
    KeyChord(LogicalKeyboardKey.keyK, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.keyK, control: true, reach: _focused),
  ],
  AppCommand.newSession: const [
    KeyChord(LogicalKeyboardKey.keyN, control: true, shift: true),
  ],
  AppCommand.openSettings: const [
    KeyChord(LogicalKeyboardKey.comma, control: true),
  ],
  AppCommand.showShortcuts: const [
    KeyChord(LogicalKeyboardKey.slash, control: true, shift: true),
  ],
  AppCommand.goBack: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, alt: true, reach: _focused),
  ],
  AppCommand.goForward: const [
    KeyChord(LogicalKeyboardKey.arrowRight, alt: true, reach: _focused),
  ],
  AppCommand.nextSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true),
  ],
  AppCommand.previousSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true, shift: true),
  ],
  AppCommand.focusAgent: const [
    KeyChord(LogicalKeyboardKey.digit0, control: true),
  ],
  AppCommand.showPreview: const [
    KeyChord(LogicalKeyboardKey.digit1, control: true),
  ],
  AppCommand.showFiles: const [
    KeyChord(LogicalKeyboardKey.digit2, control: true),
  ],
  AppCommand.showGit: const [
    KeyChord(LogicalKeyboardKey.digit3, control: true),
  ],
  AppCommand.showTerminals: const [
    KeyChord(LogicalKeyboardKey.digit4, control: true),
  ],
  AppCommand.showHandler: const [
    KeyChord(LogicalKeyboardKey.digit5, control: true),
  ],
  AppCommand.toggleSidebar: const [
    KeyChord(LogicalKeyboardKey.keyB, control: true, shift: true),
  ],
  AppCommand.toggleContextPanel: const [
    KeyChord(LogicalKeyboardKey.keyJ, control: true, shift: true),
    KeyChord(
      LogicalKeyboardKey.arrowRight,
      control: true,
      alt: true,
      reach: _focused,
    ),
  ],
  AppCommand.toggleMaximizePanel: const [
    KeyChord(LogicalKeyboardKey.enter, control: true, shift: true),
  ],
  AppCommand.toggleSessionMode: const [
    KeyChord(LogicalKeyboardKey.keyM, control: true, shift: true),
  ],
  AppCommand.newTerminal: const [
    KeyChord(LogicalKeyboardKey.backquote, control: true, shift: true),
  ],
  AppCommand.stopAgent: const [
    KeyChord(LogicalKeyboardKey.escape, reach: _local),
  ],
  AppCommand.goToFile: const [
    KeyChord(LogicalKeyboardKey.keyE, control: true, shift: true),
  ],
  AppCommand.searchInFiles: const [
    KeyChord(LogicalKeyboardKey.keyF, control: true, shift: true),
  ],
  AppCommand.findInFile: const [
    KeyChord(LogicalKeyboardKey.keyF, control: true, reach: _local),
  ],
  AppCommand.findNext: const [KeyChord(LogicalKeyboardKey.f3, reach: _local)],
  AppCommand.findPrevious: const [
    KeyChord(LogicalKeyboardKey.f3, shift: true, reach: _local),
  ],
  AppCommand.closeFile: const [
    KeyChord(LogicalKeyboardKey.keyW, control: true, reach: _local),
  ],
  AppCommand.refresh: const [
    KeyChord(LogicalKeyboardKey.f5, reach: _local),
    KeyChord(LogicalKeyboardKey.keyR, control: true, reach: _local),
  ],
  AppCommand.focusAddressBar: const [
    KeyChord(LogicalKeyboardKey.keyL, control: true, reach: _local),
  ],
  AppCommand.confirmDialog: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
  ],
  AppCommand.dismiss: const [
    KeyChord(LogicalKeyboardKey.escape, reach: _local),
  ],
};

final Map<AppCommand, List<KeyChord>> _appleChords = {
  AppCommand.searchSessions: const [
    KeyChord(LogicalKeyboardKey.keyK, meta: true),
  ],
  AppCommand.newSession: const [KeyChord(LogicalKeyboardKey.keyN, meta: true)],
  AppCommand.openSettings: const [
    KeyChord(LogicalKeyboardKey.comma, meta: true),
  ],
  AppCommand.showShortcuts: const [
    KeyChord(LogicalKeyboardKey.slash, meta: true),
  ],
  AppCommand.goBack: const [
    KeyChord(LogicalKeyboardKey.bracketLeft, meta: true),
    KeyChord(LogicalKeyboardKey.arrowLeft, alt: true, reach: _focused),
  ],
  AppCommand.goForward: const [
    KeyChord(LogicalKeyboardKey.bracketRight, meta: true),
    KeyChord(LogicalKeyboardKey.arrowRight, alt: true, reach: _focused),
  ],
  AppCommand.nextSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true),
  ],
  AppCommand.previousSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true, shift: true),
  ],
  AppCommand.focusAgent: const [
    KeyChord(LogicalKeyboardKey.digit0, meta: true),
  ],
  AppCommand.showPreview: const [
    KeyChord(LogicalKeyboardKey.digit1, meta: true),
  ],
  AppCommand.showFiles: const [KeyChord(LogicalKeyboardKey.digit2, meta: true)],
  AppCommand.showGit: const [KeyChord(LogicalKeyboardKey.digit3, meta: true)],
  AppCommand.showTerminals: const [
    KeyChord(LogicalKeyboardKey.digit4, meta: true),
  ],
  AppCommand.showHandler: const [
    KeyChord(LogicalKeyboardKey.digit5, meta: true),
  ],
  AppCommand.toggleSidebar: const [
    KeyChord(LogicalKeyboardKey.keyB, meta: true),
  ],
  AppCommand.toggleContextPanel: const [
    KeyChord(LogicalKeyboardKey.keyJ, meta: true),
    KeyChord(
      LogicalKeyboardKey.arrowRight,
      alt: true,
      meta: true,
      reach: _focused,
    ),
  ],
  AppCommand.toggleMaximizePanel: const [
    KeyChord(LogicalKeyboardKey.enter, shift: true, meta: true),
  ],
  // ⇧⌘M, not ⌘M: ⌘M is the system's minimize.
  AppCommand.toggleSessionMode: const [
    KeyChord(LogicalKeyboardKey.keyM, shift: true, meta: true),
  ],
  AppCommand.newTerminal: const [
    KeyChord(LogicalKeyboardKey.backquote, control: true, shift: true),
  ],
  AppCommand.stopAgent: const [
    KeyChord(LogicalKeyboardKey.escape, reach: _local),
  ],
  AppCommand.goToFile: const [
    KeyChord(LogicalKeyboardKey.keyE, shift: true, meta: true),
  ],
  AppCommand.searchInFiles: const [
    KeyChord(LogicalKeyboardKey.keyF, shift: true, meta: true),
  ],
  AppCommand.findInFile: const [
    KeyChord(LogicalKeyboardKey.keyF, meta: true, reach: _local),
  ],
  AppCommand.findNext: const [
    KeyChord(LogicalKeyboardKey.keyG, meta: true, reach: _local),
  ],
  AppCommand.findPrevious: const [
    KeyChord(LogicalKeyboardKey.keyG, shift: true, meta: true, reach: _local),
  ],
  AppCommand.closeFile: const [
    KeyChord(LogicalKeyboardKey.keyW, meta: true, reach: _local),
  ],
  AppCommand.refresh: const [
    KeyChord(LogicalKeyboardKey.keyR, meta: true, reach: _local),
  ],
  AppCommand.focusAddressBar: const [
    KeyChord(LogicalKeyboardKey.keyL, meta: true, reach: _local),
  ],
  AppCommand.confirmDialog: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
  ],
  AppCommand.dismiss: const [
    KeyChord(LogicalKeyboardKey.escape, reach: _local),
  ],
};

/// The chord a hint shows for [command] — its first binding — or null when
/// the platform binds none.
KeyChord? primaryChord(AppCommand command, [TargetPlatform? platform]) {
  final chords = appShortcutChords(platform)[command];
  return (chords == null || chords.isEmpty) ? null : chords.first;
}

/// [command]'s primary chord as text, e.g. `Ctrl+Shift+B` / `⌘B`.
String? shortcutLabel(AppCommand command, [TargetPlatform? platform]) =>
    primaryChord(command, platform)?.label(apple: isApplePlatform(platform));

/// A tooltip that names its shortcut: `Hide projects (Ctrl+Shift+B)`.
String withShortcut(String text, AppCommand command) {
  final label = shortcutLabel(command);
  return label == null ? text : '$text ($label)';
}

/// The global command [event] triggers, or null.
AppCommand? globalCommandFor(KeyEvent event, HardwareKeyboard keyboard) {
  for (final entry in appShortcutChords().entries) {
    for (final chord in entry.value) {
      if (chord.reach == ChordReach.global && chord.accepts(event, keyboard)) {
        return entry.key;
      }
    }
  }
  return null;
}

/// `CallbackShortcuts` bindings for the chords of [handlers]' commands on the
/// current platform — the way a widget binds the [ChordReach.local] commands it
/// owns without restating their keys.
Map<ShortcutActivator, VoidCallback> localShortcutBindings(
  Map<AppCommand, VoidCallback> handlers,
) {
  final chords = appShortcutChords();
  return {
    for (final entry in handlers.entries)
      for (final chord in chords[entry.key] ?? const <KeyChord>[])
        for (final activator in chord.activators) activator: entry.value,
  };
}
