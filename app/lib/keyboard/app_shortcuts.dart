import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Where a command shows up in the shortcut sheet.
enum AppCommandGroup {
  general('General'),
  navigation('Navigation'),
  keyboard('Moving around'),
  layout('Layout'),
  session('Session'),
  terminal('Terminal'),
  chat('Chat'),
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
  commandPalette('Command palette', AppCommandGroup.general),

  moveFocus('Move between rows and tabs', AppCommandGroup.keyboard),
  expandCollapse(
    'Expand / collapse, or go to the parent / first child',
    AppCommandGroup.keyboard,
  ),
  activate('Open the focused row / enter a tab', AppCommandGroup.keyboard),
  openContextMenu("Open the focused row's menu", AppCommandGroup.keyboard),
  resizePane(
    'Move the focused pane divider (Enter collapses)',
    AppCommandGroup.keyboard,
  ),
  focusAgent('Focus the agent', AppCommandGroup.keyboard),
  focusNextArea(
    'Focus the next area (projects, agent, context panel)',
    AppCommandGroup.keyboard,
  ),
  focusPreviousArea('Focus the previous area', AppCommandGroup.keyboard),

  goBack('Back', AppCommandGroup.navigation),
  goForward('Forward', AppCommandGroup.navigation),
  nextSession('Next session', AppCommandGroup.navigation),
  previousSession('Previous session', AppCommandGroup.navigation),
  goToSession(
    'Go to session 1–8, or the last one',
    AppCommandGroup.navigation,
    range: true,
  ),

  toggleSidebar('Show/hide projects', AppCommandGroup.layout),
  toggleContextPanel('Show/hide context panel', AppCommandGroup.layout),
  toggleMaximizePanel('Maximize/restore context panel', AppCommandGroup.layout),
  showPreviewTab('Show the Preview tab', AppCommandGroup.layout),
  showFilesTab('Show the Files tab', AppCommandGroup.layout),
  showGitTab('Show the Git tab', AppCommandGroup.layout),
  showTerminalsTab('Show the Terminals tab', AppCommandGroup.layout),
  showHandlerTab('Show the Handler tab', AppCommandGroup.layout),

  toggleSessionMode('Switch chat/terminal', AppCommandGroup.session),
  newTerminal('New terminal', AppCommandGroup.terminal),
  nextTerminal('Next terminal tab', AppCommandGroup.terminal),
  previousTerminal('Previous terminal tab', AppCommandGroup.terminal),
  terminalCopy('Copy the selection', AppCommandGroup.terminal),
  terminalPaste('Paste', AppCommandGroup.terminal),
  terminalHistory('Browse history', AppCommandGroup.terminal),

  sendMessage('Send the message', AppCommandGroup.chat),
  messageNewline('New line', AppCommandGroup.chat),
  acceptSuggestion('Accept a / or @ suggestion', AppCommandGroup.chat),
  stopAgent('Stop the agent', AppCommandGroup.chat),

  goToFile('Filter files', AppCommandGroup.files),
  searchInFiles('Search in files', AppCommandGroup.files),
  findInFile('Find in file', AppCommandGroup.files),
  findNext('Next match', AppCommandGroup.files),
  findPrevious('Previous match', AppCommandGroup.files),
  closeFile('Close file', AppCommandGroup.files),
  copyFilePath('Copy file path', AppCommandGroup.files),
  copyRelativePath('Copy relative file path', AppCommandGroup.files),
  nextChange('Next change in a diff', AppCommandGroup.files),
  previousChange('Previous change in a diff', AppCommandGroup.files),

  refresh('Refresh', AppCommandGroup.panels),
  hardRefresh('Refresh, bypassing the cache', AppCommandGroup.panels),
  focusAddressBar('Preview address bar', AppCommandGroup.panels),
  newPreviewTab('New preview tab', AppCommandGroup.panels),
  closePreviewTab('Close preview tab', AppCommandGroup.panels),
  previewBack('Preview: page back', AppCommandGroup.panels),
  previewForward('Preview: page forward', AppCommandGroup.panels),
  nextPreviewTab('Next preview tab', AppCommandGroup.panels),
  previousPreviewTab('Previous preview tab', AppCommandGroup.panels),
  openPreviewInBrowser('Open preview in the browser', AppCommandGroup.panels),
  commit('Commit staged changes', AppCommandGroup.panels),

