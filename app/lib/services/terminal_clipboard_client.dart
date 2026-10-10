import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
import '../models/terminal_clipboard_message.dart';
import '../util/detached.dart';
import 'terminal_clipboard_coordinator.dart';

typedef ClipboardContext = ({
  String checkoutId,
  String terminalId,
  String runId,
  String attachmentId,
});

class TerminalClipboardClient {
  TerminalClipboardClient({
    required this.send,
    required this.connected,
    TerminalClipboardCoordinator? coordinator,
    int Function()? now,
    String Function()? newId,
  }) : coordinator = coordinator ?? TerminalClipboardCoordinator.instance,
       _now = now ?? (() => _clock.elapsedMilliseconds),
       _newId = newId ?? const Uuid().v4;
  final Future<void> Function(Map<String, dynamic>) send;
  final bool Function() connected;
  final TerminalClipboardCoordinator coordinator;
  final Map<String, ClipboardContext> contexts = {};
  final _claims = <String, TerminalClipboardMessage>{};
  final _expires = <String, int>{};
  final _pending = <String, ({String requestId, int at})>{};
  final _hosts =
      <
        String,
        ({
          String id,
          int generation,
          int expires,
          Completer<bool> result,
          Timer timer,
        })
      >{};
  static final _clock = Stopwatch()..start();
  final int Function() _now;
  final String Function() _newId;
  final _hostResponses = <String>{};
  final _renewed = <String, int>{};
  final _held = <String, Timer>{};

  Map<String, dynamic> _record(
    String type,
    ClipboardContext context,
    Map<String, dynamic> fields,
  ) => createAbMessage('terminal:clipboard:$type', {
    'checkoutId': context.checkoutId,
    'terminalId': context.terminalId,
    'runId': context.runId,
    'attachmentId': context.attachmentId,
    ...fields,
  });
  void _send(
    String type,
    ClipboardContext context,
    Map<String, dynamic> fields,
  ) {
    detached(
      'terminal',
      'send clipboard control',
      () => send(_record(type, context, fields)),
    );
  }

  void foreground(
    Object owner,
    String? terminal, {
    bool programCopies = true,
    void Function()? onCopied,
  }) {
    if (terminal == null) {
      coordinator.unregister(owner);
      return;
    }
    coordinator.register(
      owner,
      this,
      terminal,
      programCopies: programCopies,
      release: () => release(terminal),
      onCopied: onCopied,
    );
  }

  void beforeInput(String terminal, String data) {
    if (data.isEmpty || data == '\x1b[I' || data == '\x1b[O') return;
    final sgr = RegExp(r'^\x1b\[<(\d+);\d+;\d+[Mm]$').firstMatch(data);
    final urxvt = RegExp(r'^\x1b\[(\d+);\d+;\d+M$').firstMatch(data);
    int? button;
    if (sgr != null) {
      button = int.parse(sgr.group(1)!);
    } else if (urxvt != null) {
      button = int.parse(urxvt.group(1)!) - 32;
    } else if (RegExp(r'^\x1b\[M[\s\S]{3}$').hasMatch(data)) {
      button = data.codeUnitAt(3) - 32;
    }
    if (button != null &&
        (button < 0 || button > 255 || (button & (32 | 64)) != 0)) {
      return;
    }
    if (button == null &&
        (RegExp(
              r'^\x1b\[(?:[?>]?[\d;]*c|[\d;]+[Rn]|[?>][\d;]*u|\??[\d;]+\$y|[\d;]*t)$',
            ).hasMatch(data) ||
            RegExp(r'^(?:\x1b[\]P^_]|[\x90\x9d\x9e\x9f])').hasMatch(data))) {
      return;
    }
    if (button != null) {
      if (data.endsWith('m') || (button & 3) == 3) {
        _held.remove(terminal)?.cancel();
        _renewed.remove(terminal);
      } else if (!_held.containsKey(terminal)) {
        final began = _now();
        _held[terminal] = Timer.periodic(const Duration(seconds: 2), (timer) {
          if (_now() - began >= 60000 ||
              !coordinator.eligible(this, terminal)) {
            timer.cancel();
            _held.remove(terminal);
            return;
          }
          _claim(terminal);
        });
      }
    }
    _claim(terminal);
  }

