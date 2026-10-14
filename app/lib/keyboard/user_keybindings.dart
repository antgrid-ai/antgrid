import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../providers/demo_mode.dart';
import 'app_shortcuts.dart';

final _kKeybindings = scopedStorageKey('antgrid.keybindings.v1');

/// `ctrl+shift+alt+meta|<logical key id>` — the key id rather than its label,
/// so a binding survives a layout or label change.
@visibleForTesting
String encodeChord(KeyChord chord) => [
  if (chord.control) 'ctrl',
  if (chord.shift) 'shift',
  if (chord.alt) 'alt',
  if (chord.meta) 'meta',
  '|${chord.key.keyId}',
].join('+');

@visibleForTesting
KeyChord? decodeChord(String text) {
  final bar = text.lastIndexOf('|');
  if (bar < 0) return null;
  final id = int.tryParse(text.substring(bar + 1));
  final key = id == null ? null : LogicalKeyboardKey.findKeyByKeyId(id);
  if (key == null) return null;
  final mods = text.substring(0, bar).split('+');
  return KeyChord(
    key,
    control: mods.contains('ctrl'),
    shift: mods.contains('shift'),
    alt: mods.contains('alt'),
    meta: mods.contains('meta'),
  );
}

/// Why [chord] cannot be [command]'s key, or null when it can.
///
/// Checked against the table in force, so a key freed by moving its command
/// elsewhere is free again.
String? keybindingProblem(
  AppCommand command,
  KeyChord chord, {
  TargetPlatform? platform,
}) {
  if (!isRebindable(command)) return '"${command.label}" cannot be changed.';
  final p = platform ?? defaultTargetPlatform;
  final table = appShortcutChords(p);
  final reach = table[command]?.first.reach ?? ChordReach.global;
  final modified = chord.control || chord.alt || chord.meta;
  final functionKey = _functionKeys.contains(chord.key);
  if (reach != ChordReach.local && !modified && !functionKey) {
    final meta = isApplePlatform(p)
        ? '⌘'
        : p == TargetPlatform.linux
        ? 'Super'
        : 'Win';
    return 'Add Ctrl, Alt or $meta: on its '
        'own that key would stop typing it anywhere.';
  }
  final letter =
      chord.key.keyId >= LogicalKeyboardKey.keyA.keyId &&
      chord.key.keyId <= LogicalKeyboardKey.keyZ.keyId;
  if (!isApplePlatform(p) &&
      reach == ChordReach.global &&
      letter &&
      chord.control &&
      !chord.shift &&
      !chord.alt &&
      !chord.meta) {
    return "Ctrl+letter belongs to the agent's terminal — use Ctrl+Shift.";
  }
  for (final MapEntry(key: other, value: chords) in table.entries) {
    if (other == command) continue;
    for (final existing in chords) {
      if (existing != chord) continue;
      // Two widget-bound commands may share a key: each answers only in its
      // own area (Ctrl+W closes a file in one, a preview tab in the other).
      if (reach == ChordReach.local && existing.reach == ChordReach.local) {
        continue;
      }
      return 'Already used by "${other.label}".';
    }
  }
  return null;
}

final _functionKeys = {
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
};

/// The user's rebindings, persisted on this device and pushed into the chord
/// table ([applyUserKeybindings]) whenever they change.
///
/// Loaded asynchronously on first read: until then the defaults are in force,
/// which is also what a store that cannot be read leaves behind.
class UserKeybindings extends Notifier<Map<AppCommand, KeyChord>> {
  @override
  Map<AppCommand, KeyChord> build() {
    // Nothing about the demo reaches disk (see demo/): its rebindings, if
    // any, live only for the session.
    if (!ref.read(demoModeProvider)) _load();
    return const {};
  }

  SharedPreferencesAsync get _prefs =>
      SharedPreferencesAsync(options: desktopSharedPreferencesOptions);

  Future<void> _load() async {
    try {
      final raw = await _prefs.getString(_kKeybindings);
      if (raw == null) return;
      final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
      final loaded = <AppCommand, KeyChord>{
        for (final e in decoded.entries)
          if (AppCommand.values.asNameMap()[e.key] case final command?)
            if (e.value case final String text) command: ?decodeChord(text),
      };
      _set(loaded, persist: false);
    } catch (_) {
      // An unreadable store leaves the defaults; never fail a launch over it.
    }
  }

  void bind(AppCommand command, KeyChord chord) =>
      _set({...state, command: chord});

  void reset(AppCommand command) => _set({...state}..remove(command));

  void resetAll() => _set(const {});

  void _set(Map<AppCommand, KeyChord> next, {bool persist = true}) {
    applyUserKeybindings(next);
    state = userKeybindings;
    if (!persist || ref.read(demoModeProvider)) return;
    final encoded = jsonEncode({
      for (final e in state.entries) e.key.name: encodeChord(e.value),
    });
    _prefs.setString(_kKeybindings, encoded).catchError((_) {});
  }
}

final userKeybindingsProvider =
    NotifierProvider<UserKeybindings, Map<AppCommand, KeyChord>>(
      UserKeybindings.new,
      name: 'userKeybindings',
    );