  confirmDialog('Confirm', AppCommandGroup.dialogs),
  dismiss('Cancel / close', AppCommandGroup.dialogs);

  const AppCommand(this.label, this.group, {this.range = false});
  final String label;
  final AppCommandGroup group;

  /// Bound to a run of keys (1–9) rather than one chord: the sheet shows the
  /// first and last instead of every one, and the handler reads which was
  /// pressed from `AppCommandRegistry.dispatchingChordIndex`.
  final bool range;
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

  /// Punctuation chords also match by the key's US-layout POSITION: on a
  /// German, French or Nordic layout the key that types `/[/] on US types
  /// something else (often a dead key), so matching the character alone would
  /// leave those chords unpressable. The same rule VS Code and browsers use.
  static final Map<LogicalKeyboardKey, PhysicalKeyboardKey> _byPosition = {
    LogicalKeyboardKey.backquote: PhysicalKeyboardKey.backquote,
    LogicalKeyboardKey.slash: PhysicalKeyboardKey.slash,
    LogicalKeyboardKey.comma: PhysicalKeyboardKey.comma,
    LogicalKeyboardKey.bracketLeft: PhysicalKeyboardKey.bracketLeft,
    LogicalKeyboardKey.bracketRight: PhysicalKeyboardKey.bracketRight,
    // AZERTY puts symbols, not digits, on the unshifted digit row.
    LogicalKeyboardKey.digit1: PhysicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2: PhysicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3: PhysicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4: PhysicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5: PhysicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6: PhysicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7: PhysicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8: PhysicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9: PhysicalKeyboardKey.digit9,
  };

