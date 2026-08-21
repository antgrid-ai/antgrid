import 'dart:convert';

const int kMaxFramePayload = 1500000;
const int kFragThreshold = 1400000;
const int kFragDataBudget = 1400000;
const int kMaxTransferBytes = 33554432;
const int kTransferTimeoutMs = 10000;
const int kGlobalReassemblyBudget = 67108864;
const int kMaxRerequests = 1;
// Mirror of MAX_FRAGMENT_COUNT in antgrid-wire's frag.ts. Receive-side guard: a
// legitimate kMaxTransferBytes transfer needs ~24 fragments; this caps the eager
// `n`-sized parts list a malformed/hostile envelope can ask us to allocate.
const int kMaxFragmentCount = 1024;

class FragHint {
  final String type;
  final String key;

  const FragHint(this.type, this.key);
}

class FragEnvelope {
  final String id;
  final int i;
  final int n;
  final FragHint? hint;
  final String data;

  const FragEnvelope({
    required this.id,
    required this.i,
    required this.n,
    required this.data,
    this.hint,
  });
}

class FragSendError {
  final String code;
  final String message;

  const FragSendError(this.code, this.message);
}

bool isFragEnvelope(Object? v) {
  if (v is! Map) return false;
  final data = v['data'];
  final frag = v['__frag'];
  if (data is! String || frag is! Map) return false;
  return frag['id'] is String && frag['i'] is int && frag['n'] is int;
}

/// UTF-8 byte length of [s] without encoding it. The reassembly budget wants a
/// count, and `utf8.encode(s).length` allocates a full copy of a multi-MB
/// fragment to produce one — ~25x the cost of this scan on ASCII, once per
/// fragment. Mirrors the bridge's `Buffer.byteLength(data, "utf8")`
/// (frag-reassembler.ts), including Dart's substitution of U+FFFD (3 bytes) for
/// an unpaired surrogate, so both ends charge a transfer the same size.
int utf8ByteLength(String s) {
  // Every code unit is worth at least one byte; the loop adds only the excess.
  var bytes = s.length;
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u < 0x80) continue;
    if (u < 0x800) {
      bytes += 1;
      continue;
    }
    if (u >= 0xd800 && u < 0xdc00 && i + 1 < s.length) {
      final low = s.codeUnitAt(i + 1);
      if (low >= 0xdc00 && low < 0xe000) {
        bytes += 2; // surrogate PAIR: 2 code units -> 4 bytes
        i++;
        continue;
      }
    }
    // BMP char, or an unpaired surrogate the encoder replaces with U+FFFD —
    // 3 bytes either way.
    bytes += 2;
  }
  return bytes;
}

// JSON-escaped byte cost of a single Unicode rune. Runes iterate whole code
// points (astral chars as one rune, unpaired surrogates as their raw value), so
// the UTF-8 length is pure arithmetic — no per-character allocation.
int _escapedLenForRune(int rune) {
  if (rune == 0x22 /* " */ || rune == 0x5c /* \ */ ) return 2;
  if (rune == 0x08 ||
      rune == 0x09 ||
      rune == 0x0a ||
      rune == 0x0c ||
      rune == 0x0d) {
    return 2;
  }
  if (rune < 0x20) return 6;
  if (rune >= 0xd800 && rune <= 0xdfff) return 6; // lone surrogate → \uXXXX
  if (rune < 0x80) return 1;
  if (rune < 0x800) return 2;
  if (rune < 0x10000) return 3;
  return 4;
}

List<String> splitForJsonData(String s, int maxEscapedBytes) {
  if (maxEscapedBytes <= 0) {
    throw ArgumentError.value(
      maxEscapedBytes,
      'maxEscapedBytes',
      'must be positive',
    );
  }

  final out = <String>[];
  var curStart = 0;
  var curBytes = 0;
  final it = s.runes.iterator;

  while (it.moveNext()) {
    final start = it.rawIndex;
    final b = _escapedLenForRune(it.current);
    if (curBytes + b > maxEscapedBytes && curStart < start) {
      out.add(s.substring(curStart, start));
      curStart = start;
      curBytes = 0;
    }
    curBytes += b;
  }

  if (curStart < s.length || out.isEmpty) out.add(s.substring(curStart));
  return out;
}

