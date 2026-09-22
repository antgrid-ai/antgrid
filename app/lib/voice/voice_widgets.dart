import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_text_field.dart';
import '../util/detached.dart';
import '../widgets/transcript/composer/composer_controller.dart';
import 'voice_composer_binding.dart';
import 'voice_input.dart';

class VoiceMic extends ConsumerWidget {
  const VoiceMic({super.key, required this.target});
  final VoiceTarget target;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(voicePreviewEnabledProvider)) return const SizedBox.shrink();
    final controller = ref.watch(voiceInputProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final d = controller.draft(target);
        return AbIconButton(
          icon: d.busy ? AbIcons.stop : AbIcons.microphone,
          selected: d.busy,
          tooltip: d.busy
              ? 'Stop dictation'
              : d.text.isNotEmpty
              ? 'Review dictation below'
              : 'Start dictation (simulated)',
          onTap:
              d.phase == VoicePhase.finalizing || d.text.isNotEmpty && !d.busy
              ? null
              : () {
                  if (d.busy) {
                    controller.stop(target);
                    return;
                  }
                  controller.start(target);
                  if (!controller.ready || !controller.permission) {
                    detached(
                      'Voice',
                      'show simulated setup',
                      () => showAbAdaptiveSheet<void>(
                        context,
                        child: VoiceSetup(
                          controller: controller,
                          target: target,
                        ),
                      ),
                    );
                  }
                },
        );
      },
    );
  }
}

class VoicePanel extends ConsumerStatefulWidget {
  const VoicePanel({super.key, required this.target, this.onInsert});
  final VoiceTarget target;
  final bool Function(String)? onInsert;
  @override
  ConsumerState<VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends ConsumerState<VoicePanel> {
  final _text = TextEditingController();
  final _live = ScrollController();
  String _shown = '';
  late final VoiceInputController _voice;
  @override
  void initState() {
    super.initState();
    _voice = ref.read(voiceInputProvider);
  }

  /// Partials append at the bottom of a height-capped shelf, so without this a
  /// long prompt hides exactly the words being recognized right now.
  void _followLiveText(String text) {
    if (text == _shown) return;
    _shown = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_live.hasClients) _live.jumpTo(_live.position.maxScrollExtent);
    });
  }

  @override
  void didUpdateWidget(VoicePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) {
      _voice.preserve(oldWidget.target, deferNotification: true);
    }
  }

  @override
  void dispose() {
    _voice.preserve(widget.target, deferNotification: true);
    _text.dispose();
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(voicePreviewEnabledProvider)) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _voice,
      builder: (context, _) {
        final d = _voice.draft(widget.target);
        if (d.phase == VoicePhase.idle ||
            d.phase == VoicePhase.setup ||
            d.phase == VoicePhase.downloading ||
            d.phase == VoicePhase.permission ||
            d.phase == VoicePhase.denied ||
            d.phase == VoicePhase.preparing) {
          return const SizedBox.shrink();
        }
        if (_text.text != d.text) {
          _text.value = TextEditingValue(
            text: d.text,
            selection: TextSelection.collapsed(offset: d.text.length),
          );
        }
        if (d.busy) _followLiveText(d.text);
        final status = switch (d.phase) {
          VoicePhase.listening =>
            'Listening… ${d.seconds ~/ 60}:${(d.seconds % 60).toString().padLeft(2, '0')}',
          VoicePhase.finalizing => 'Transcribing…',
          VoicePhase.error => 'Dictation interrupted',
          _ => 'Review dictation',
        };
        return Padding(
          padding: const EdgeInsets.all(AbTokens.space8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                label: '${d.phase.name}, simulated dictation',
                excludeSemantics: true,
                child: Text(
                  '$status · Simulated',
                  style: AbTokens.sansStyle(color: context.antgrid.accent),
                ),
              ),
              if (widget.onInsert != null) ...[
                const SizedBox(height: AbTokens.space8),
                if (d.busy)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: AbTokens.rowHeightXl * 3,
                    ),
                    child: SingleChildScrollView(
                      controller: _live,
                      child: Text(
                        d.text.isEmpty ? 'Speak your prompt…' : d.text,
                        style: AbTokens.monoStyle(),
                      ),
                    ),
                  )
                else
                  AbTextField(
                    controller: _text,
                    minLines: 2,
                    maxLines: 5,
                    onChanged: (text) {
                      _voice.edit(widget.target, text);
                      setState(() {});
                    },
                  ),
              ],
              if (d.message != null)
                Text(
                  d.message!,
                  style: AbTokens.sansStyle(
                    color: context.antgrid.textSecondary,
                  ),
                ),
              const SizedBox(height: AbTokens.space8),
              Wrap(
                spacing: AbTokens.space8,
                runSpacing: AbTokens.space8,
                children: [
                  AbButton(
                    label: d.busy
                        ? 'Cancel'
                        : widget.onInsert != null
                        ? 'Discard'
                        : 'Dismiss',
                    onTap: () => _voice.cancel(widget.target),
                  ),
                  // The terminal shelf is the only control surface near the
                  // transcript; the chat composer already has the stop icon
                  // and its own settings gear in the footer row.
                  if (d.phase == VoicePhase.listening &&
                      widget.onInsert != null)
                    AbButton(
                      label: 'Stop',
                      onTap: () => _voice.stop(widget.target),
                    ),
                  if (!d.busy &&
                      widget.onInsert != null &&
                      d.text.isNotEmpty) ...[
                    AbButton(
                      label: d.message?.startsWith('Cannot insert') == true
                          ? 'Retry'
                          : 'Insert',
                      variant: AbButtonVariant.primary,
                      onTap: () =>
                          _voice.insert(widget.target, widget.onInsert!),
                    ),
                    AbButton(
                      label: 'Copy',
                      onTap: () => detached(
                        'Voice',
                        'copy transcript',
                        () => Clipboard.setData(ClipboardData(text: d.text)),
                      ),
                    ),
                  ],
                  if (widget.onInsert != null)
                    VoiceSettingsButton(target: widget.target),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class VoiceSettingsButton extends ConsumerWidget {
  const VoiceSettingsButton({super.key, required this.target});
  final VoiceTarget target;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(voicePreviewEnabledProvider)) return const SizedBox.shrink();
    final c = ref.watch(voiceInputProvider);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AbIconButton(
        icon: AbIcons.settings,
        tooltip: 'Voice input settings',
        onTap: c.active != null
            ? null
            : () => detached(
                'Voice',
                'show voice settings',
                () => showAbAdaptiveSheet<void>(
                  context,
                  child: VoiceSetup(controller: c, target: target),
                ),
              ),
      ),
    );
  }
}

