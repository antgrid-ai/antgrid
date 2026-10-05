import 'dart:collection';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';

enum CommandStatus { idle, running, success, failed }

/// The open end of a run's output grows to this many UTF-16 code units before
/// it is sealed at a line break. It bounds what one flush copies and what the
/// panel re-lays-out.
const int kCommandOutputBlockChars = 4 * 1024;

/// The output kept per run, in UTF-16 code units. The bridge forwards every
/// chunk uncapped, so without this bound a long-lived command grows memory
/// without limit, and so does the layout done when the panel expands.
const int kCommandOutputMaxChars = 256 * 1024;

/// A command run's output, held as sealed blocks plus an open tail.
///
/// An append copies only the tail, and a sealed block stays the same String
/// object while it is kept; the overlay relies on that identity to skip sealed
/// paragraphs.
///
/// Once any output exists, no block and not the tail is empty. An empty
/// paragraph registers no selectable (`RenderParagraph._getSelectableFragments`
/// yields none for empty text), so a copy across it would lose a line break.
class CommandOutput extends ChangeNotifier {
  CommandOutput({
    this.blockChars = kCommandOutputBlockChars,
    this.maxChars = kCommandOutputMaxChars,
  }) : assert(blockChars > 0 && maxChars > 0);

  final int blockChars;
  final int maxChars;

  /// Each sealed block's display text, without its terminator.
  final List<String> _blocks = [];

  /// Parallel to [_blocks]; each entry is '\n' or '\r\n'.
  final List<String> _terminators = [];
  String _tail = '';

  /// No '\n' lies in `_tail[blockChars + 1, _noNewlineTo)`. Output that never
  /// breaks a line (a progress bar redrawn with '\r') would otherwise be
  /// rescanned in full on every append.
  int _noNewlineTo = 0;

  /// The sum of every block's length plus its terminator's length.
  int _sealedChars = 0;
  int _firstBlockSeq = 0;
  bool _trimmed = false;

  List<String> get blocks => UnmodifiableListView(_blocks);
  String get tail => _tail;

  /// Absolute number of `blocks[0]` since the run began.
  int get firstBlockSeq => _firstBlockSeq;
  bool get trimmed => _trimmed;
  bool get isEmpty => _tail.isEmpty && _blocks.isEmpty;
  int get length => _sealedChars + _tail.length;

  /// Exactly the retained text, CRs included. O(length): only user actions and
  /// tests call it.
  String get text {
    final buffer = StringBuffer();
    for (var i = 0; i < _blocks.length; i++) {
      buffer
        ..write(_blocks[i])
        ..write(_terminators[i]);
    }
    buffer.write(_tail);
    return buffer.toString();
  }

  void append(String chunk) {
    if (chunk.isEmpty) return;
    _tail += chunk;
    _seal();
    _trim();
    notifyListeners();
  }

  int _displayEnd(int start, int nl) =>
      nl > start && _tail.codeUnitAt(nl - 1) == 0x0D ? nl - 1 : nl;

  /// The '\n' to seal a block at, or -1 when none may be used. The second
  /// search covers a line longer than the budget; refusing a break that is the
  /// last character keeps the tail non-empty.
  int _blockEnd(int start) {
    var nl = _tail.lastIndexOf('\n', start + blockChars);
    if (nl < start || _displayEnd(start, nl) == start) {
      nl = _tail.indexOf('\n', max(start + blockChars + 1, _noNewlineTo));
      if (nl < 0) _noNewlineTo = _tail.length;
    }
    if (nl < 0 || nl == _tail.length - 1) return -1;
    return nl;
  }

  // Walks indices and copies each substring once, so a large burst is not
  // re-copied per block. Cuts happen only at '\n' with a preceding CR moved
  // into the terminator, so a CRLF is never split.
  void _seal() {
    var start = 0;
    while (_tail.length - start > blockChars) {
      final nl = _blockEnd(start);
      if (nl < 0) break;
      final end = _displayEnd(start, nl);
      _blocks.add(_tail.substring(start, end));
      _terminators.add(end == nl ? '\n' : '\r\n');
      _sealedChars += nl + 1 - start;
      start = nl + 1;
    }
    if (start > 0) {
      _tail = _tail.substring(start);
      _noNewlineTo = max(0, _noNewlineTo - start);
    }
  }

  void _trim() {
    if (length <= maxChars) return;
    var drop = 0;
    var dropped = 0;
    while (drop < _blocks.length && length - dropped > maxChars) {
      dropped += _blocks[drop].length + _terminators[drop].length;
      drop++;
    }
    if (drop > 0) {
      _blocks.removeRange(0, drop);
      _terminators.removeRange(0, drop);
      _sealedChars -= dropped;
      _firstBlockSeq += drop;
      _trimmed = true;
    }
    // Only a single unterminated run longer than the cap reaches here with
    // the tail still over it; keep the newest characters, never starting on
    // the low half of a surrogate pair.
    if (_tail.length > maxChars) {
      var cut = _tail.length - maxChars;
      if (cut < _tail.length - 1 && (_tail.codeUnitAt(cut) & 0xFC00) == 0xDC00) {
        cut++;
      }
      _tail = _tail.substring(cut);
      _noNewlineTo = max(0, _noNewlineTo - cut);
      _trimmed = true;
    }
  }
}

class CommandExecution {
  final String commandName;
  final String projectId;
  final CommandStatus status;
  final int? exitCode;
  final CommandOutput output;

  CommandExecution({
    required this.commandName,
    required this.projectId,
    this.status = CommandStatus.running,
    this.exitCode,
    CommandOutput? output,
  }) : output = output ?? CommandOutput();

  CommandExecution copyWith({CommandStatus? status, int? exitCode}) {
    return CommandExecution(
      commandName: commandName,
      projectId: projectId,
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      output: output,
    );
  }
}

class CommandState {
  final CommandExecution? current;

  const CommandState({this.current});

  CommandState copyWith({
    CommandExecution? current,
    bool clearCurrent = false,
  }) {
    return CommandState(
      current: clearCurrent ? null : (current ?? this.current),
    );
  }
}