// The `__frag` key is emitted first so every frame begins with `{"__frag"`;
// [FragReassembler.accept] gates on that exact prefix. Keep in lockstep with
// antgrid-wire's frag.ts buildFragments — reordering keys breaks reassembly.
List<String> buildFragments(
  String json,
  String id, [
  FragHint? hint,
  int budget = kFragDataBudget,
]) {
  final slices = splitForJsonData(json, budget);
  final n = slices.length;
  return [
    for (var i = 0; i < n; i++)
      jsonEncode({
        '__frag': {
          'id': id,
          'i': i,
          'n': n,
          if (hint != null) 'hint': {'type': hint.type, 'key': hint.key},
        },
        'data': slices[i],
      }),
  ];
}

class FragReassembler {
  final int timeoutMs;
  final int globalBudgetBytes;
  final void Function(String json, String channel) onComplete;
  final void Function(FragHint? hint) onAbort;
  final int Function() _now;

  final _transfers = <String, _Transfer>{};
  int _totalBytes = 0;

  FragReassembler({
    required this.timeoutMs,
    required this.globalBudgetBytes,
    required this.onComplete,
    required this.onAbort,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool accept(String plaintext, {String channel = 'control'}) {
    // Fast pre-parse filter: buildFragments emits `__frag` first so every
    // fragment frame starts with this prefix (kept in lockstep in frag.ts).
    if (!plaintext.startsWith('{"__frag"')) return false;

    final Object? decoded;
    try {
      decoded = jsonDecode(plaintext);
    } catch (_) {
      return true;
    }
    if (!isFragEnvelope(decoded)) return true;

    final obj = decoded as Map;
    final frag = obj['__frag'] as Map;
    final id = frag['id'] as String;
    final i = frag['i'] as int;
    final n = frag['n'] as int;
    final data = obj['data'] as String;
    final hint = _parseHint(frag['hint']);

    // Bound `n` before allocating the parts list — see kMaxFragmentCount.
    if (n <= 0 || n > kMaxFragmentCount || i < 0 || i >= n) return true;

    var t = _transfers[id];
    if (t == null) {
      t = _Transfer(
        n: n,
        parts: List<String?>.filled(n, null),
        hint: hint,
        channel: channel,
        lastTs: _now(),
      );
      _transfers[id] = t;
    }

    if (t.n != n) {
      _discard(id, t, true);
      return true;
    }

    if (t.parts[i] == null) {
      t.parts[i] = data;
      t.count++;
      final b = utf8ByteLength(data);
      t.bytes += b;
      _totalBytes += b;
    }
    t.hint ??= hint;
    t.lastTs = _now();

    _enforceBudget();

    if (t.count == t.n && _transfers[id] == t) {
      final joinedJson = t.parts.join();
      final ch = t.channel;
      _remove(id, t);
      onComplete(joinedJson, ch);
    }
    return true;
  }

  void sweep() {
    final cutoff = _now() - timeoutMs;
    for (final entry in _transfers.entries.toList()) {
      if (entry.value.lastTs <= cutoff) {
        _discard(entry.key, entry.value, true);
      }
    }
  }

  static FragHint? _parseHint(Object? v) {
    if (v is! Map) return null;
    final type = v['type'];
    final key = v['key'];
    if (type is! String || key is! String) return null;
    return FragHint(type, key);
  }

  void _enforceBudget() {
    while (_totalBytes > globalBudgetBytes && _transfers.isNotEmpty) {
      final oldest = _transfers.entries.reduce(
        (a, b) => a.value.lastTs <= b.value.lastTs ? a : b,
      );
      _discard(oldest.key, oldest.value, true);
    }
  }

  void _remove(String id, _Transfer t) {
    _totalBytes -= t.bytes;
    _transfers.remove(id);
  }

  void _discard(String id, _Transfer t, bool abort) {
    _remove(id, t);
    if (abort) onAbort(t.hint);
  }
}

class _Transfer {
  final int n;
  final List<String?> parts;
  final String channel;
  int count = 0;
  int bytes = 0;
  FragHint? hint;
  int lastTs;

  _Transfer({
    required this.n,
    required this.parts,
    required this.hint,
    required this.channel,
    required this.lastTs,
  });
}
