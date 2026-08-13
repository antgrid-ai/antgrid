import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';

/// How an address signed in last. Mirrors `AUTH_METHODS` in
/// `web/src/ui/auth-memory.ts` — the two surfaces answer the same question and
/// must keep the same vocabulary.
enum AuthMethod { password, link, github, google }

/// Per-address memory of the last method used, so the sign-in screen can go
/// straight to a password field for someone who has one.
///
/// This exists because the server must not be asked. Telling the client whether
/// an address has an account, a password, or a provider is the enumeration
/// oracle the whole auth surface is built to avoid (see the comments in
/// `web/src/routes/ui.tsx`), so the routing hint can only ever come from what
/// THIS device has watched the user do. It is advisory: an absent or stale hint
/// falls through to the magic link, which works for every address.
///
/// Cacheless [SharedPreferencesAsync] rather than the `WithCache` flavour most
/// of this directory uses: the blob is read once per sign-in attempt and
/// written once per commit, so an in-process cache would buy nothing and the
/// single-owner rule in `scoped_prefs.dart` would gain another key to uphold.
class LastAuthMethodStore {
  static final _key = scopedStorageKey('antgrid.auth_method.v1');

  /// Enough to cover the shared-machine and work/personal cases without
  /// keeping a lifetime record of every address ever typed on this device.
  static const _cap = 5;

  final SharedPreferencesAsync _prefs;

  LastAuthMethodStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  /// The method [email] last committed to on this device, or null when nothing
  /// is remembered. Never throws — a store that will not open is a miss, and a
  /// miss costs the user one extra tap, whereas an error here would block
  /// sign-in outright.
  Future<AuthMethod?> recall(String email) async {
    final key = _normalize(email);
    if (key.isEmpty) return null;
    for (final entry in await _read()) {
      if (entry.email == key) return entry.method;
    }
    return null;
  }

  /// Records [method] as [email]'s most recent, evicting the oldest address
  /// past [_cap]. Never throws, for the same reason as [recall]: this is
  /// bookkeeping behind a sign-in that already succeeded.
  Future<void> remember(String email, AuthMethod method) async {
    final key = _normalize(email);
    if (key.isEmpty) return;
    try {
      final entries = await _read();
      entries
        ..removeWhere((e) => e.email == key)
        ..insert(0, _Entry(key, method));
      if (entries.length > _cap) entries.removeRange(_cap, entries.length);
      await _prefs.setString(
        _key,
        jsonEncode([for (final e in entries) e.toJson()]),
      );
    } catch (_) {}
  }

  /// Most-recent-first. Empty on a cold install and on anything unreadable — a
  /// corrupt blob or an unavailable prefs platform is a cache miss, never a
  /// crash on the sign-in path.
  Future<List<_Entry>> _read() async {
    try {
      final raw = await _prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [for (final item in decoded) ?_Entry.fromJson(item)];
    } catch (_) {
      return [];
    }
  }

  /// Normalized exactly as `AuthService` normalizes a submitted address — keep
  /// in lockstep, or an address typed with different casing recalls nothing.
  static String _normalize(String email) => email.trim().toLowerCase();
}

class _Entry {
  const _Entry(this.email, this.method);
  final String email;
  final AuthMethod method;

  Map<String, dynamic> toJson() => {'email': email, 'method': method.name};

  /// Null for anything that is not a well-formed entry, including a `method`
  /// this build does not know — a downgrade must skip the row, not throw.
  static _Entry? fromJson(Object? json) {
    if (json is! Map) return null;
    final email = json['email'];
    final method = json['method'];
    if (email is! String || email.isEmpty || method is! String) return null;
    for (final m in AuthMethod.values) {
      if (m.name == method) return _Entry(email, m);
    }
    return null;
  }
}
