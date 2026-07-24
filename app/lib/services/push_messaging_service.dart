import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:push/push.dart';

import '../models/ab_message.dart';
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

  /// projectIds already registered with the current [_token]. Reset whenever
  /// the token changes so a token refresh re-registers every session. Lets
  /// [registerNewSessions] skip sessions already told about this token.
  final Set<String> _registered = <String>{};

  /// pubkey of the identity [_registered] was populated under. Sign-out
  /// regenerates the push keypair but reuses the same long-lived service and
  /// device token, so a token-only reset would miss it — reset on pubkey change
  /// too, or a re-signed-in user's agents keep the stale pubkey and can't push.
  String? _registeredPubkey;

  /// projectIds with a pending "register once connected" status listener. A
  /// session can enter the warm set before its transport finishes handshaking;
  /// a `push:register` sent then is silently dropped and the registry trigger
  /// never re-fires on connect. We defer via a one-shot listener and guard here
  /// so repeated passes over a still-connecting session don't stack listeners.
  final Set<String> _awaitingReady = <String>{};

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
    // the subscribe would otherwise be missed. _setTokenAndRegister dedups, so
    // both paths firing is harmless.
    _unsubscribeToken = Push.instance.addOnNewToken((t) {
      // The callback is sync and can't propagate a rejection; the registration
      // is async, so an uncaught throw here would be an unhandled rejection.
      // Swallow (log) — a failed re-register must never crash.
      unawaited(
        _setTokenAndRegister(t, sessions(), provider: _provider).catchError((
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
      await _setTokenAndRegister(token, sessions(), provider: _provider);
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

  Future<void> _setTokenAndRegister(
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
  /// AFTER startup still gets the token. No-op until [init] has a token.
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
    // (_setTokenAndRegister / registerNewSessions) already keep this in lockstep.
    _token = token;
    _provider = provider;
    final kp = await pushIdentity.ensureKeypair();
    if (kp.pubkeyB64 != _registeredPubkey) {
      _registered.clear();
      _registeredPubkey = kp.pubkeyB64;
    }
    for (final s in sessions) {
      // Push is a relay-only concern: a local agent shares the machine, so
      // there is nothing to relay a blob through. Only register relay sessions.
      if (s.mode != ProjectSessionMode.relay) continue;
      // Already told this token about the project.
      if (_registered.contains(s.projectId)) continue;
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
          'provider': _provider,
          'pushPubkey': pushPubkeyB64,
        }),
      );
    } catch (e) {
      // One closed/failing transport must not abort the rest of the sessions.
      // Un-mark so a later registerNewSessions pass retries this one.
      _registered.remove(s.projectId);
      AbLog.error(
        'PushMessagingService',
        'push:register failed',
        fields: {'projectId': s.projectId, 'error': '$e'},
      );
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
    _registeredPubkey = null;
    // Drop pending "register when ready" listeners too: their sessions are torn
    // down on sign-out, but clearing the guard lets a re-sign-in re-schedule.
    _awaitingReady.clear();
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

  void dispose() {
    _unsubscribeToken?.call();
    _unsubscribeToken = null;
  }
}
