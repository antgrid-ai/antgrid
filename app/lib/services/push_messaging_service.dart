import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:push/push.dart';

import '../models/ab_message.dart';
import '../models/agent_hello.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import 'push_identity.dart';

class PushMessagingService {
  final PushIdentity _pushIdentity;
  final FlutterLocalNotificationsPlugin _localNotifications;
  PushMessagingService({
    PushIdentity? pushIdentity,
    FlutterLocalNotificationsPlugin? localNotifications,
  }) : _pushIdentity = pushIdentity ?? PushIdentity.secure(),
       _localNotifications =
           localNotifications ?? FlutterLocalNotificationsPlugin();

  /// The FCM token last obtained. Held so a session that becomes warm AFTER
  /// startup ([registerNewSessions]) can be registered without a fresh
  /// getToken round-trip.
  String? _token;

  /// The push provider for [_token]: 'apns' on iOS, 'fcm' on Android. Derived
  /// from the platform rather than assigned when a token arrives, because the
  /// token read can time out (see [init]) — leaving a default of 'fcm' to be
  /// reported by a later clearToken on an iOS device.
  String _provider = defaultTargetPlatform == TargetPlatform.iOS
      ? 'apns'
      : 'fcm';

  /// projectId → the agent handshake its registration went out on. Keyed on
  /// the handshake, not just the project: the agent re-sends `agent:hello` on
  /// every connect, and one that has since dropped this phone's row (the
  /// account left it out of a lease) recreates it on readmission without a
  /// token, so each new handshake must be told again. Reset whenever the token
  /// changes so a token refresh re-registers every session.
  final Map<String, AgentHello> _registered = <String, AgentHello>{};

  /// pubkey of the identity [_registered] was populated under. Sign-out
  /// regenerates the push keypair but reuses the same long-lived service and
  /// device token, so a token-only reset would miss it — reset on pubkey change
  /// too, or a re-signed-in user's agents keep the stale pubkey and can't push.
  String? _registeredPubkey;

  /// Sessions with a handshake listener attached, so repeated registration
  /// passes over one session don't stack listeners. An [Expando] so a closed
  /// session is not kept alive by this set.
  Expando<bool> _watched = Expando<bool>();

  /// The identity the last [registerToken] ran under, read by handshake
  /// listeners at fire time so a reconnect after an identity change registers
  /// the current key.
  PushIdentity? _identity;

  /// Set by [clearToken], cleared only by [resumeAfterSignIn]. While set, no
  /// path tells an agent the token: sign-out evicts sessions one at a time and
  /// every eviction re-runs [registerNewSessions] on the ones still open, and a
  /// token refresh can land at any time — either would undo the empty-token
  /// clear. [_token] is deliberately kept: the platform hands it over only at
  /// startup or on refresh, so the next sign-in has no other way to get it.
  bool _signedOut = false;

  /// `push` hands back an unsubscribe callback rather than a StreamSubscription.
  VoidCallback? _unsubscribeToken;