class VoiceSetup extends StatefulWidget {
  const VoiceSetup({super.key, required this.controller, required this.target});
  final VoiceInputController controller;
  final VoiceTarget target;
  @override
  State<VoiceSetup> createState() => _VoiceSetupState();
}

class _VoiceSetupState extends State<VoiceSetup> {
  bool _binding = false;
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final d = c.draft(widget.target);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (!_binding || event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            setState(() => _binding = false);
            return KeyEventResult.handled;
          }
          // Function keys avoid stealing text-entry and host OS dictation chords.
          if (event.logicalKey.keyId < LogicalKeyboardKey.f1.keyId ||
              event.logicalKey.keyId > LogicalKeyboardKey.f12.keyId) {
            return KeyEventResult.handled;
          }
          setState(() {
            c.shortcut = event.logicalKey;
            _binding = false;
          });
          return KeyEventResult.handled;
        },
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Voice input preview',
                        style: AbTokens.monoStyle(),
                      ),
                    ),
                    AbIconButton(
                      icon: AbIcons.close,
                      tooltip: 'Close',
                      onTap: () {
                        c.cancelSetup(widget.target);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
                Text(
                  'Simulated speech. No microphone access, audio storage, network requests, or real model downloads. Review text before sending or inserting.',
                  style: AbTokens.sansStyle(),
                ),
                const SizedBox(height: AbTokens.space12),
                Text(
                  'Language: English · Input: simulated microphone',
                  style: AbTokens.sansStyle(),
                ),
                Text(
                  c.ready
                      ? 'Model: simulated, ready · Storage: 0 B'
                      : 'Model: simulated, setup required · Download: 0 B',
                  style: AbTokens.sansStyle(),
                ),
                const SizedBox(height: AbTokens.space12),
                Text('Test scenario', style: AbTokens.sansStyle()),
                Wrap(
                  spacing: AbTokens.space8,
                  runSpacing: AbTokens.space8,
                  children: [
                    for (final scenario in VoiceScenario.values)
                      AbButton(
                        wrapLabel: true,
                        label:
                            '${c.scenario == scenario ? '✓ ' : ''}${scenario.name}',
                        onTap: c.active != null
                            ? null
                            : () {
                                c.configure(scenario);
                                if (d.text.isEmpty) d.phase = VoicePhase.setup;
                              },
                      ),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                Wrap(
                  spacing: AbTokens.space8,
                  runSpacing: AbTokens.space8,
                  children: [
                    AbButton(
                      wrapLabel: true,
                      label: c.holdToTalk
                          ? 'Shortcut: hold to talk'
                          : 'Shortcut: toggle',
                      onTap: () => setState(() => c.holdToTalk = !c.holdToTalk),
                    ),
                    AbButton(
                      wrapLabel: true,
                      label: _binding
                          ? 'Press F1–F12 (Escape cancels)'
                          : 'Assign shortcut: ${c.shortcut?.keyLabel ?? 'none'}',
                      onTap: () {
                        setState(() => _binding = true);
                        _focus.requestFocus();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),
                if (d.phase == VoicePhase.preparing)
                  Text(
                    'Preparing simulated model… ${(d.progress * 100).round()}%',
                    style: AbTokens.sansStyle(),
                  ),
                if (d.phase == VoicePhase.downloading)
                  Text(
                    'Downloading (simulated)… ${(d.progress * 487).round()} / 487 MB. No data is transferred.',
                    style: AbTokens.sansStyle(),
                  ),
                if (d.phase == VoicePhase.denied)
                  Text(
                    'Microphone access denied (simulated). Choose another scenario to retry.',
                    style: AbTokens.sansStyle(),
                  ),
                if (d.message != null)
                  Text(d.message!, style: AbTokens.sansStyle()),
                Wrap(
                  spacing: AbTokens.space8,
                  children: [
                    AbButton(
                      label: 'Cancel',
                      onTap: () {
                        c.cancelSetup(widget.target);
                        Navigator.of(context).pop();
                      },
                    ),
                    if (c.ready)
                      AbButton(
                        label: 'Remove simulated model',
                        wrapLabel: true,
                        onTap: () => c.configure(c.scenario),
                      ),
                    if (d.phase == VoicePhase.denied)
                      AbButton(
                        label: 'Simulate enabling microphone',
                        wrapLabel: true,
                        onTap: () {
                          c.permission = true;
                          c.start(widget.target);
                          Navigator.of(context).pop();
                        },
                      ),
                    if (d.phase != VoicePhase.preparing &&
                        d.phase != VoicePhase.downloading)
                      AbButton(
                        wrapLabel: true,
                        label: d.text.isNotEmpty
                            ? 'Back to review'
                            : !c.ready
                            ? 'Set up'
                            : 'Allow & start (simulated)',
                        onTap: () {
                          if (d.text.isNotEmpty) {
                            Navigator.of(context).pop();
                            return;
                          }
                          if (c.scenario == VoiceScenario.unavailable) {
                            c.start(widget.target);
                            return;
                          }
                          if (!c.ready) {
                            c.prepare(widget.target);
                            return;
                          }
                          c.grant(widget.target);
                          if (c.active == widget.target) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class VoiceChatEditor extends ConsumerStatefulWidget {
  const VoiceChatEditor({
    super.key,
    required this.target,
    required this.controller,
    required this.builder,
  });
  final VoiceTarget target;
  final ComposerController controller;
  final Widget Function(ComposerController controller) builder;
  @override
  ConsumerState<VoiceChatEditor> createState() => _VoiceChatEditorState();
}

class _VoiceChatEditorState extends ConsumerState<VoiceChatEditor> {
  late final VoiceInputController _voice = ref.read(voiceInputProvider);
  VoiceComposerBinding? _binding;
  bool _manual = false;
  @override
  void initState() {
    super.initState();
    _voice.addListener(_changed);
  }

  void _changed() {
    final d = _voice.draft(widget.target);
    if (d.busy) {
      _binding ??= VoiceComposerBinding(widget.controller, () {
        _manual = true;
        _voice.preserve(widget.target);
      });
      if (d.text.isNotEmpty) _binding!.update(d.text);
    } else if (_binding != null) {
      final binding = _binding!;
      if (!_manual && d.text.isNotEmpty) binding.update(d.text);
      binding.finish(keep: _manual || d.text.isNotEmpty);
      _binding = null;
      _manual = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => binding.dispose());
      if (d.text.isNotEmpty) {
        _voice.edit(widget.target, '');
        if (d.phase != VoicePhase.error) d.phase = VoicePhase.idle;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_changed);
    _binding?.finish(keep: true);
    final binding = _binding;
    if (binding != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => binding.dispose());
    }
    _voice.preserve(widget.target, deferNotification: true);
    if (binding != null) {
      _voice.edit(widget.target, '');
      _voice.draft(widget.target).phase = VoicePhase.idle;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_binding?.preview ?? widget.controller);
}

KeyEventResult handleVoiceKey(
  VoiceInputController c,
  VoiceTarget target,
  KeyEvent event,
) {
  // Escape ends capture and KEEPS the text, matching host OS dictation; the
  // only discard is the explicit button, so a reflex Escape cannot lose a long
  // prompt. Still swallowed while finalizing so it never reaches the terminal.
  if (event.logicalKey == LogicalKeyboardKey.escape && c.draft(target).busy) {
    if (event is KeyDownEvent) c.stop(target);
    return KeyEventResult.handled;
  }
  if (event.logicalKey != c.shortcut || !c.ready || !c.permission) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) {
    if (c.draft(target).busy) {
      if (!c.holdToTalk) c.stop(target);
    } else if (c.draft(target).text.isEmpty) {
      c.start(target);
    }
  } else if (event is KeyUpEvent && c.holdToTalk) {
    c.stop(target);
  }
  return KeyEventResult.handled;
}
