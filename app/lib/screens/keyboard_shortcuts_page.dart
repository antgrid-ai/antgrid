import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_segmented.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_toolbar.dart';
import '../keyboard/app_command_registry.dart';
import '../keyboard/app_shortcuts.dart';
import '../keyboard/shortcuts_sheet.dart';
import '../keyboard/user_keybindings.dart';
import '../navigation/back_intent.dart';

/// App settings' Keyboard shortcuts page: every binding on this platform, with
/// a filter — the list runs to dozens of rows, and the user arriving here is
/// usually after one.
///
/// A page within the settings surface rather than a pushed route: a route on
/// top would stop the app's own shortcuts (they fire only while the root route
/// is current), which is an odd thing for the shortcuts page to do.
class KeyboardShortcutsPage extends ConsumerStatefulWidget {
  const KeyboardShortcutsPage({
    super.key,
    required this.onBack,
    required this.onClose,
  });

  /// Back to the settings list.
  final VoidCallback onBack;

  /// Closes settings altogether, as the list's own close button does.
  final VoidCallback onClose;

  @override
  ConsumerState<KeyboardShortcutsPage> createState() =>
      _KeyboardShortcutsPageState();
}

class _KeyboardShortcutsPageState extends ConsumerState<KeyboardShortcutsPage> {
  final _controller = TextEditingController();
  final _recorder = FocusNode(debugLabel: 'shortcut-recorder');
  late final AppCommandRegistry _registry;
  String _query = '';

  /// The chord the user pressed to search by, or null.
  KeyChord? _chord;
  bool _recording = false;

  /// The command whose keys the recorder is capturing, or null when it is
  /// capturing a key search.
  AppCommand? _rebinding;

  /// Why the last recorded keys could not be used, shown until the next try.
  String? _rebindError;

  /// Lists the Mac's keys instead of this machine's, for someone who moves
  /// between the two.
  bool _apple = isApplePlatform();