  /// Request the notification permission, obtain the push token, register it on
  /// all current relay-paired sessions, and re-register on refresh. Called once
  /// at startup on Android and iOS — `push` unifies both, so there is no
  /// separate APNs path any more. On-device only; no-ops cleanly under test.
  ///
  /// [sessions] is a live view of the currently warm sessions, re-read on each
  /// registration pass so a session that becomes warm after startup is caught
  /// (drive that via [registerNewSessions] on registry changes).
  Future<void> init({
    required Iterable<ProjectSession> Function() sessions,
  }) async {
    await _requestAndroidNotificationPermission();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Drives the APNs authorization prompt. Deliberately NOT called on
      // Android: PushPlugin.onRequestPushNotificationsPermission only resolves
      // its callback via onRequestPermissionsResult, so when notifications are
      // already disabled AND (the SDK is < 33 or no activity is attached) it
      // never fires and this await never returns, stranding init(). The real
      // Android grant is the flutter_local_notifications call above.
      await Push.instance.requestPermission();
    }
    // Subscribe BEFORE reading the token: on iOS the token usually arrives
    // after startup (push registers for remote notifications itself in
    // didFinishLaunchingWithOptions), and a token landing between the read and
    // the subscribe would otherwise be missed. setTokenAndRegister dedups, so
    // both paths firing is harmless.
    _unsubscribeToken = Push.instance.addOnNewToken((t) {
      // The callback is sync and can't propagate a rejection; the registration
      // is async, so an uncaught throw here would be an unhandled rejection.
      // Swallow (log) — a failed re-register must never crash.
      unawaited(
        setTokenAndRegister(t, sessions(), provider: _provider).catchError((
          Object e,
        ) {
          AbLog.error(
            'PushMessagingService',
            'token-refresh register failed',
            fields: {'error': '$e'},
          );
        }),
      );
    });
    // Bounded: on iOS `push`'s getToken waits on a DispatchGroup that
    // didFailToRegisterForRemoteNotificationsWithError never leaves
    // (PushHostHandlers.swift), so a registration failure hangs here forever.
    // The addOnNewToken subscription above still catches a late token.
    //
    // Deliberately no onTimeout callback: `Push.instance.token` is declared
    // Future<String?> but hands back the pigeon Future<String>, so at runtime
    // T is String and a `() => null` callback fails its subtype check —
    // init() throws and no token is ever registered. The analyzer only sees
    // the nullable static type, so this is invisible to `flutter analyze`.
    String? token;
    try {
      token = await Push.instance.token.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // Worth logging: with no token every later registerNewSessions returns
      // early, so the whole push path goes quiet with nothing to show for it.
      AbLog.warn('PushMessagingService', 'token read timed out after 30s');
      token = null;
    }
    if (token != null) {
      await setTokenAndRegister(token, sessions(), provider: _provider);
    }
  }

  /// Request the Android POST_NOTIFICATIONS runtime permission. No-op / safe on
  /// non-Android and where the plugin impl doesn't resolve (tests, web).
  Future<void> _requestAndroidNotificationPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final android = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
    } catch (e) {
      AbLog.error(
        'PushMessagingService',
        'POST_NOTIFICATIONS request failed',
        fields: {'error': '$e'},
      );
    }
  }

  /// What a token arriving from the platform (startup read or refresh) does.
  @visibleForTesting
  Future<void> setTokenAndRegister(
    String token,
    Iterable<ProjectSession> sessions, {
    String provider = 'fcm',
  }) async {
    if (token != _token || provider != _provider) {
      _token = token;
      _provider = provider;
      _registered.clear();
    }
    await registerToken(
      token: token,
      provider: provider,
      pushIdentity: _pushIdentity,
      sessions: sessions,
    );
  }

  /// Register the current FCM token on any warm sessions not yet told about it.
  /// Called when the warm-project set changes so a relay session that pairs
  /// AFTER startup still gets the token. No-op until [init] has a token, and
  /// while signed out.
  Future<void> registerNewSessions(Iterable<ProjectSession> sessions) async {
    final token = _token;
    if (token == null) return;
    await registerToken(
      token: token,
      provider: _provider,
      pushIdentity: _pushIdentity,
      sessions: sessions,
    );
  }

  Future<void> registerToken({
    required String token,
    String provider = 'fcm',
    required PushIdentity pushIdentity,
    required Iterable<ProjectSession> sessions,
  }) async {
    // Record the token/provider so a deferred (register-when-ready) send reads
    // the CURRENT pair at fire time — a refresh mid-handshake then registers the
    // new token, not the one captured when the listener was attached. Callers
    // (setTokenAndRegister / registerNewSessions) already keep this in lockstep.
    _token = token;
    _provider = provider;
    if (_signedOut) return;
    _identity = pushIdentity;
    final watched = _watched;
    final kp = await pushIdentity.ensureKeypair();
    // A sign-out across an await here already sent the empty-token clear.
    // Checked before the pubkey bookkeeping too: a pass outliving a sign-out
    // and re-sign-in holds the discarded key, and must not repoint
    // [_registeredPubkey] at it under the new identity's registrations.
    if (!identical(watched, _watched)) return;
    if (kp.pubkeyB64 != _registeredPubkey) {
      _registered.clear();
      _registeredPubkey = kp.pubkeyB64;
    }
    for (final s in sessions) {
      if (!identical(watched, _watched)) return;
      // Push is a relay-only concern: a local agent shares the machine, so
      // there is nothing to relay a blob through. Only register relay sessions.
      if (s.mode != ProjectSessionMode.relay) continue;
      _watchHandshakes(s);
      // A send() on a transport that hasn't finished its session handshake is
      // silently dropped; the listener above registers once agentHello lands.
      final hello = s.status.value.agentHello;
      if (hello == null) continue;
      await _sendRegister(
        s,
        hello: hello,
        token: token,
        pushPubkeyB64: kp.pubkeyB64,
      );
    }
  }

  Future<void> _sendRegister(
    ProjectSession s, {
    required AgentHello hello,
    required String token,
    required String pushPubkeyB64,
  }) async {
    // Already told this handshake about this token.
    if (identical(_registered[s.projectId], hello)) return;
    _registered[s.projectId] = hello;
    try {
      await s.send(
        createAbMessage('push:register', {
          'pushToken': token,
          'provider': _provider,
          'pushPubkey': pushPubkeyB64,
        }),
      );
    } catch (e) {
      // One closed/failing transport must not abort the rest of the sessions.
      // Un-mark so a later registerNewSessions pass retries this one.
      if (identical(_registered[s.projectId], hello)) {
        _registered.remove(s.projectId);
      }
      AbLog.error(
        'PushMessagingService',
        'push:register failed',
        fields: {'projectId': s.projectId, 'error': '$e'},
      );
    }
  }

  /// Registers [s] on each agent handshake (every `agent:hello`) for the
  /// session's lifetime: the warm-set trigger never re-fires for a session that
  /// merely connects or reconnects. Reads [_token] and [_identity] at fire time
  /// so a refresh between handshakes sends the current pair; a sign-out swaps
  /// [_watched], which retires every listener attached before it.
  void _watchHandshakes(ProjectSession s) {
    if (_watched[s] == true) return;
    final watched = _watched;
    watched[s] = true;
    void onStatus() {
      if (!identical(watched, _watched)) {
        s.status.removeListener(onStatus);
        return;
      }
      final hello = s.status.value.agentHello;
      final token = _token;
      final identity = _identity;
      if (hello == null || token == null || identity == null) return;
      if (identical(_registered[s.projectId], hello)) return;
      unawaited(() async {
        final kp = await identity.ensureKeypair();
        // A sign-out during that await already sent the empty-token clear;
        // registering now would undo it.
        if (!identical(watched, _watched)) return;
        await _sendRegister(
          s,
          hello: hello,
          token: token,
          pushPubkeyB64: kp.pubkeyB64,
        );
      }());
    }

    s.status.addListener(onStatus);
  }

  /// On sign-out: tell each paired agent to stop pushing (empty token clears
  /// it), and register nothing more until [resumeAfterSignIn]. Clears the local
  /// registered-set so the re-register after sign-in re-sends.
  Future<void> clearToken({required Iterable<ProjectSession> sessions}) async {
    _signedOut = true;
    _registered.clear();
    _registeredPubkey = null;
    // Retire every handshake listener: a session that outlives sign-out must
    // not re-register, and a re-sign-in attaches fresh ones.
    _watched = Expando<bool>();
    _identity = null;
    for (final s in sessions) {
      if (s.mode != ProjectSessionMode.relay) continue;
      try {
        await s.send(
          createAbMessage('push:register', {
            'pushToken': '',
            'provider': _provider,
            'pushPubkey': '',
          }),
        );
      } catch (e) {
        // One failing transport must not block clearing the rest.
        AbLog.error(
          'PushMessagingService',
          'push:register clear failed',
          fields: {'projectId': s.projectId, 'error': '$e'},
        );
      }
    }
  }

  /// On sign-in: lift [clearToken]'s hold and register the kept token on the
  /// warm [sessions]. Safe to call while never signed out — it is then just a
  /// [registerNewSessions] pass, which dedups.
  Future<void> resumeAfterSignIn(Iterable<ProjectSession> sessions) {
    _signedOut = false;
    return registerNewSessions(sessions);
  }

  void dispose() {
    _unsubscribeToken?.call();
    _unsubscribeToken = null;
  }
}