  void _claim(String terminal) {
    final context = contexts[terminal];
    if (context == null ||
        !connected() ||
        !coordinator.eligible(this, terminal)) {
      return;
    }
    final now = _now();
    final pending = _pending[terminal];
    if (pending != null && now - pending.at > 1000) {
      _claims.remove(terminal);
      _expires.remove(terminal);
    }
    if (now - (_renewed[terminal] ?? -2000) < 2000) return;
    final requestId = _newId();
    _renewed[terminal] = now;
    _pending[terminal] = (requestId: requestId, at: now);
    _send('claim', context, {'requestId': requestId});
  }

  void release(String terminal) {
    _held.remove(terminal)?.cancel();
    _pending.remove(terminal);
    _renewed.remove(terminal);
    _expires.remove(terminal);
    final claim = _claims.remove(terminal);
    if (claim != null && connected()) {
      _send('release', claim.context, {
        'claimId': claim.claimId,
        'epoch': claim.epoch,
      });
    }
    final host = _hosts.remove(terminal);
    host?.timer.cancel();
    if (host != null) _hostResponses.remove(host.id);
    host?.result.complete(false);
  }

  void remove(String terminal) {
    release(terminal);
    contexts.remove(terminal);
  }

  void dispose() {
    coordinator.disconnect(this);
    for (final terminal in contexts.keys.toList()) {
      remove(terminal);
    }
  }

  Future<bool> readHost(String terminal) {
    final context = contexts[terminal];
    if (context == null ||
        !connected() ||
        !coordinator.foreground(this, terminal)) {
      return Future.value(false);
    }
    final old = _hosts.remove(terminal);
    old?.timer.cancel();
    if (old != null) _hostResponses.remove(old.id);
    old?.result.complete(false);
    final id = _newId();
    final result = Completer<bool>();
    final timer = Timer(const Duration(seconds: 3), () {
      if (_hosts[terminal]?.id != id) return;
      _hosts.remove(terminal);
      _hostResponses.remove(id);
      result.complete(false);
    });
    _hosts[terminal] = (
      id: id,
      generation: coordinator.generation,
      expires: _now() + 3000,
      result: result,
      timer: timer,
    );
    _send('read-host', context, {'requestId': id});
    return result.future;
  }

  void handle(TerminalClipboardMessage message) {
    final terminal = message.context.terminalId;
    if (!connected() || contexts[terminal] != message.context) return;
    switch (message.type) {
      case 'terminal:clipboard:claimed':
        final pending = _pending[terminal];
        if (pending == null ||
            pending.requestId != message.requestId ||
            _now() - pending.at > 1000 ||
            !coordinator.eligible(this, terminal)) {
          return;
        }
        _pending.remove(terminal);
        if (message.claimId == null) {
          _claims.remove(terminal);
          return;
        }
        _claims[terminal] = message;
        _expires[terminal] = pending.at + message.lifetimeMs!;
      case 'terminal:clipboard:revoked':
        if (_claims[terminal]?.claimId == message.claimId &&
            _claims[terminal]?.epoch == message.epoch) {
          release(terminal);
        }
      case 'terminal:clipboard:write':
        detached('terminal', 'apply clipboard write', () async {
          bool valid() =>
              connected() &&
              contexts[terminal] == message.context &&
              _claims[terminal]?.claimId == message.claimId &&
              _claims[terminal]?.epoch == message.epoch &&
              _now() < (_expires[terminal] ?? 0) &&
              (_pending[terminal] == null ||
                  _now() - _pending[terminal]!.at <= 1000);
          final outcome = await coordinator.copyProgram(
            message.text!,
            connection: this,
            terminal: terminal,
            eventId: message.eventId!,
            valid: valid,
          );
          if (connected() && contexts[terminal] == message.context) {
            await send(
              _record('result', message.context, {
                'claimId': message.claimId,
                'epoch': message.epoch,
                'eventId': message.eventId,
                'outcome': outcome,
              }),
            );
          }
        });
      case 'terminal:clipboard:host-text':
        final host = _hosts[terminal];
        if (host == null ||
            host.id != message.requestId ||
            !_hostResponses.add(host.id)) {
          return;
        }
        detached('terminal', 'apply host clipboard', () async {
          final copied =
              message.text != null &&
              await coordinator.copyHost(
                message.text!,
                generation: host.generation,
                valid: () =>
                    _hosts[terminal]?.id == host.id &&
                    _now() < host.expires &&
                    connected() &&
                    contexts[terminal] == message.context &&
                    coordinator.foreground(this, terminal),
              );
          if (_hosts[terminal]?.id == host.id) _hosts.remove(terminal);
          _hostResponses.remove(host.id);
          host.timer.cancel();
          if (!host.result.isCompleted) host.result.complete(copied);
        });
    }
  }
}