  /// Matches key-down AND repeat: a held global chord's repeats must be
  /// swallowed too, or the terminal behind it receives them.
  bool accepts(KeyEvent event, HardwareKeyboard keyboard) {
    if (event is KeyUpEvent) return false;
    if (event.logicalKey != key &&
        // Numpad Enter is the same key to a user.
        !(key == LogicalKeyboardKey.enter &&
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !(_byPosition[key] != null && event.physicalKey == _byPosition[key])) {
      return false;
    }
    return keyboard.isControlPressed == control &&
        keyboard.isShiftPressed == shift &&
        keyboard.isAltPressed == alt &&
        keyboard.isMetaPressed == meta;
  }

  /// `Ctrl+Shift+K` off Apple platforms, `⇧⌘K` on them (Apple's own modifier
  /// order: ⌃⌥⇧⌘). The meta key reads Win on Windows and Super on Linux.
  String label({required bool apple}) =>
      keyCaps(apple: apple).join(apple ? '' : '+');

  /// [label] split into one string per key, for [AbKbdGroup].
  List<String> keyCaps({required bool apple}) => [
    if (control) apple ? '⌃' : 'Ctrl',
    if (alt) apple ? '⌥' : 'Alt',
    if (shift) apple ? '⇧' : 'Shift',
    if (meta)
      apple
          ? '⌘'
          : defaultTargetPlatform == TargetPlatform.linux
          ? 'Super'
          : 'Win',
    _keyName(key, apple: apple),
  ];

  static String _keyName(LogicalKeyboardKey key, {required bool apple}) {
    final special = <LogicalKeyboardKey, (String, String)>{
      LogicalKeyboardKey.enter: ('Enter', '↩'),
      LogicalKeyboardKey.escape: ('Esc', 'esc'),
      LogicalKeyboardKey.tab: ('Tab', '⇥'),
      LogicalKeyboardKey.arrowLeft: ('←', '←'),
      LogicalKeyboardKey.arrowRight: ('→', '→'),
      LogicalKeyboardKey.arrowUp: ('↑', '↑'),
      LogicalKeyboardKey.arrowDown: ('↓', '↓'),
      LogicalKeyboardKey.pageUp: ('PgUp', '⇞'),
      LogicalKeyboardKey.pageDown: ('PgDn', '⇟'),
      LogicalKeyboardKey.home: ('Home', '↖'),
      LogicalKeyboardKey.end: ('End', '↘'),
      LogicalKeyboardKey.space: ('Space', 'Space'),
      LogicalKeyboardKey.contextMenu: ('Menu', 'Menu'),
      LogicalKeyboardKey.insert: ('Ins', 'Ins'),
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
Map<AppCommand, List<KeyChord>> appShortcutChords([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  final base = isApplePlatform(p)
      ? _appleChords
      : p == TargetPlatform.linux
      ? _linuxChords
      : _otherChords;
  // The user's rebindings were recorded on this machine's keyboard, so they
  // apply to its own table only — never to another family listed for reference.
  if (_userOverrides.isEmpty || p != defaultTargetPlatform) return base;
  return _merged[base] ??= {
    ...base,
    for (final MapEntry(key: command, value: chord) in _userOverrides.entries)
      command: [
        KeyChord(
          chord.key,
          control: chord.control,
          shift: chord.shift,
          alt: chord.alt,
          meta: chord.meta,
          // A rebinding changes the keys, never how far they reach.
          reach: base[command]?.first.reach ?? ChordReach.global,
        ),
      ],
  };
}

/// The commands a user may rebind. Excluded: keys handled by code that does
/// not read this table (the terminal's copy/paste, the composer's Enter, list
/// and dialog navigation) — a rebinding there would show a key that does
/// nothing — and the 1–9 run, which is one command per digit.
bool isRebindable(AppCommand command) =>
    !command.range && !_fixedCommands.contains(command);

const _fixedCommands = {
  AppCommand.moveFocus,
  AppCommand.expandCollapse,
  AppCommand.activate,
  AppCommand.openContextMenu,
  AppCommand.resizePane,
  AppCommand.terminalCopy,
  AppCommand.terminalPaste,
  AppCommand.terminalHistory,
  AppCommand.sendMessage,
  AppCommand.messageNewline,
  AppCommand.acceptSuggestion,
  AppCommand.stopAgent,
  AppCommand.confirmDialog,
  AppCommand.dismiss,
};

Map<AppCommand, KeyChord> _userOverrides = const {};
final _merged = Expando<Map<AppCommand, List<KeyChord>>>();

/// The user's rebindings in force, one chord per command replacing all of its
/// defaults. Set by `UserKeybindings`; read through [appShortcutChords].
Map<AppCommand, KeyChord> get userKeybindings => _userOverrides;

void applyUserKeybindings(Map<AppCommand, KeyChord> overrides) {
  _userOverrides = Map.unmodifiable({
    for (final e in overrides.entries)
      if (isRebindable(e.key)) e.key: e.value,
  });
  _merged[_appleChords] = null;
  _merged[_linuxChords] = null;
  _merged[_otherChords] = null;
}

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

/// Linux terminals paste with Ctrl+Shift+V and leave bare Ctrl+V to the
/// program (see `terminal_view_wrapper.dart`); everything else is Windows'.
final Map<AppCommand, List<KeyChord>> _linuxChords = {
  ..._otherChords,
  AppCommand.terminalPaste: const [
    KeyChord(
      LogicalKeyboardKey.keyV,
      control: true,
      shift: true,
      reach: _local,
    ),
    KeyChord(LogicalKeyboardKey.insert, shift: true, reach: _local),
  ],
};

const _local = ChordReach.local;
const _focused = ChordReach.focused;

final Map<AppCommand, List<KeyChord>> _otherChords = {
  AppCommand.searchSessions: const [
    KeyChord(LogicalKeyboardKey.keyK, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.keyK, control: true, reach: _focused),
  ],
  // Ctrl+N and Ctrl+/ are what VS Code, Cursor and the Codex app bind for
  // these; focused, so a terminal that wants them (readline history, undo)
  // keeps them.
  AppCommand.newSession: const [
    KeyChord(LogicalKeyboardKey.keyN, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.keyN, control: true, reach: _focused),
  ],
  AppCommand.openSettings: const [
    KeyChord(LogicalKeyboardKey.comma, control: true),
  ],
  AppCommand.showShortcuts: const [
    KeyChord(LogicalKeyboardKey.slash, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.slash, control: true, reach: _focused),
  ],
  AppCommand.commandPalette: const [
    KeyChord(LogicalKeyboardKey.keyP, control: true, shift: true),
  ],
  AppCommand.focusAgent: const [
    KeyChord(LogicalKeyboardKey.keyA, control: true, shift: true),
  ],
  // F6 is the Windows/GTK "next pane" key; global, so it also leaves the
  // agent's terminal, the one place nothing else can.
  AppCommand.focusNextArea: const [KeyChord(LogicalKeyboardKey.f6)],
  AppCommand.focusPreviousArea: const [
    KeyChord(LogicalKeyboardKey.f6, shift: true),
  ],
  // Ctrl+digit means nothing to almost every terminal program (Ctrl+2 as NUL
  // is the rare exception), so it is free to be global.
  AppCommand.goToSession: [for (final d in _digits) KeyChord(d, control: true)],
  AppCommand.showPreviewTab: const [
    KeyChord(LogicalKeyboardKey.digit1, control: true, shift: true),
  ],
  AppCommand.showFilesTab: const [
    KeyChord(LogicalKeyboardKey.digit2, control: true, shift: true),
  ],
  AppCommand.showGitTab: const [
    KeyChord(LogicalKeyboardKey.digit3, control: true, shift: true),
  ],
  AppCommand.showTerminalsTab: const [
    KeyChord(LogicalKeyboardKey.digit4, control: true, shift: true),
  ],
  AppCommand.showHandlerTab: const [
    KeyChord(LogicalKeyboardKey.digit5, control: true, shift: true),
  ],
  AppCommand.nextTerminal: const [
    KeyChord(LogicalKeyboardKey.bracketRight, control: true, shift: true),
  ],
  AppCommand.previousTerminal: const [
    KeyChord(LogicalKeyboardKey.bracketLeft, control: true, shift: true),
  ],
  // Listed for the sheet; the terminal handles these itself
  // (terminal_view_wrapper.dart).
  AppCommand.terminalCopy: const [
    KeyChord(LogicalKeyboardKey.keyC, control: true, reach: _local),
  ],
  AppCommand.terminalPaste: const [
    KeyChord(LogicalKeyboardKey.keyV, control: true, reach: _local),
    KeyChord(LogicalKeyboardKey.insert, shift: true, reach: _local),
  ],
  AppCommand.terminalHistory: const [
    KeyChord(LogicalKeyboardKey.pageUp, shift: true, reach: _local),
  ],
  // Listed for the sheet; the composer handles these itself (smart_enter.dart).
  AppCommand.sendMessage: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
    KeyChord(LogicalKeyboardKey.enter, control: true, reach: _local),
  ],
  AppCommand.messageNewline: const [
    KeyChord(LogicalKeyboardKey.enter, shift: true, reach: _local),
  ],
  AppCommand.acceptSuggestion: const [
    KeyChord(LogicalKeyboardKey.tab, reach: _local),
  ],
  AppCommand.moveFocus: const [
    KeyChord(LogicalKeyboardKey.arrowUp, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowDown, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
    KeyChord(LogicalKeyboardKey.home, reach: _local),
    KeyChord(LogicalKeyboardKey.end, reach: _local),
  ],
  AppCommand.expandCollapse: const [
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
  ],
  AppCommand.activate: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
    KeyChord(LogicalKeyboardKey.space, reach: _local),
  ],
  // Shift+F10 and the Menu key are the WAI-ARIA keys for a context menu.
  AppCommand.openContextMenu: const [
    KeyChord(LogicalKeyboardKey.f10, shift: true, reach: _local),
    KeyChord(LogicalKeyboardKey.contextMenu, reach: _local),
  ],
  AppCommand.resizePane: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
  ],
  AppCommand.goBack: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, alt: true, reach: _focused),
  ],
  AppCommand.goForward: const [
    KeyChord(LogicalKeyboardKey.arrowRight, alt: true, reach: _focused),
  ],
  // Ctrl+PageDown/Up are the browsers' and VS Code's second spelling of tab
  // cycling.
  AppCommand.nextSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true),
    KeyChord(LogicalKeyboardKey.pageDown, control: true),
  ],
  AppCommand.previousSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.pageUp, control: true),
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
  AppCommand.findNext: const [
    KeyChord(LogicalKeyboardKey.f3, reach: _local),
    KeyChord(LogicalKeyboardKey.keyG, control: true, reach: _local),
  ],
  AppCommand.findPrevious: const [
    KeyChord(LogicalKeyboardKey.f3, shift: true, reach: _local),
    KeyChord(
      LogicalKeyboardKey.keyG,
      control: true,
      shift: true,
      reach: _local,
    ),
  ],
  AppCommand.closeFile: const [
    KeyChord(LogicalKeyboardKey.keyW, control: true, reach: _local),
  ],
  AppCommand.copyFilePath: const [
    KeyChord(LogicalKeyboardKey.keyC, shift: true, alt: true, reach: _local),
  ],
  AppCommand.copyRelativePath: const [
    KeyChord(
      LogicalKeyboardKey.keyC,
      control: true,
      shift: true,
      alt: true,
      reach: _local,
    ),
  ],
  AppCommand.nextChange: const [
    KeyChord(LogicalKeyboardKey.f5, alt: true, reach: _focused),
  ],
  AppCommand.previousChange: const [
    KeyChord(LogicalKeyboardKey.f5, shift: true, alt: true, reach: _focused),
  ],
  AppCommand.refresh: const [
    KeyChord(LogicalKeyboardKey.f5, reach: _local),
    KeyChord(LogicalKeyboardKey.keyR, control: true, reach: _local),
  ],
  AppCommand.hardRefresh: const [
    KeyChord(
      LogicalKeyboardKey.keyR,
      control: true,
      shift: true,
      reach: _local,
    ),
    KeyChord(LogicalKeyboardKey.f5, control: true, reach: _local),
  ],
  AppCommand.focusAddressBar: const [
    KeyChord(LogicalKeyboardKey.keyL, control: true, reach: _local),
    KeyChord(LogicalKeyboardKey.keyD, alt: true, reach: _local),
  ],
  AppCommand.newPreviewTab: const [
    KeyChord(LogicalKeyboardKey.keyT, control: true, reach: _local),
  ],
  AppCommand.closePreviewTab: const [
    KeyChord(LogicalKeyboardKey.keyW, control: true, reach: _local),
  ],
  // Alt+←/→ also mean app-level Back/Forward; bound in the preview only while
  // the page can go that way, so they fall through to the app's otherwise.
  AppCommand.previewBack: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, alt: true, reach: _local),
  ],
  AppCommand.previewForward: const [
    KeyChord(LogicalKeyboardKey.arrowRight, alt: true, reach: _local),
  ],
  AppCommand.nextPreviewTab: const [
    KeyChord(
      LogicalKeyboardKey.pageDown,
      control: true,
      alt: true,
      reach: _local,
    ),
  ],
  AppCommand.previousPreviewTab: const [
    KeyChord(
      LogicalKeyboardKey.pageUp,
      control: true,
      alt: true,
      reach: _local,
    ),
  ],
  AppCommand.openPreviewInBrowser: const [
    KeyChord(
      LogicalKeyboardKey.keyO,
      control: true,
      shift: true,
      reach: _local,
    ),
  ],
  AppCommand.commit: const [
    KeyChord(LogicalKeyboardKey.enter, control: true, reach: _local),
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
  AppCommand.commandPalette: const [
    KeyChord(LogicalKeyboardKey.keyP, shift: true, meta: true),
  ],
  AppCommand.focusAgent: const [
    KeyChord(LogicalKeyboardKey.keyA, shift: true, meta: true),
  ],
  AppCommand.focusNextArea: const [KeyChord(LogicalKeyboardKey.f6)],
  AppCommand.focusPreviousArea: const [
    KeyChord(LogicalKeyboardKey.f6, shift: true),
  ],
  AppCommand.goToSession: [for (final d in _digits) KeyChord(d, meta: true)],
  AppCommand.showPreviewTab: const [
    KeyChord(LogicalKeyboardKey.digit1, alt: true, meta: true),
  ],
  AppCommand.showFilesTab: const [
    KeyChord(LogicalKeyboardKey.digit2, alt: true, meta: true),
  ],
  AppCommand.showGitTab: const [
    KeyChord(LogicalKeyboardKey.digit3, alt: true, meta: true),
  ],
  AppCommand.showTerminalsTab: const [
    KeyChord(LogicalKeyboardKey.digit4, alt: true, meta: true),
  ],
  AppCommand.showHandlerTab: const [
    KeyChord(LogicalKeyboardKey.digit5, alt: true, meta: true),
  ],
  // ⇧⌘] / ⇧⌘[ switch tabs in Terminal.app and the Mac browsers.
  AppCommand.nextTerminal: const [
    KeyChord(LogicalKeyboardKey.bracketRight, shift: true, meta: true),
  ],
  AppCommand.previousTerminal: const [
    KeyChord(LogicalKeyboardKey.bracketLeft, shift: true, meta: true),
  ],
  AppCommand.terminalCopy: const [
    KeyChord(LogicalKeyboardKey.keyC, meta: true, reach: _local),
  ],
  AppCommand.terminalPaste: const [
    KeyChord(LogicalKeyboardKey.keyV, meta: true, reach: _local),
  ],
  AppCommand.terminalHistory: const [
    KeyChord(LogicalKeyboardKey.pageUp, shift: true, reach: _local),
  ],
  AppCommand.sendMessage: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
    KeyChord(LogicalKeyboardKey.enter, meta: true, reach: _local),
  ],
  AppCommand.messageNewline: const [
    KeyChord(LogicalKeyboardKey.enter, shift: true, reach: _local),
  ],
  AppCommand.acceptSuggestion: const [
    KeyChord(LogicalKeyboardKey.tab, reach: _local),
  ],
  AppCommand.moveFocus: const [
    KeyChord(LogicalKeyboardKey.arrowUp, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowDown, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
    KeyChord(LogicalKeyboardKey.home, reach: _local),
    KeyChord(LogicalKeyboardKey.end, reach: _local),
  ],
  AppCommand.expandCollapse: const [
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
  ],
  AppCommand.activate: const [
    KeyChord(LogicalKeyboardKey.enter, reach: _local),
    KeyChord(LogicalKeyboardKey.space, reach: _local),
  ],
  // Shift+F10 and the Menu key are the WAI-ARIA keys for a context menu.
  AppCommand.openContextMenu: const [
    KeyChord(LogicalKeyboardKey.f10, shift: true, reach: _local),
    KeyChord(LogicalKeyboardKey.contextMenu, reach: _local),
  ],
  AppCommand.resizePane: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, reach: _local),
    KeyChord(LogicalKeyboardKey.arrowRight, reach: _local),
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
    KeyChord(LogicalKeyboardKey.pageDown, control: true),
  ],
  AppCommand.previousSession: const [
    KeyChord(LogicalKeyboardKey.tab, control: true, shift: true),
    KeyChord(LogicalKeyboardKey.pageUp, control: true),
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
  AppCommand.copyFilePath: const [
    KeyChord(LogicalKeyboardKey.keyC, alt: true, meta: true, reach: _local),
  ],
  AppCommand.copyRelativePath: const [
    KeyChord(
      LogicalKeyboardKey.keyC,
      shift: true,
      alt: true,
      meta: true,
      reach: _local,
    ),
  ],
  AppCommand.nextChange: const [
    KeyChord(LogicalKeyboardKey.f5, alt: true, reach: _focused),
  ],
  AppCommand.previousChange: const [
    KeyChord(LogicalKeyboardKey.f5, shift: true, alt: true, reach: _focused),
  ],
  AppCommand.refresh: const [
    KeyChord(LogicalKeyboardKey.keyR, meta: true, reach: _local),
    KeyChord(LogicalKeyboardKey.f5, reach: _local),
  ],
  AppCommand.hardRefresh: const [
    KeyChord(LogicalKeyboardKey.keyR, shift: true, meta: true, reach: _local),
  ],
  AppCommand.focusAddressBar: const [
    KeyChord(LogicalKeyboardKey.keyL, meta: true, reach: _local),
  ],
  AppCommand.newPreviewTab: const [
    KeyChord(LogicalKeyboardKey.keyT, meta: true, reach: _local),
  ],
  AppCommand.closePreviewTab: const [
    KeyChord(LogicalKeyboardKey.keyW, meta: true, reach: _local),
  ],
  // ⌘[/⌘] are the app's global Back/Forward, which claim them before the
  // preview could see them; ⌘←/→ are Safari's and Chrome's other spelling.
  AppCommand.previewBack: const [
    KeyChord(LogicalKeyboardKey.arrowLeft, meta: true, reach: _local),
  ],
  AppCommand.previewForward: const [
    KeyChord(LogicalKeyboardKey.arrowRight, meta: true, reach: _local),
  ],
  AppCommand.nextPreviewTab: const [
    KeyChord(
      LogicalKeyboardKey.arrowRight,
      alt: true,
      meta: true,
      reach: _local,
    ),
  ],
  AppCommand.previousPreviewTab: const [
    KeyChord(
      LogicalKeyboardKey.arrowLeft,
      alt: true,
      meta: true,
      reach: _local,
    ),
  ],
  AppCommand.openPreviewInBrowser: const [
    KeyChord(LogicalKeyboardKey.keyO, shift: true, meta: true, reach: _local),
  ],
  AppCommand.commit: const [
    KeyChord(LogicalKeyboardKey.enter, meta: true, reach: _local),
    KeyChord(LogicalKeyboardKey.enter, control: true, reach: _local),
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
