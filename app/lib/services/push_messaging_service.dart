import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/ab_message.dart';
import '../project/project_session.dart';
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

  /// projectIds already registered with the current [_token]. Reset whenever
  /// the token changes so a token refresh re-registers every session. Lets
  /// [registerNewSessions] skip sessions already told about this token.
  final Set<String> _registered = <String>{};

  /// projectIds with a pending "register once connected" status listener. A
  /// session can enter the warm set before its transport finishes handshaking;
  /// a `push:register` sent then is silently dropped and the registry trigger
  /// never re-fires on connect. We defer via a one-shot listener and guard here
  /// so repeated passes over a still-connecting session don't stack listeners.
  final Set<String> _awaitingReady = <String>{};

  StreamSubscription<String>? _tokenRefreshSub;

  /// Request the Android runtime notification permission (POST_NOTIFICATIONS,
  /// required on API 33+), obtain the FCM token, register it on all current
  /// relay-paired sessions, and re-register on refresh. Called once at startup
  /// after Firebase.initializeApp. On-device only; no-ops cleanly under test.
  ///
  /// [sessions] is a live view of the currently warm sessions, re-read on each
  /// registration pass so a session that becomes warm after startup is caught
  /// (drive that via [registerNewSessions] on registry changes).
  Future<void> init({
    required Iterable<ProjectSession> Function() sessions,
  }) async {
    await _requestAndroidNotificationPermission();
    // FirebaseMessaging.requestPermission is a no-op on Android for the runtime
    // POST_NOTIFICATIONS grant (it drives APNs on iOS); the real Android ask is
    // done above. Still call it so iOS/other providers keep working if this
    // service is ever reused there.
    await FirebaseMessaging.instance.requestPermission();
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _setTokenAndRegister(token, sessions());
    }
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      // The listener callback is sync and can't propagate a rejection; the
      // registration is async, so an uncaught throw here would be an unhandled
      // rejection. Swallow (log) — a failed re-register must never crash.
      unawaited(
        _setTokenAndRegister(t, sessions()).catchError((Object e) {
          debugPrint('PushMessagingService token-refresh register failed: $e');
        }),
      );
    });
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
      debugPrint('POST_NOTIFICATIONS request failed: $e');
    }
  }

  Future<void> _setTokenAndRegister(
    String token,
    Iterable<ProjectSession> sessions,
  ) async {
    if (token != _token) {
      _token = token;
      _registered.clear();
    }
    await registerToken(
      token: token,
      pushIdentity: _pushIdentity,
      sessions: sessions,
    );
  }

  /// Register the current FCM token on any warm sessions not yet told about it.
  /// Called when the warm-project set changes so a relay session that pairs
  /// AFTER startup still gets the token. No-op until [init] has a token.
  Future<void> registerNewSessions(Iterable<ProjectSession> sessions) async {
    final token = _token;
    if (token == null) return;
    await registerToken(
      token: token,
      pushIdentity: _pushIdentity,
      sessions: sessions,
    );
  }

  Future<void> registerToken({
    required String token,
    required PushIdentity pushIdentity,
    required Iterable<ProjectSession> sessions,
  }) async {
    // Record the token so a deferred (register-when-ready) send reads the
    // CURRENT token at fire time — a refresh mid-handshake then registers the
    // new token, not the one captured when the listener was attached. Callers
    // (_setTokenAndRegister / registerNewSessions) already keep this in lockstep.
    _token = token;
    final kp = await pushIdentity.ensureKeypair();
    for (final s in sessions) {
      // Push is a relay-only concern: a local agent shares the machine, so
      // there is nothing to relay a blob through. Only register relay sessions.
      if (s.mode != ProjectSessionMode.relay) continue;
      if (_registered.contains(s.projectId)) continue; // already told this token
      // A send() on a transport that hasn't finished its E2E handshake is
      // silently dropped, and the registry-membership trigger never re-fires
      // for a session that merely transitions from handshaking to connected —
      // registering now would strand the token. Defer until the agent
      // handshakes (agentHello lands), then register exactly once.
      if (s.status.value.agentHello == null) {
        _registerWhenReady(s, pushIdentity);
        continue;
      }
      await _sendRegister(s, token: token, pushPubkeyB64: kp.pubkeyB64);
    }
  }

  Future<void> _sendRegister(
    ProjectSession s, {
    required String token,
    required String pushPubkeyB64,
  }) async {
    if (!_registered.add(s.projectId)) return; // already told this token
    try {
      await s.send(
        createAbMessage('push:register', {
          'pushToken': token,
          'provider': 'fcm',
          'pushPubkey': pushPubkeyB64,
        }),
      );
    } catch (e) {
      // One closed/failing transport must not abort the rest of the sessions.
      // Un-mark so a later registerNewSessions pass retries this one.
      _registered.remove(s.projectId);
      debugPrint('push:register failed for ${s.projectId}: $e');
    }
  }

  /// Register [s] once its transport finishes handshaking (agentHello lands).
  /// One-shot: the listener removes itself on fire. Reads [_token] at fire time
  /// so a token refresh between scheduling and readiness still sends the current
  /// token; a sign-out clears [_awaitingReady] (and disposes the session), so a
  /// stale listener can't re-register after the user signs out.
  void _registerWhenReady(ProjectSession s, PushIdentity pushIdentity) {
    if (!_awaitingReady.add(s.projectId)) return; // listener already pending
    void onStatus() {
      if (s.status.value.agentHello == null) return; // not connected yet
      s.status.removeListener(onStatus);
      _awaitingReady.remove(s.projectId);
      final token = _token;
      if (token == null || s.mode != ProjectSessionMode.relay) return;
      unawaited(() async {
        final kp = await pushIdentity.ensureKeypair();
        await _sendRegister(s, token: token, pushPubkeyB64: kp.pubkeyB64);
      }());
    }

    s.status.addListener(onStatus);
  }

  /// On sign-out: tell each paired agent to stop pushing (empty token clears
  /// it). Clears the local registered-set so a later re-register re-sends.
  Future<void> clearToken({required Iterable<ProjectSession> sessions}) async {
    _registered.clear();
    // Drop pending "register when ready" listeners too: their sessions are torn
    // down on sign-out, but clearing the guard lets a re-sign-in re-schedule.
    _awaitingReady.clear();
    for (final s in sessions) {
      if (s.mode != ProjectSessionMode.relay) continue;
      try {
        await s.send(
          createAbMessage('push:register', {
            'pushToken': '',
            'provider': 'fcm',
            'pushPubkey': '',
          }),
        );
      } catch (e) {
        // One failing transport must not block clearing the rest.
        debugPrint('push:register clear failed for ${s.projectId}: $e');
      }
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }
}
