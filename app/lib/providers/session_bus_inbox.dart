import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
import '../project/project_session.dart';
import 'providers.dart';

/// How long a thread read waits before giving up. The bridge answers a thread
/// out of SQLite with no git spawn behind it, so this bounds a dropped frame
/// rather than a slow answer.
const _kThreadReadTimeout = Duration(seconds: 15);

const _kInboxRequest = 'session-bus:inbox';
const _kInboxResult = 'session-bus:inbox:result';
const _kThreadRequest = 'session-bus:thread';
const _kThreadResult = 'session-bus:thread:result';
const _kArrivedPush = 'session-bus:arrived';

const _uuid = Uuid();

/// The project stream, narrowed to what a session-bus read needs of it.
///
/// The bus's state is machine-level but its transport never moved: every read
/// leaves and every answer arrives through the owning project's core, on the
/// same control tier `handler:status` rides. This interface exists so the
/// providers below can be exercised without standing up a transport — a
/// [ProjectSession] is the only implementation the app ships.
abstract class SessionBusChannel {
  /// Inbound status-tier frames for this project, as raw envelopes.
  Stream<Map<String, dynamic>> get frames;

  Future<void> send(Map<String, dynamic> message);

  /// Register [run] as the re-drive for [key]: it fires now if the transport is
  /// established and again on every re-establishment.
  Future<void> hydrate(String key, Future<void> Function() run);

  void unhydrate(String key);
}

class _ProjectSessionBusChannel implements SessionBusChannel {
  _ProjectSessionBusChannel(this._session);

  final ProjectSession _session;

  @override
  Stream<Map<String, dynamic>> get frames => _session.statusStream;

  @override
  Future<void> send(Map<String, dynamic> message) => _session.send(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) =>
      _session.hydrate(key, run);

  @override
  void unhydrate(String key) => _session.unhydrate(key);

  // sessionBusChannelProvider builds a fresh instance on every rebuild (a
  // reselected registration, a ProjectSession re-yielded by its own provider);
  // with no value equality that reads as a NEW channel to every family entry
  // watching it, invalidating each sessionInboxProvider and zeroing its badge
  // on a rebuild the wrapped session did not actually change under.
  @override
  bool operator ==(Object other) =>
      other is _ProjectSessionBusChannel && other._session == _session;

  @override
  int get hashCode => _session.hashCode;
}

/// The focused project's bus channel, or null while no project is focused or
/// its session is still resolving.
///
/// Sourced via [focusedSessionOrNull] rather than a `ref.watch` of a throwing
/// service façade, for the reason that function documents.
final sessionBusChannelProvider = Provider<SessionBusChannel?>((ref) {
  final session = focusedSessionOrNull(ref);
  if (session == null) return null;
  return _ProjectSessionBusChannel(session);
}, name: 'sessionBusChannel');

// --- Wire view models -------------------------------------------------------

/// A bus peer's address. Mirrors `SessionMemberKeySchema` in `protocol.ts`.
@immutable
class SessionBusAddress {
  const SessionBusAddress({
    required this.machineId,
    required this.projectId,
    required this.sessionId,
  });

  final String machineId;
  final String projectId;
  final String sessionId;

