import 'dart:convert';
import 'dart:io';

import 'package:antgrid_eval_client/src/commands.dart';

void main() async {
  final handler = CommandHandler((response) {
    stdout.writeln(jsonEncode(response));
  });

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    try {
      final cmd = jsonDecode(line) as Map<String, dynamic>;
      await handler.handle(cmd);
    } catch (e) {
      stdout.writeln(jsonEncode({'event': 'error', 'message': e.toString()}));
    }
  }
}