  static final _modifiers = {
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  @override
  void initState() {
    super.initState();
    _registry = ref.read(appCommandRegistryProvider);
    _recorder.addListener(() {
      // Clicking away ends a recording as surely as a key does.
      if (!_recorder.hasFocus && _recording) _stopRecording();
    });
  }

  @override
  void dispose() {
    if (_recording) _registry.resume();
    _recorder.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startRecording({AppCommand? rebinding}) {
    // Paused, or the chord the user presses would run its command rather than
    // reach the recorder.
    if (!_recording) _registry.pause();
    setState(() {
      _recording = true;
      _rebinding = rebinding;
      _rebindError = null;
    });
    _recorder.requestFocus();
  }

  void _stopRecording() {
    if (!_recording) return;
    _registry.resume();
    setState(() {
      _recording = false;
      _rebinding = null;
    });
  }

  KeyEventResult _onRecorderKey(FocusNode node, KeyEvent event) {
    if (!_recording || event is! KeyDownEvent) return KeyEventResult.handled;
    if (_modifiers.contains(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final bare =
        !keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed;
    // Plain Esc gives up rather than searching for Esc's own commands.
    if (bare && event.logicalKey == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    final chord = KeyChord(
      event.logicalKey,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    final command = _rebinding;
    if (command != null) {
      final problem = keybindingProblem(command, chord);
      if (problem != null) {
        // Stays recording: the next press is the user's second try.
        setState(() => _rebindError = problem);
        return KeyEventResult.handled;
      }
      ref.read(userKeybindingsProvider.notifier).bind(command, chord);
    } else {
      setState(() {
        _chord = chord;
        // Recorded on this machine's keyboard, so searched on its own table.
        _apple = isApplePlatform();
      });
    }
    _stopRecording();
    _recorder.unfocus();
    return KeyEventResult.handled;
  }

  TargetPlatform get _listedPlatform => _apple
      ? TargetPlatform.macOS
      : isApplePlatform()
      ? TargetPlatform.windows
      : defaultTargetPlatform;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final sheet = shortcutLabel(AppCommand.showShortcuts);
    // Above the settings surface's own handler, so Back returns to the list
    // before it closes settings.
    return BackHandler(
      priority: BackPriority.settingsPage,
      onBack: () {
        widget.onBack();
        return true;
      },
      child: Scaffold(
        backgroundColor: antgrid.bgDeepest,
        body: Column(
          children: [
            AbToolbar.panel(
              title: 'KEYBOARD SHORTCUTS',
              leading: AbIconButton(
                icon: AbIcons.back,
                tooltip: withShortcut('Back to settings', AppCommand.goBack),
                onTap: widget.onBack,
              ),
              actions: [
                AbIconButton(icon: AbIcons.close, onTap: widget.onClose),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AbTokens.space12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      [
                        // The modifier rule is the one thing a user cannot
                        // infer from the list: why most chords carry Shift here
                        // but not in other apps.
                        if (!isApplePlatform())
                          'App-wide shortcuts use Ctrl+Shift so plain '
                              "Ctrl+letter keys stay with the agent's terminal.",
                        'Shortcuts marked "when focused" work while that area '
                            '— a file, a panel, a dialog — has the keyboard. '
                            'Keys marked "$kOutsideTerminalNote" work '
                            'everywhere except while the agent terminal has '
                            'the keyboard, which keeps them for its own '
                            'programs. The rest work anywhere.',
                        if (sheet != null)
                          '$sheet shows this list from anywhere.',
                      ].join(' '),
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: antgrid.textMuted,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space8),
                    AbSearchField(
                      controller: _controller,
                      hint: 'Filter by name or key (e.g. "ctrl+k")…',
                      debounce: null,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    if (_rebinding case final command?) ...[
                      const SizedBox(height: AbTokens.space8),
                      AbInlineBanner(
                        text:
                            _rebindError ??
                            'Press the new keys for "${command.label}" '
                                '(Esc to cancel).',
                        color: _rebindError == null
                            ? antgrid.accent
                            : antgrid.error,
                      ),
                    ],
                    const SizedBox(height: AbTokens.space8),
                    Wrap(
                      spacing: AbTokens.space8,
                      runSpacing: AbTokens.space8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Focus(
                          focusNode: _recorder,
                          onKeyEvent: _onRecorderKey,
                          child: AbButton(
                            compact: true,
                            label: _recording && _rebinding == null
                                ? 'Press a shortcut… (Esc to cancel)'
                                : _chord == null
                                ? 'Find by keys'
                                : 'Keys: ${_chord!.label(apple: isApplePlatform())}',
                            onTap: _recording
                                ? _stopRecording
                                : _startRecording,
                          ),
                        ),
                        if (_chord != null && !_recording)
                          AbIconButton(
                            icon: AbIcons.close,
                            tooltip: 'Clear the key search',
                            onTap: () => setState(() => _chord = null),
                          ),
                        AbSegmented<bool>(
                          segments: const [
                            AbSegment(value: false, label: 'Windows / Linux'),
                            AbSegment(value: true, label: 'macOS'),
                          ],
                          selected: _apple,
                          onSelect: (apple) => setState(() {
                            _apple = apple;
                            // A chord pressed here means nothing on the
                            // other family's table.
                            _chord = null;
                          }),
                        ),
                        if (ref.watch(userKeybindingsProvider).isNotEmpty)
                          AbButton(
                            compact: true,
                            label: 'Reset all keys',
                            onTap: () => ref
                                .read(userKeybindingsProvider.notifier)
                                .resetAll(),
                          ),
                      ],
                    ),
                    ShortcutList(
                      query: _query,
                      chord: _chord,
                      platform: _listedPlatform,
                      // Rebinding is for this machine's keyboard, so only
                      // offered on its own table.
                      onEdit: _apple == isApplePlatform()
                          ? (command) => _startRecording(rebinding: command)
                          : null,
                      onReset: (command) => ref
                          .read(userKeybindingsProvider.notifier)
                          .reset(command),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
