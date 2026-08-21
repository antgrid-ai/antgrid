import 'package:sentry_flutter/sentry_flutter.dart';

final _pathLike = RegExp(r'([a-zA-Z]:)?[\\/][^\s"]+');

String _redact(String input) => input.replaceAll(_pathLike, '<redacted-path>');

// Nullable-preserving variant: keeps null as null rather than coercing to "".
String? _redactNullable(String? input) =>
    input?.replaceAll(_pathLike, '<redacted-path>');

// Recursively redact string values inside arbitrary breadcrumb/extra data —
// nested maps and lists, not just top-level entries (an http/navigation
// breadcrumb commonly nests a URL or route args one level down). Map KEYS are
// redacted too: a breadcrumb/extra map can be keyed by a path or URL (e.g.
// `{'/Users/me/x.dart': 'opened'}`), which would otherwise leak verbatim.
// Non-string scalars pass through untouched.
Object? _redactDeep(Object? value) {
  if (value is String) return _redact(value);
  if (value is Map) {
    return value.map(
      (k, v) => MapEntry(k is String ? _redact(k) : k, _redactDeep(v)),
    );
  }
  if (value is List) {
    return value.map(_redactDeep).toList();
  }
  return value;
}

// Rebuilds a frame with the on-disk path redacted and all source/local content
// dropped. contextLine/preContext/postContext are literal lines of the user's
// source around the crash site, and `vars` carries local variable values — both
// direct content leaks, never needed for an anonymous report, so they are
// dropped (not passed to the constructor), not redacted. Still rebuilt rather
// than mutated in place: 9.x makes absPath/contextLine settable, but
// preContext/postContext/vars stay getter-only, so a frame is the one object
// here that assignment alone can't neutralize.
SentryStackFrame _scrubFrame(SentryStackFrame f) => SentryStackFrame(
  absPath: _redactNullable(f.absPath),
  fileName: f.fileName,
  function: f.function,
  module: f.module,
  lineNo: f.lineNo,
  colNo: f.colNo,
  inApp: f.inApp,
  package: f.package,
  native: f.native,
  platform: f.platform,
  imageAddr: f.imageAddr,
  symbolAddr: f.symbolAddr,
  instructionAddr: f.instructionAddr,
  rawFunction: f.rawFunction,
  stackStart: f.stackStart,
  symbol: f.symbol,
  framesOmitted: f.framesOmitted.isEmpty ? null : List.of(f.framesOmitted),
  // Raw user source/locals — dropped, not redacted.
  contextLine: null,
  preContext: null,
  postContext: null,
);

// `copyWith` (deprecated in 9.x) is kept here deliberately over the public
// constructor: it round-trips the @internal symbolication fields
// (baseAddr/buildId/unknown) the constructor can't accept from app code
// (invalid_use_of_internal_member), so a hand rebuild would silently drop
// native-symbolication data. Frames themselves still can't be mutated in place
// (see _scrubFrame), so a new trace with rebuilt frames is unavoidable.
SentryStackTrace _scrubStackTrace(SentryStackTrace st) =>
    // ignore: deprecated_member_use
    st.copyWith(frames: st.frames.map(_scrubFrame).toList());

/// Strips user content (paths, file/project names, source snippets) from a
/// crash event before transmit. Defense-in-depth even though errex is
/// self-hosted: the zero-knowledge promise is that we never hold readable user
/// content.
///
/// 9.x SDK data classes are mutable, so this mutates [event] in place and
/// returns it — the idiomatic `beforeSend` pattern (`copyWith` is deprecated).
/// Every content-bearing field is neutralized with a redacted/empty value,
/// never left untouched.
///
/// Coverage is every field the app or SDK can populate with user-controlled
/// paths/source: message, breadcrumbs (message + data), exceptions (value +
/// stack trace), the crashing isolate's thread stack traces, transaction,
/// culprit, serverName, extra, and the whole HTTP request. The remaining 9.x
/// content-capable fields are intentionally NOT scrubbed because they cannot
/// carry user source/project paths: structured `contexts` and `debugMeta` are
/// device/OS/binary metadata; `user` and `request.response` are not
/// auto-populated because `sendDefaultPii = false`; `tags`/`release`/
/// `environment` are app constants we control. Revisit this list if the SDK
/// adds a new content field, or if we start populating tags/contexts with
/// project data.
SentryEvent? scrubCrashEvent(SentryEvent event) {
  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(_redact(message.formatted));
  }

  for (final b in event.breadcrumbs ?? const <Breadcrumb>[]) {
    b.message = _redactNullable(b.message);
    final data = b.data;
    if (data != null) {
      b.data = Map<String, dynamic>.from(_redactDeep(data) as Map);
    }
  }

  for (final e in event.exceptions ?? const <SentryException>[]) {
    e.value = _redactNullable(e.value);
    final st = e.stackTrace;
    if (st != null) e.stackTrace = _scrubStackTrace(st);
  }

  // The crashing isolate is attached as a thread BEFORE beforeSend runs; its
  // stacktrace carries the same absPath/source content as exceptions, so it
  // must be scrubbed identically.
  for (final t in event.threads ?? const <SentryThread>[]) {
    final st = t.stacktrace;
    if (st != null) t.stacktrace = _scrubStackTrace(st);
  }

  event.transaction = _redactNullable(event.transaction);
  event.culprit = _redactNullable(event.culprit);
  if (event.serverName != null) event.serverName = '<redacted-host>';

  // ignore: deprecated_member_use
  final extra = event.extra;
  if (extra != null) {
    // ignore: deprecated_member_use
    event.extra = Map<String, dynamic>.from(_redactDeep(extra) as Map);
  }

  // Drop any HTTP request context wholesale — url/query/headers/cookies/body
  // are all potential content; an empty request serializes to nothing.
  if (event.request != null) event.request = SentryRequest();

  return event;
}

Future<void> initCrashReporting({
  required bool enabled,
  required String dsn,
  required Future<void> Function() runApp,
}) async {
  if (!enabled || dsn.isEmpty) {
    await runApp();
    return;
  }
  await SentryFlutter.init((options) {
    options.dsn = dsn;
    options.sendDefaultPii = false;
    options.attachScreenshot = false;
    // attachViewHierarchy is @experimental and defaults to false; no explicit
    // set needed.
    options.beforeSend = (event, hint) => scrubCrashEvent(event);
  }, appRunner: runApp);
}
