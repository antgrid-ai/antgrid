import 'dart:convert';
import 'dart:io';

import 'package:portable_pty/portable_pty.dart';

void main() {
  final isWindows = Platform.isWindows;
  final command = isWindows ? r'C:\Windows\System32\cmd.exe' : '/bin/sh';
  final args = isWindows
      ? ['/c', 'echo', 'hello from portable_pty']
      : ['-c', 'echo hello from portable_pty'];

  final pty = PortablePty.open(rows: 24, cols: 80);

  try {
    print('Spawning command: $command ${args.join(' ')}');
    pty.spawn(command, args: args);
    final output = pty.readSync(4096);
    if (output.isNotEmpty) {
      print(utf8.decode(output));
    } else {
      print('PTY produced no output.');
    }

    final status = pty.tryWait();
    print('child exited: ${status ?? 'still running'}');

    try {
      final mode = pty.getMode();
      print('pty mode canonical=${mode.canonical}, echo=${mode.echo}');
    } on Exception catch (err) {
      // Windows and non-Unix systems may not expose terminal mode flags.
      print('mode unavailable: $err');
    }
  } finally {
    pty.close();
  }
}