  static SessionBusAddress? fromJson(Object? json) {
    if (json is! Map) return null;
    final machineId = json['machineId'];
    final projectId = json['projectId'];
    final sessionId = json['sessionId'];
    if (machineId is! String || projectId is! String || sessionId is! String) {
      return null;
    }
    return SessionBusAddress(
      machineId: machineId,
      projectId: projectId,
      sessionId: sessionId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionBusAddress &&
      other.machineId == machineId &&
      other.projectId == projectId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(machineId, projectId, sessionId);
}

/// A refusal from the bus, as all three result frames carry it.
///
/// Thrown by the thread read and held on [SessionInboxState] rather than
/// collapsed into an empty answer: "this terminal names no session" and
/// "nobody has written to you" are different facts, and an inbox that renders
/// the first as the second is the one wrong thing it can say.
@immutable
class SessionBusRefusal implements Exception {
  const SessionBusRefusal({required this.message, this.code});

  /// Authored at the point of refusal and safe to render verbatim.
  final String message;

  /// A bare string, never an enum: the bridge's vocabulary can gain a code this
  /// build has not learned, and a reader that dropped the frame over an
  /// unrecognized one would turn a new refusal into silence. Branch on it if
  /// there is something better to do; render [message] regardless.
  final String? code;

  @override
  String toString() => message;

  @override
  bool operator ==(Object other) =>
      other is SessionBusRefusal &&
      other.message == message &&
      other.code == code;

  @override
  int get hashCode => Object.hash(message, code);
}

SessionBusRefusal? _refusalOf(Map<String, dynamic> json) {
  final error = json['error'];
  if (error is! String) return null;
  final code = json['code'];
  return SessionBusRefusal(
    message: error,
    code: code is String ? code : null,
  );
}

/// A file carried alongside a post. The bytes are not here — an artifact is
/// fetched on demand, and this is what a row renders to decide whether to.
@immutable
class SessionBusArtifact {
  const SessionBusArtifact({
    required this.artifactId,
    required this.name,
    required this.mediaType,
    required this.bytes,
    required this.sha256,
    required this.summary,
  });

  final String artifactId;
  final String name;
  final String mediaType;
  final int bytes;
  final String sha256;
  final String summary;

  static SessionBusArtifact? fromJson(Object? json) {
    if (json is! Map) return null;
    final artifactId = json['artifactId'];
    final name = json['name'];
    if (artifactId is! String || name is! String) return null;
    final bytes = json['bytes'];
    return SessionBusArtifact(
      artifactId: artifactId,
      name: name,
      mediaType: json['mediaType'] is String
          ? json['mediaType'] as String
          : 'application/octet-stream',
      bytes: bytes is num ? bytes.toInt() : 0,
      sha256: json['sha256'] is String ? json['sha256'] as String : '',
      summary: json['summary'] is String ? json['summary'] as String : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionBusArtifact &&
      other.artifactId == artifactId &&
      other.name == name &&
      other.mediaType == mediaType &&
      other.bytes == bytes &&
      other.sha256 == sha256 &&
      other.summary == summary;

  @override
  int get hashCode =>
      Object.hash(artifactId, name, mediaType, bytes, sha256, summary);
}

/// One unread post, rendered whole: the read returns everything a row shows so
/// a mailbox needs no second call per line.
@immutable
class SessionBusInboxPost {
  const SessionBusInboxPost({
    required this.messageId,
    required this.threadId,
    required this.contextId,
    required this.at,
    required this.from,
    required this.summary,
    required this.text,
    this.unexpected,
    this.artifacts = const <SessionBusArtifact>[],
  });

  final String messageId;

  /// Null for a post that opened no thread. A row offering "open thread" gates
  /// on this.
  final String? threadId;

  final String contextId;

  /// Epoch milliseconds, as every timestamp on this wire is.
  final int at;

  final SessionBusAddress from;
  final String summary;
  final List<String> text;

  /// What the sender flagged as not fitting the thread it was answering.
  final String? unexpected;

  final List<SessionBusArtifact> artifacts;

  static SessionBusInboxPost? fromJson(Object? json) {
    if (json is! Map) return null;
    final messageId = json['messageId'];
    final contextId = json['contextId'];
    final from = SessionBusAddress.fromJson(json['from']);
    if (messageId is! String || contextId is! String || from == null) {
      return null;
    }
    final at = json['at'];
    final threadId = json['threadId'];
    return SessionBusInboxPost(
      messageId: messageId,
      threadId: threadId is String ? threadId : null,
      contextId: contextId,
      at: at is num ? at.toInt() : 0,
      from: from,
      summary: json['summary'] is String ? json['summary'] as String : '',
      text: _stringList(json['text']),
      unexpected: json['unexpected'] is String
          ? json['unexpected'] as String
          : null,
      artifacts: _mapList(json['artifacts'], SessionBusArtifact.fromJson),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionBusInboxPost &&
      other.messageId == messageId &&
      other.threadId == threadId &&
      other.contextId == contextId &&
      other.at == at &&
      other.from == from &&
      other.summary == summary &&
      listEquals(other.text, text) &&
      other.unexpected == unexpected &&
      listEquals(other.artifacts, artifacts);

  @override
  int get hashCode => Object.hash(
    messageId,
    threadId,
    contextId,
    at,
    from,
    summary,
    Object.hashAll(text),
    unexpected,
    Object.hashAll(artifacts),
  );
}

/// One line of a thread, in either direction.
@immutable
class SessionBusThreadEntry {
  const SessionBusThreadEntry({
    required this.outbound,
    required this.at,
    required this.peer,
    required this.summary,
    required this.text,
    this.deliveredAt,
  });

  /// True for a message this session sent, false for one it received.
  final bool outbound;

  /// Epoch milliseconds.
  final int at;

  final SessionBusAddress peer;
  final String summary;
  final List<String> text;

  /// Outbound entries only, and its absence means "no receipt yet" rather than
  /// a failure: a receipt is fire-and-forget and an unacked message is never
  /// retried. This read is the only surface it is visible on.
  final int? deliveredAt;

  static SessionBusThreadEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final direction = json['direction'];
    final peer = SessionBusAddress.fromJson(json['peer']);
    if (direction is! String || peer == null) return null;
    final at = json['at'];
    final deliveredAt = json['deliveredAt'];
    return SessionBusThreadEntry(
      outbound: direction == 'out',
      at: at is num ? at.toInt() : 0,
      peer: peer,
      summary: json['summary'] is String ? json['summary'] as String : '',
      text: _stringList(json['text']),
      deliveredAt: deliveredAt is num ? deliveredAt.toInt() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionBusThreadEntry &&
      other.outbound == outbound &&
      other.at == at &&
      other.peer == peer &&
      other.summary == summary &&
      listEquals(other.text, text) &&
      other.deliveredAt == deliveredAt;

  @override
  int get hashCode => Object.hash(
    outbound,
    at,
    peer,
    summary,
    Object.hashAll(text),
    deliveredAt,
  );
}

/// One thread as the thread view renders it.
@immutable
class SessionBusThread {
  const SessionBusThread({
    required this.threadId,
    this.contextId,
    this.entries = const <SessionBusThreadEntry>[],
    this.refusal,
  });

  final String threadId;

  /// The context this thread belongs to, absent only when the bridge answered
  /// without one.
  final String? contextId;

  /// Oldest first, as the bridge orders them.
  final List<SessionBusThreadEntry> entries;

  /// Why there are no entries. A value, not a thrown error: `defaultRetry`
  /// only recognizes `ProviderException`/`Error`, so a thrown
  /// [SessionBusRefusal] (and a thrown [TimeoutException]) is retried instead
  /// of surfacing, and every retry sits in `AsyncLoading` with
  /// `isReloading: true` — which `.when` renders as the loading arm, not the
  /// error arm, for as long as the retries run. Answering the refusal as data
  /// is what lets the reader ever see it.
  final SessionBusRefusal? refusal;

  @override
  bool operator ==(Object other) =>
      other is SessionBusThread &&
      other.threadId == threadId &&
      other.contextId == contextId &&
      other.refusal == refusal &&
      listEquals(other.entries, entries);

  @override
  int get hashCode =>
      Object.hash(threadId, contextId, refusal, Object.hashAll(entries));
}

List<String> _stringList(Object? json) {
  if (json is! List) return const <String>[];
  return <String>[
    for (final line in json)
      if (line is String) line,
  ];
}

List<T> _mapList<T>(Object? json, T? Function(Object?) decode) {
  if (json is! List) return <T>[];
  final out = <T>[];
  for (final item in json) {
    final decoded = decode(item);
    if (decoded != null) out.add(decoded);
  }
  return out;
}

// --- Inbox ------------------------------------------------------------------

/// One session's mailbox as its surfaces see it.
@immutable
class SessionInboxState {
  const SessionInboxState({
    this.dropped = 0,
    this.posts = const <SessionBusInboxPost>[],
    this.loading = false,
    this.refusal,
    this.generation = 0,
  });

  /// Posts this session will never see, zero included: a reader that cannot
  /// tell an empty mailbox from an emptied one has been told the wrong thing,
  /// not merely told less.
  final int dropped;

  /// The last read's contents. The arrival push carries none, so a surface
  /// showing the list watches [generation] and calls
  /// [SessionInboxController.refresh] rather than waiting to be handed them.
  final List<SessionBusInboxPost> posts;

  final bool loading;

  /// Set when the bridge refused the read. What was already read is left
  /// standing: a transient refusal must not empty a sheet that was right a
  /// moment ago.
  final SessionBusRefusal? refusal;

  /// Bumped by every arrival push. A surface holding rendered content listens
  /// for it to re-read; nothing reads meaning into the number itself.
  final int generation;

  SessionInboxState copyWith({
    int? dropped,
    List<SessionBusInboxPost>? posts,
    bool? loading,
    SessionBusRefusal? refusal,
    bool clearRefusal = false,
    int? generation,
  }) {
    assert(
      !(clearRefusal && refusal != null),
      'clearRefusal with a refusal says two things at once.',
    );
    return SessionInboxState(
      dropped: dropped ?? this.dropped,
      posts: posts ?? this.posts,
      loading: loading ?? this.loading,
      refusal: clearRefusal ? null : (refusal ?? this.refusal),
      generation: generation ?? this.generation,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionInboxState &&
      other.dropped == dropped &&
      other.loading == loading &&
      other.refusal == refusal &&
      other.generation == generation &&
      listEquals(other.posts, posts);

  @override
  int get hashCode => Object.hash(
    dropped,
    loading,
    refusal,
    generation,
    Object.hashAll(posts),
  );
}

class SessionInboxController extends Notifier<SessionInboxState> {
  SessionInboxController(this.sessionId);

  final String sessionId;

  SessionBusChannel? _channel;

  /// The read this controller is still waiting on. The result frame carries no
  /// session id — every session on this project answers on one stream — so the
  /// request id is the only correlation there is, and keeping just the latest
  /// makes a late reply to a superseded read fall on the floor where it
  /// belongs.
  String? _pendingRequestId;

  String get _hydratorKey => '$_kInboxRequest:$sessionId';

  @override
  SessionInboxState build() {
    final channel = ref.watch(sessionBusChannelProvider);
    _channel = channel;
    _pendingRequestId = null;
    // A rebuild is not necessarily a new mailbox — `sessionBusChannelProvider`
    // can legitimately yield a fresh-but-equivalent channel (a reconnect that
    // re-wrapped the same session). Carrying `dropped` forward keeps a sheet
    // that was right a moment ago from blanking for the width of the re-read.
    final previous = stateOrNull;
    if (channel == null) return const SessionInboxState();

    final sub = channel.frames.listen(_onFrame);
    ref.onDispose(sub.cancel);
    // Registered, not sent once: the mailbox is idempotent view-state, and the
    // bridge re-announces nothing on handshake. A reconnect that did not
    // re-read would leave an open sheet stale at whatever the dropped socket
    // last carried.
    ref.onDispose(() => channel.unhydrate(_hydratorKey));
    unawaited(channel.hydrate(_hydratorKey, _read));
    return SessionInboxState(dropped: previous?.dropped ?? 0, loading: true);
  }

  /// Re-reads the mailbox. A peek: it never marks anything read, because the
  /// marking read belongs to the agent and a human opening the sheet must not
  /// spend a post the agent has not seen.
  Future<void> refresh() {
    state = state.copyWith(loading: true);
    return _read();
  }

  Future<void> _read() {
    final channel = _channel;
    if (channel == null) return Future<void>.value();
    final requestId = _uuid.v4();
    _pendingRequestId = requestId;
    return channel.send(
      createAbMessage(_kInboxRequest, {
        'requestId': requestId,
        'sessionId': sessionId,
      }),
    );
  }

  void _onFrame(Map<String, dynamic> json) {
    switch (json['type']) {
      case _kArrivedPush:
        if (json['sessionId'] != sessionId) return;
        _applyArrival();
      case _kInboxResult:
        if (json['requestId'] != _pendingRequestId) return;
        _pendingRequestId = null;
        _applyResult(json);
    }
  }

  /// The push carries WHOSE mailbox grew and nothing else, so the contents are
  /// re-read here rather than carried on the frame. This is the ONLY thing that
  /// moves a mailbox between reads — nothing announces a peer's mail, so a
  /// surface polling state alone would render whatever the connect-time read
  /// returned for as long as the socket lived.
  void _applyArrival() {
    state = state.copyWith(
      // A mailbox that just grew is a mailbox that exists, so whatever refused
      // the last read no longer holds.
      clearRefusal: true,
      generation: state.generation + 1,
    );
    unawaited(_read());
  }

  void _applyResult(Map<String, dynamic> json) {
    final refusal = _refusalOf(json);
    if (refusal != null) {
      state = state.copyWith(loading: false, refusal: refusal);
      return;
    }
    final posts = _mapList(json['posts'], SessionBusInboxPost.fromJson);
    final dropped = json['dropped'];
    state = SessionInboxState(
      dropped: dropped is num ? dropped.toInt() : 0,
      posts: posts,
      generation: state.generation,
    );
  }
}

/// One session's mailbox, keyed by session id.
///
/// Read against the FOCUSED project's bridge, like every other per-session
/// provider sourced from [focusedSessionOrNull]. A surface that can show a
/// session belonging to some other project must not read it there: that
/// bridge holds no such session and refuses the read. Widening this means
/// keying on the entry id as well, the way `sessionWorkStatusProvider` does.
///
/// autoDispose is load-bearing: each entry holds a subscription to the project
/// stream and a hydrator registration on the transport, and a keep-alive family
/// would accumulate one of each per session id for the life of the app run —
/// re-reading, on every reconnect, mailboxes nothing is showing.
final sessionInboxProvider = NotifierProvider.autoDispose
    .family<SessionInboxController, SessionInboxState, String>(
      SessionInboxController.new,
      name: 'sessionInbox',
    );

// --- Thread -----------------------------------------------------------------

/// Which thread, of whose mailbox.
typedef SessionBusThreadKey = ({String sessionId, String threadId});

/// One thread's entries, read on demand.
///
/// Answers with [SessionBusThread.refusal] set when the bridge refuses (an
/// unknown thread is `UNKNOWN_PEER`, not an empty one) and again, synthesized,
/// when no answer arrives in time — see [SessionBusThread.refusal] for why
/// this is a value rather than a thrown error. Re-reads itself when the
/// session's mailbox grows, so a reply landing in an open thread appears
/// without a poll; `ref.invalidate` forces one otherwise.
final sessionBusThreadProvider = FutureProvider.autoDispose
    .family<SessionBusThread, SessionBusThreadKey>((ref, key) async {
      // The arrival push is the only signal a thread has a new line in it.
      ref.watch(
        sessionInboxProvider(key.sessionId).select((s) => s.generation),
      );
      final channel = ref.watch(sessionBusChannelProvider);
      if (channel == null) return SessionBusThread(threadId: key.threadId);

      final requestId = _uuid.v4();
      final answer = Completer<SessionBusThread>();
      final sub = channel.frames.listen((json) {
        if (json['type'] != _kThreadResult) return;
        if (json['requestId'] != requestId) return;
        if (answer.isCompleted) return;
        final refusal = _refusalOf(json);
        final threadId = json['threadId'];
        final contextId = json['contextId'];
        answer.complete(
          SessionBusThread(
            // Echoed even on a refusal, so it is the bridge's word for which
            // thread this is rather than the caller's.
            threadId: threadId is String ? threadId : key.threadId,
            contextId: contextId is String ? contextId : null,
            entries: refusal == null
                ? _mapList(json['entries'], SessionBusThreadEntry.fromJson)
                : const <SessionBusThreadEntry>[],
            refusal: refusal,
          ),
        );
      });
      try {
        await channel.send(
          createAbMessage(_kThreadRequest, {
            'requestId': requestId,
            'sessionId': key.sessionId,
            'threadId': key.threadId,
          }),
        );
        return await answer.future.timeout(_kThreadReadTimeout);
      } on TimeoutException {
        return SessionBusThread(
          threadId: key.threadId,
          refusal: const SessionBusRefusal(
            message: 'The bridge did not answer in time.',
          ),
        );
      } finally {
        await sub.cancel();
      }
    }, name: 'sessionBusThread');
