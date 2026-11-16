import 'dart:async';
import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/services.dart' show TextInput, TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AppleLogoPainter;
import '../analytics/events.dart';
import '../demo/demo_identity.dart';
import '../design/ab_carbon.dart';
import '../project/limits.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/demo_mode.dart';
import '../providers/device_revocation.dart';
import '../providers/subscription.dart';
import '../services/auth_service.dart';
import '../storage/last_auth_method_store.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';

/// Declared here rather than under `providers/` so `storage/` stays free of
/// Riverpod: this screen is the only consumer, and tests override it to
/// substitute a store over a fake prefs backend.
final lastAuthMethodStoreProvider = Provider<LastAuthMethodStore>(
  (ref) => LastAuthMethodStore(),
);

/// Offered where App Review requires it beside GitHub and Google (iOS,
/// guideline 4.8), and on macOS so an account made on the iPhone — possibly
/// under a Hide My Email address the user cannot type — is reachable from the
/// Mac without minting a second one.
bool get _offersAppleSignIn =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Apple's own sheet, which needs no browser, runs on iOS only: it needs the
/// applesignin entitlement, and Apple will not put that in the Developer ID
/// profile the macOS build ships under. macOS signs in through the browser as
/// the web client instead.
bool get _appleSheet => defaultTargetPlatform == TargetPlatform.iOS;

/// Sign-in screen.
///
/// Sign-in is optional on desktop — signed-out users land in [AppShell] and
/// can use local-only features. On mobile (iOS/Android) [_AppHome] routes here
/// first; relay pairing requires an account.
///
/// When pushed modally (desktop, explicit "Sign in" action) a close button and
/// "Continue without signing in" are shown. It auto-pops when
/// [currentUserProvider] flips to a non-null user.
///
/// The form is two steps: an address, then whatever that address needs. Which
/// is decided by [LastAuthMethodStore] and nothing else — asking the server
/// what an address uses would hand out an enumeration oracle, so a device that
/// has never watched this address sign in simply falls through to the magic
/// link, which works for every address (approving one creates the account).
///
/// Magic-link is that fallback and the primary method: it drives the web
/// cross-device flow ([AuthService.startMagicLink] / [AuthService.pollStatus])
/// entirely over HTTPS — no browser, no deeplink. GitHub and Google remain as
/// secondary options on the browser+deeplink path (an in-app sheet on iOS, see
/// [AuthService.startOAuth]), and Sign in with Apple ([_offersAppleSignIn]) on
/// Apple's native sheet where [_appleSheet] allows, else on that same browser
/// path.
///
/// There is no password SIGN-UP here. Creating an account with one lands on
/// "check your email" and then needs a second trip back to sign in (the server
/// runs `autoSignIn: false` with `requireEmailVerification`), which is the same
/// mail the link sends and a step longer; and a password set on an address
/// nobody has proven is dropped the moment someone proves it
/// (`purgeUnprovenPasswordCredential`, web). Adding a password to an account is
/// a signed-in action on the web account page, so this screen only ever signs
/// in with one that already exists.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

/// What the screen is DOING. Kept separate from [_Step], which is what the form
/// is asking for: [pending]/[expired]/[bounced] belong to the magic link alone
/// and [verifyEmail]/[resetSent] to the password paths, and folding the two axes
/// into one enum would put the magic link's restore-and-poll invariants (see
/// [_SignInScreenState._restorePendingSignIn]) on states that have nothing to
/// do with it.
enum _Phase {
  form,
  submitting,
  pending,
  expired,
  bounced,
  verifyEmail,
  resetSent,
}

/// How far through the form the user is. [password] is reached from a
/// remembered hint, from step 1's escape link, or from a screen that already
/// knows the address needs one. None of those asks the server anything, which
/// is what keeps the address step from implying whether the account behind it
/// has a password at all.
enum _Step { email, password, signup }

class _SignInScreenState extends ConsumerState<SignInScreen>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 3);

  /// Matches `RESEND_COOLDOWN_SECONDS` in `web/src/ui/auth-memory.ts` so a user
  /// waits the same time whichever surface they started on.
  static const _resendCooldown = Duration(seconds: 45);

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  _Phase _phase = _Phase.form;
  _Step _step = _Step.email;
  String? _error;

  /// Non-error status line (a resend landed, a reset went out). Separate from
  /// [_error] so a success message can never be styled as a failure.
  String? _notice;
  MagicLinkSession? _session;
  Timer? _pollTimer;
  bool _polling = false;
  bool _resending = false;
  DateTime? _pollDeadline;
  DateTime? _pollRetryAt;
  StreamSubscription<String>? _oauthFailureSub;

  /// An in-app OAuth round trip is running under the spinner, so its failures
  /// belong to this screen even though the form is not showing.
  bool _oauthInApp = false;

  /// Bumped every time the user walks away from the flow they were in
  /// ([_backToForm], [_goToStep]). A request that snapshots this and finds it
  /// changed knows its flow was abandoned mid-air. [_pollOnce]'s
  /// `identical(_session, …)` cannot stand in for it on the resend path: the
  /// late resend is precisely what would install the new [_session].
  int _flowGeneration = 0;

  /// Seconds left before the pending screen will send another link. Armed on
  /// every send — including the first, so landing on the pending screen already
  /// starts the clock — and counted down by [_cooldownTimer].
  int _resendSecondsLeft = 0;
  Timer? _cooldownTimer;
  DateTime? _resendDeadline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // OAuth outcomes arrive as a deep link long after the button's future
    // completed (and possibly into a fresh process), so failures reach the
    // screen through this stream, not a call stack.
    _oauthFailureSub = ref
        .read(authServiceProvider)
        .oauthFailures
        .listen(_onOAuthFailure);
    // Never throws (see restorePendingMagicLink), so no catchError needed.
    unawaited(_restorePendingSignIn());
    // `ref.listen` below fires only on CHANGE, so a user ALREADY settled when
    // this screen mounts never reaches it. That is not hypothetical: if
    // `hardSignOut` throws, `performHardSignOut` never reaches its
    // invalidations, yet `handleDeviceRevoked` still raises the revoked notice
    // (it does so in a `finally`) — leaving a live `currentUserProvider` behind
    // the one flag that pins the root to this screen. Nothing else could then
    // retire it.
    //
    // `isLoading`, not just a null check, is what keeps this off the SUCCESSFUL
    // path: there `currentUserProvider` was invalidated, and a rebuilding
    // FutureProvider still reports its previous value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final user = ref.read(currentUserProvider);
      if (!user.isLoading && user.value != null) {
        clearRevokedNotice(ref.container);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(currentUserProvider);
      detached('SignInScreen', 'Resume sign-in polling', _pollOnce);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    _oauthFailureSub?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onOAuthFailure(String message) {
    // A late bounce must not clobber an in-progress magic-link flow — OAuth is
    // only ever started from the form, so only the form shows its failures.
    if (!mounted || (_phase != _Phase.form && !_oauthInApp)) return;
    setState(() => _error = message);
  }

  /// Records [method] as the way [email] signs in, so the next Continue can
  /// route straight there. Fire-and-forget by design: [LastAuthMethodStore]
  /// never throws, and a lost write costs the user exactly one extra tap next
  /// time — never a failed sign-in.
  ///
  /// [store] is for callers recording AFTER an await, where reading it off
  /// [ref] could land on a widget that is already gone.
  void _remember(
    String email,
    AuthMethod method, {
    LastAuthMethodStore? store,
  }) {
    if (!_looksLikeEmail(email)) return;
    final LastAuthMethodStore target =
        store ?? ref.read(lastAuthMethodStoreProvider);
    unawaited(target.remember(email, method));
  }

  Future<void> _startApple() =>
      _appleSheet ? _signInWithApple() : _startOAuth(AuthMethod.apple);

  /// [method]'s name is the web's provider id.
  Future<void> _startOAuth(AuthMethod method) async {
    assert(
      method == AuthMethod.github ||
          method == AuthMethod.google ||
          method == AuthMethod.apple,
      '$method is not a social provider',
    );
    final provider = method.name;
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInStarted, props: {'provider': provider});
    final email = _emailController.text.trim();
    // Captured up front: the hint below is written after the await, and the
    // browser detour can outlive this widget — a `ref` touched then throws.
    final store = ref.read(lastAuthMethodStoreProvider);
    final auth = ref.read(authServiceProvider);
    final container = ref.container;
    // A hand-off returns to the form even if Continue routed us here from
    // [_Phase.submitting]: its outcome arrives as a deep link much later, and
    // [_onOAuthFailure] only shows itself on the form. An in-app round trip
    // holds the spinner until the session is redeemed, so a second tap cannot
    // start another sign-in underneath it.
    final inApp = auth.oauthRunsInApp;
    setState(() {
      _phase = inApp ? _Phase.submitting : _Phase.form;
      _error = null;
      _notice = null;
      _oauthInApp = inApp;
    });
    final OAuthStart started;
    try {
      started = await auth.startOAuth(provider);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _oauthInApp = false;
        _error = e.message;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = 'Could not complete sign-in. Try again.';
      });
      return;
    } finally {
      _oauthInApp = false;
    }
    // Signed in, the root replaces this screen; anything else is back to the
    // form, where a failure reported during the round trip is already shown.
    if (mounted && started != OAuthStart.signedIn) {
      setState(() => _phase = _Phase.form);
    }
    if (started == OAuthStart.notSignedIn) return;
    // Only once the browser is actually up: written before the launch, the hint
    // outlives a launch that never happened and then routes every later
    // Continue back to a provider that has never worked. It still records the
    // TYPED address, not whichever one the user authenticates as — the callback
    // deep link carries none — so a hint can still land wrong. What keeps that
    // survivable is "Continue with a password": it reaches step 2 whatever the
    // hint says, and step 2 carries the link.
    _remember(email, method, store: store);
    if (started != OAuthStart.signedIn) return;
    // The in-app round trip has no deep link behind it, so nothing else will
    // tell the root the user signed in.
    _warmSignedIn(container);
  }

  /// The session cookie is already stored: tell the root, and warm billing in
  /// parallel with the user refresh so pricing is ready when the shell opens.
  /// Takes a container so a caller past an await need not touch [ref].
  static void _warmSignedIn(ProviderContainer container) {
    container
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInCompleted);
    container.invalidate(currentUserProvider);
    container.invalidate(subscriptionProvider);
    container.invalidate(pricingCatalogProvider);
    prefetchSubscriptionCache(container);
  }

  Future<void> _signInWithApple() async {
    final email = _emailController.text.trim();
    final auth = ref.read(authServiceProvider);
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInStarted, props: {'provider': 'apple'});
    setState(() {
      _phase = _Phase.submitting;
      _error = null;
      _notice = null;
    });
    final bool signedIn;
    try {
      signedIn = await auth.signInWithApple();
    } catch (e) {
      // Anything, not just AuthException: a keychain that refuses the cookie
      // write throws its own type, and leaving the phase at submitting would
      // disable every control on the screen for good.
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = e is AuthException
            ? e.message
            : 'Apple sign-in failed. Try again.';
      });
      return;
    }
    if (!mounted) return;
    if (!signedIn) {
      // Dismissing Apple's sheet is a choice, not a failure: back to the form
      // with nothing to explain.
      setState(() => _phase = _Phase.form);
      return;
    }
    // Keyed on the TYPED address, like the OAuth hint: the sheet may answer
    // with a private relay address the user never typed here.
    _remember(email, AuthMethod.apple);
    _warmSignedIn(ref.container);
  }

  /// Reclaim a sign-in started before this process existed.
  ///
  /// Approving happens outside the app, so Android is free to kill it while
  /// backgrounded — and does, once the detour runs much past ~30s. The bind
  /// cookie is the only credential that can consume the approval, so without
  /// this the user approves the link, returns to an untouched sign-in form,
  /// and the approval is stranded server-side forever.
  Future<void> _restorePendingSignIn() async {
    final session = await ref
        .read(authServiceProvider)
        .restorePendingMagicLink();
    if (!mounted || session == null) return;
    // Whatever the user has already done by hand wins: a link they started
    // (_session set, or _phase moved off the form), an address they are
    // part-way through typing, or a move to the password step — the restored
    // ticket is a MAGIC-LINK sign-in, so resuming it would yank someone out of
    // the form they deliberately opened. A cold-start keychain read can easily
    // outlast the first keystrokes, and clobbering them would swap the field
    // back to a stale address and strand the user on a pending screen they
    // never asked for.
    if (_session != null ||
        _phase != _Phase.form ||
        _step != _Step.email ||
        _emailController.text.isNotEmpty) {
      return;
    }
    setState(() {
      _session = session;
      final email = session.email;
      if (email != null) _emailController.text = email;
      _phase = _Phase.pending;
    });
    _startPolling();
    _startResendCooldown(deadline: session.retryAt);
  }

  bool _looksLikeEmail(String s) {
    final t = s.trim();
    return t.contains('@') &&
        t.indexOf('@') > 0 &&
        t.indexOf('@') < t.length - 1;
  }

  /// Step 1's primary action, and a guess by construction. The stored hint is
  /// the ONLY input to this routing — no server is asked what
  /// [_emailController] holds, because an answer would tell anyone with a list
  /// of addresses which of them have accounts. A null or wrong hint therefore
  /// has to be survivable, and it is: every method below the divider names
  /// itself and ignores the hint entirely, so the guess is never the only way
  /// through.
  Future<void> _continue() async {
    final email = _emailController.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = _emailFieldMessage(email));
      return;
    }
    final store = ref.read(lastAuthMethodStoreProvider);
    setState(() {
      _phase = _Phase.submitting;
      _error = null;
      _notice = null;
    });
    final method = await store.recall(email);
    if (!mounted) return;
    switch (method) {
      case AuthMethod.password:
        _goToStep(_Step.password);
      case AuthMethod.github:
        await _startOAuth(AuthMethod.github);
      case AuthMethod.google:
        await _startOAuth(AuthMethod.google);
      case AuthMethod.apple when _offersAppleSignIn:
        await _startApple();
      // A remembered link, and an address this device has never seen, take the
      // same path — the link is what works without knowing anything. So does an
      // Apple hint on a platform that does not offer Apple, which another
      // surface can have recorded.
      case AuthMethod.apple:
      case AuthMethod.link:
      case null:
        await _sendLink();
    }
  }

  /// Starts a magic link for [email]. Every ref read happens before the await
  /// so nothing here depends on the widget outliving the request; the caller
  /// owns the mounted check and the UI transition.
  Future<MagicLinkSession> _startMagicLink(
    String email, {
    MagicLinkSession? previous,
  }) {
    final auth = ref.read(authServiceProvider);
    ref
        .read(analyticsServiceProvider)
        ?.track(
          AnalyticsEvents.signInStarted,
          props: {'provider': 'magic_link'},
        );
    // Before the send lands, deliberately: a failed send does not change what
    // this address needs, and the link is still the right answer next time.
    _remember(email, AuthMethod.link);
    return auth.startMagicLink(email, previous: previous);
  }

  Future<void> _sendLink() async {
    final email = _emailController.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = _emailFieldMessage(email));
      return;
    }
    setState(() {
      _phase = _Phase.submitting;
      _error = null;
    });
    try {
      final session = await _startMagicLink(email);
      if (!mounted) return;
      setState(() {
        _session = session;
        _phase = _Phase.pending;
      });
      _startPolling();
      _startResendCooldown(deadline: session.retryAt);
    } on AuthException catch (e) {
      if (!mounted) return;
      _honorRetry(e);
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = 'Could not complete sign-in. Try again.';
      });
    }
  }

  /// Send another link from the pending screen. Deliberately stays on
  /// [_Phase.pending] — the user is still waiting, and swapping the body out
  /// for a spinner would hide the state they are waiting in.
  ///
  /// The new pending row comes with a new bind cookie, so [_session] is
  /// replaced and [_startPolling] re-aims the timer at it; a response still in
  /// flight for the OLD session is dropped by the identity guard in
  /// [_pollOnce], which is what stops a stale `expired` from landing on a link
  /// that was just re-sent.
  ///
  /// Nothing hides the pending screen while this is outstanding, so "Use a
  /// different email" sits live right beneath the tap — hence the generation
  /// guard on the way back in.
  Future<void> _resendLink() async {
    if (_resendSecondsLeft > 0 || _resending) return;
    final email = _emailController.text.trim();
    if (!_looksLikeEmail(email)) return;
    setState(() {
      _error = null;
      _notice = null;
    });
    // Armed before the request, not after: that is what makes one tap one send
    // even while the round-trip is outstanding.
    _startResendCooldown();
    final generation = _flowGeneration;
    _resending = true;
    try {
      final session = await _startMagicLink(email, previous: _session);
      if (!mounted) return;
      if (_flowGeneration != generation || _phase != _Phase.pending) {
        return;
      }
      setState(() {
        _session = session;
        // Confirms the REQUEST — the server answers identically whether or not
        // it had somewhere to send to, and we cannot vouch for delivery.
        _notice = 'Sent. Check your inbox again in a moment.';
      });
      _startPolling();
      _startResendCooldown(deadline: session.retryAt);
    } on AuthException catch (e) {
      if (!mounted ||
          _flowGeneration != generation ||
          _phase != _Phase.pending) {
        return;
      }
      _honorRetry(e);
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted && _flowGeneration == generation) {
        setState(() => _error = 'Could not resend the link. Try again.');
      }
    } finally {
      _resending = false;
    }
  }

  void _startResendCooldown({DateTime? deadline}) {
    _cooldownTimer?.cancel();
    _resendDeadline = deadline ?? clock.now().add(_resendCooldown);
    int remaining() =>
        (_resendDeadline!.difference(clock.now()).inMilliseconds / 1000)
            .ceil()
            .clamp(0, 3600);
    setState(() => _resendSecondsLeft = remaining());
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          (_phase != _Phase.pending && _phase != _Phase.verifyEmail)) {
        timer.cancel();
        _cooldownTimer = null;
        return;
      }
      setState(() => _resendSecondsLeft = remaining());
      if (_resendSecondsLeft <= 0) {
        timer.cancel();
        _cooldownTimer = null;
      }
    });
  }

  void _honorRetry(AuthException failure) {
    if (failure.kind == AuthFailure.throttled && failure.retryAfter != null) {
      _startResendCooldown(deadline: clock.now().add(failure.retryAfter!));
    }
  }

  DateTime? _receiptRetry(AuthFlowReceipt? receipt) => receipt == null
      ? null
      : clock.now().add(receipt.retryAt.difference(receipt.serverTime));

  void _goToStep(_Step step) {
    detached(
      'SignInScreen',
      'Cancel previous sign-in',
      ref.read(authServiceProvider).cancelAuthentication,
    );
    // The cooldown belongs to the send that armed it, and the periodic timer
    // self-cancels the moment the phase leaves pending/verifyEmail — so a
    // counter left standing here can never tick back down, and would disable
    // the resend on the next visit for the rest of the app's life.
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    setState(() {
      _flowGeneration++;
      _step = step;
      _phase = _Phase.form;
      _error = null;
      _notice = null;
      _resendSecondsLeft = 0;
    });
  }

  /// The password method, named and always visible. The hint that routes
  /// Continue to step 2 is written only by a successful password sign-in
  /// ([_signInWithPassword]), so without a door of its own the password step
  /// could never be entered a first time — a password added on the web account
  /// page would be unusable here forever.
  ///
  /// It is also what makes a WRONG hint survivable, now that step 1 offers no
  /// link of its own: this reaches step 2 whatever the hint says, and step 2
  /// carries "Email me a link instead".
  ///
  /// Deliberately writes NO hint on the way through: a user who guesses wrong
  /// would otherwise be routed back to a password they do not have on every
  /// later Continue. Same reasoning as the OAuth buttons, which record nothing
  /// until the browser actually opens.
  ///
  /// The address is validated first for the same reason the web's
  /// `/login/password` refuses to render without one: step 2 shows the address
  /// as settled text with no field to fix it, so arriving without a usable one
  /// is a dead end.
  void _useMyPassword() {
    if (!_looksLikeEmail(_emailController.text)) {
      setState(() => _error = _emailFieldMessage(_emailController.text));
      return;
    }
    _goToStep(_Step.password);
  }

  /// Back to the address step from step 2. The typed address stays in the
  /// field to be edited; the password does not, because it belonged to the
  /// address being left behind.
  void _changeEmail() {
    _passwordController.clear();
    _goToStep(_Step.email);
  }

  /// Everything the two password submissions share: validate the address, park
  /// the UI on [_Phase.submitting], run [body], and route an [AuthException]
  /// back to the form. [body] owns the success side, because the two have
  /// nothing in common there — one lands in the app, the other in a mailbox.
  Future<void> _submitPassword(Future<void> Function(String email) body) async {
    final email = _emailController.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = _emailFieldMessage(email));
      return;
    }
    setState(() {
      _phase = _Phase.submitting;
      _error = null;
      _notice = null;
    });
    try {
      await body(email);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.form;
          _error = 'Could not complete sign-in. Try again.';
        });
      }
    } finally {
      if (mounted && _phase == _Phase.submitting) {
        setState(() => _phase = _Phase.form);
      }
    }
  }

  Future<void> _signInWithPassword() => _submitPassword((email) async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      // Not a length check: the minimum applies to passwords being CHOSEN, and
      // restating it here would tell an attacker the policy while blocking
      // nothing the server won't reject anyway.
      setState(() {
        _phase = _Phase.form;
        _error = 'Enter your password';
      });
      return;
    }
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInStarted, props: {'provider': 'password'});
    final outcome = await ref
        .read(authServiceProvider)
        .signInWithPassword(email: email, password: password);
    if (!mounted) return;
    // Both non-failure outcomes prove this address has a password (Better-Auth
    // verifies it before it checks `emailVerified`), which is exactly what the
    // hint records — so an unverified account still skips the link next time.
    if (outcome != PasswordSignIn.invalidCredentials) {
      _remember(email, AuthMethod.password);
    }
    switch (outcome) {
      case PasswordSignIn.ok:
        // Closes the group opened on step 1, which is what asks the platform
        // manager to save the pair. Only on a verdict of OK: committing on a
        // rejected credential would offer to save a password the server just
        // refused, and this screen is about to be popped out from under it.
        TextInput.finishAutofillContext();
        _warmSignedIn(ref.container);
      case PasswordSignIn.invalidCredentials:
        setState(() {
          _phase = _Phase.form;
          _error = 'Invalid email or password';
        });
      case PasswordSignIn.emailNotVerified:
        setState(() => _phase = _Phase.verifyEmail);
        // The server sends nothing on this branch (`sendOnSignIn: false`, see
        // web/src/auth/better-auth.ts) — without this the user waits on a mail
        // that was never going to arrive.
        try {
          final receipt = await ref
              .read(authServiceProvider)
              .sendVerificationEmail(email);
          if (!mounted) return;
          // This screen IS the landing after that send, so the resend beneath
          // it starts its clock here rather than offering an instant retry of
          // mail that has not had time to arrive.
          _startResendCooldown(deadline: _receiptRetry(receipt));
        } on AuthException catch (e) {
          if (!mounted) return;
          // Handled here rather than left to `_submitPassword`: the sign-in
          // reached a verdict, so bouncing back to the form would throw away
          // a correct password over a failed follow-up send. The resend
          // button on this screen is the retry.
          _honorRetry(e);
          setState(() => _error = e.message);
        }
    }
  });

  Future<void> _forgotPassword() => _submitPassword((email) async {
    await ref.read(authServiceProvider).requestPasswordReset(email);
    if (!mounted) return;
    setState(() => _phase = _Phase.resetSent);
  });

  Future<void> _resendVerification() async {
    if (_resendSecondsLeft > 0) return;
    final email = _emailController.text.trim();
    // "Use a different email" sits directly beneath the resend and stays live
    // for the whole round trip, so `mounted` alone would land this send's
    // verdict on whatever flow replaced it. Same guard as [_resendLink], minus
    // its discard: a verification send persists nothing to survive the abandon.
    final generation = _flowGeneration;
    setState(() {
      _error = null;
      _notice = null;
    });
    // Armed before the request, same as [_resendLink]: nothing hides this
    // screen while the send is outstanding, so without it one tap per frame is
    // one send per frame straight into the server's per-minute bucket.
    _startResendCooldown();
    bool abandoned() =>
        !mounted ||
        _flowGeneration != generation ||
        _phase != _Phase.verifyEmail;
    try {
      final receipt = await ref
          .read(authServiceProvider)
          .sendVerificationEmail(email);
      if (abandoned()) return;
      _startResendCooldown(deadline: _receiptRetry(receipt));
      // The server answers identically whether or not it sent anything, so
      // this confirms the REQUEST, not a delivery we cannot vouch for.
      setState(() => _notice = 'Sent. Check your inbox again in a moment.');
    } on AuthException catch (e) {
      if (abandoned()) return;
      _honorRetry(e);
      setState(() => _error = e.message);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollRetryAt = null;
    _pollDeadline = _session?.expiresAt ?? clock.now().add(kMagicLinkWindow);
    _pollTimer = Timer.periodic(
      _pollInterval,
      (_) => detached('SignInScreen', 'Poll sign-in', _pollOnce),
    );
  }

  Future<void> _pollOnce() async {
    final session = _session;
    if (session == null || _polling || _resending) return;
    if (_pollDeadline?.isAfter(clock.now()) == false) {
      _pollTimer?.cancel();
      if (mounted) setState(() => _phase = _Phase.expired);
      return;
    }
    if (_pollRetryAt?.isAfter(clock.now()) == true) return;
    _polling = true;
    try {
      final poll = await ref.read(authServiceProvider).pollStatus(session);
      // Drop a response whose session was replaced while it was in flight
      // (user tapped "Use a different email" or started a new link): the timer
      // was cancelled but this future was already awaiting, so without this
      // guard a stale result would snap the UI to bounced or sign in on an
      // abandoned flow.
      if (!mounted || _resending || !identical(_session, session)) return;

      // A hard bounce means the link will never arrive — stop polling and tell
      // the user. ZeptoMail reports no "delivered" event, so there is no success
      // signal; we just keep waiting for approval until then.
      if (poll.status == MagicLinkStatus.pending &&
          (poll.delivery == DeliveryStatus.failed ||
              poll.delivery == DeliveryStatus.expired)) {
        _pollTimer?.cancel();
        setState(() {
          _phase = _Phase.expired;
          _error =
              'Email could not be delivered. Request a new link or use another sign-in method.';
        });
        return;
      }
      if (poll.status == MagicLinkStatus.pending &&
          poll.delivery == DeliveryStatus.bounced) {
        _pollTimer?.cancel();
        unawaited(ref.read(authServiceProvider).discardPendingMagicLink());
        setState(() => _phase = _Phase.bounced);
        return;
      }

      switch (poll.status) {
        case MagicLinkStatus.ready:
          _pollTimer?.cancel();
          _warmSignedIn(ref.container);
        case MagicLinkStatus.expired:
        case MagicLinkStatus.consumed:
        case MagicLinkStatus.unbound:
          _pollTimer?.cancel();
          setState(() => _phase = _Phase.expired);
        case MagicLinkStatus.pending:
        case MagicLinkStatus.error:
          // keep polling until the link window lapses
          break;
      }
    } on AuthException catch (e) {
      if (mounted && identical(_session, session)) {
        if (e.kind == AuthFailure.throttled && e.retryAfter != null) {
          _pollRetryAt = clock.now().add(e.retryAfter!);
        }
        _honorRetry(e);
        setState(() => _error = e.message);
      }
    } finally {
      _polling = false;
    }
  }

  void _backToForm() {
    _pollTimer?.cancel();
    _pollDeadline = null;
    _pollRetryAt = null;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    unawaited(ref.read(authServiceProvider).discardPendingMagicLink());
    // The password belonged to the address being abandoned.
    _passwordController.clear();
    setState(() {
      _flowGeneration++;
      _phase = _Phase.form;
      _step = _Step.email;
      _session = null;
      _resendSecondsLeft = 0;
      _error = null;
      _notice = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
      final user = next.value;
      if (user == null) return;
      // Load-bearing when the user got here by revocation: the notice is what
      // pins the root to this screen, so nothing else can retire it.
      clearRevokedNotice(ref.container);
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    });

    return AbCarbonScope(
      child: Builder(
        builder: (scoped) {
          final t = CarbonTheme.of(scoped);
          // Chosen from density, not window width: a phone column is the
          // screen width less its gutters, and the three method buttons only
          // fit one row at that width. A wide tablet is touch too and gets the
          // same column, which is what a phone-shaped form should be.
          final columnWidth = t.isTouch
              ? _touchColumnWidth
              : _compactColumnWidth;
          final lightBrand = t.brightness == Brightness.light;
          // The Scaffold keeps the keyboard inset handling.
          return Scaffold(
            backgroundColor: t.colors.background,
            body: SafeArea(
              child: Stack(
                children: [
                  if (canPop && !isMobilePlatform)
                    Positioned(
                      top: CarbonSpacing.spacing03,
                      right: CarbonSpacing.spacing03,
                      child: CarbonButton.iconOnly(
                        icon: const CarbonIcon(CarbonIcons.close),
                        semanticLabel: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  // One group spanning BOTH steps, which is what makes the
                  // address and the password a single credential to the
                  // platform password manager: the two fields never coexist on
                  // screen, and a group per step would commit the address on
                  // its own and offer to save a password with no username
                  // attached.
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                      child: AutofillGroup(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: columnWidth),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Two-tone artwork, so a light ground gets its
                              // own file rather than a tint.
                              SvgPicture.asset(
                                lightBrand
                                    ? 'assets/logo/antgrid-lockup-light.svg'
                                    : 'assets/logo/antgrid-lockup.svg',
                                height: _lockupHeight,
                                semanticsLabel: 'Antgrid',
                              ),
                              const SizedBox(height: CarbonSpacing.spacing04),
                              switch (_phase) {
                                _Phase.pending => _pendingBody(scoped),
                                _Phase.bounced => _bouncedBody(scoped),
                                _Phase.expired => _expiredBody(scoped),
                                _Phase.verifyEmail => _verifyEmailBody(scoped),
                                _Phase.resetSent => _resetSentBody(scoped),
                                _Phase.form ||
                                _Phase.submitting => _formBody(scoped, canPop),
                              },
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static const double _compactColumnWidth = 320;

  /// A 390pt phone less its 16pt gutters.
  static const double _touchColumnWidth = 358;

  static const double _lockupHeight = 80;

  Widget _formBody(BuildContext context, bool canPop) => switch (_step) {
    _Step.email => _emailStepBody(context, canPop),
    _Step.password => _passwordStepBody(context),
    _Step.signup => _signupBody(context),
  };

  Widget _gap([double height = CarbonSpacing.spacing03]) =>
      SizedBox(height: height);

  Widget _heading(CarbonThemeData t, String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: t.typography.heading.copyWith(color: t.colors.textPrimary),
  );

  Widget _detail(CarbonThemeData t, String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: t.typography.helper.copyWith(color: t.colors.textSecondary),
  );

  /// A primary action: the one filled button of its phase. [arrow] marks the
  /// step that moves the form forward.
  Widget _primary(String label, VoidCallback? onPressed, {bool arrow = false}) =>
      CarbonButton(
        label: label,
        onPressed: onPressed,
        expand: true,
        icon: arrow ? const CarbonIcon(CarbonIcons.arrowRight) : null,
      );

  Widget _link(String label, VoidCallback? onTap) =>
      Center(child: CarbonLink(label: label, onPressed: onTap));

  /// The room a field's one-line error takes under it, held while there is
  /// none. The column is centred, so an error that arrived in fresh space
  /// would lift everything above it — the logo included — by half its height.
  /// Spacing and style mirror `CarbonFieldFrame`'s message line.
  Widget _reservedFieldMessage(CarbonThemeData t) => Visibility(
    visible: false,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: Padding(
      padding: const EdgeInsets.only(top: CarbonSpacing.spacing02),
      child: Text(' ', style: t.typography.helper),
    ),
  );

  /// Step 1: an address and nothing else. No sign-in/sign-up fork, and no
  /// password field — that fork would make the user answer a question about
  /// their own account that only this device's memory can answer for them.
  ///
  /// Two tiers, and the split is what the hint is allowed to decide. Continue
  /// is the fast path and the only thing that reads the hint; every method
  /// below the divider names its own method and ignores it, so a hint that is
  /// missing or wrong costs a tap rather than the account. None of them asks
  /// the server anything.
  ///
  /// Three visual classes, one per tier, so the tiers are told apart before
  /// they are read: the filled Continue, the outlined method buttons, and the
  /// demo tile. Every one of these was a full-width button of the same weight
  /// once, and five of them stacked read as a wall rather than a hierarchy.
  Widget _emailStepBody(BuildContext context, bool canPop) {
    final t = CarbonTheme.of(context);
    final busy = _phase == _Phase.submitting;
    // The one error that belongs to the field; the rest (a browser that would
    // not open, a provider that bounced) are about the screen, not the address.
    final fieldError =
        _error == _emptyEmailMessage || _error == _invalidEmailMessage
        ? _error
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in or create an account',
          textAlign: TextAlign.center,
          style: t.typography.body.copyWith(color: t.colors.textSecondary),
        ),
        _gap(CarbonSpacing.spacing05),
        CarbonTextInput(
          controller: _emailController,
          label: 'Email',
          placeholder: 'you@example.com',
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          // `username`, not `email`: the manager has to file this against the
          // password on step 2 as ONE credential, and it is the username half
          // of that pair it looks for — a field tagged as a bare email address
          // is offered contact suggestions instead and saves nothing.
          autofillHints: const [AutofillHints.username],
          errorText: fieldError,
          announceError: true,
          onSubmitted: (_) => busy ? null : _continue(),
        ),
        if (fieldError == null) _reservedFieldMessage(t),
        ?_message(t, errorInField: fieldError != null),
        _gap(CarbonSpacing.spacing03),
        _primary(
          busy ? 'Continuing…' : 'Continue',
          busy ? null : _continue,
          arrow: true,
        ),
        _gap(CarbonSpacing.spacing04),
        const _OrDivider(),
        _gap(CarbonSpacing.spacing04),
        if (_offersAppleSignIn) ...[
          _AppleButton(
            onPressed: busy
                ? null
                : () => detached(
                    'SignInScreen',
                    'Apple sign-in failed',
                    _startApple,
                  ),
          ),
          _gap(),
        ],
        // These are all answers to a single question — how to prove the
        // address is yours — so they sit together as one row.
        //
        // The password button is a peer, not a footnote. `_startOAuth` records
        // the TYPED address rather than the one the user authenticates as, so
        // the hint can land wrong, and this button is the only thing that
        // reaches step 2 — and the link it carries — whatever the hint says.
        _MethodRow(
          methods: [
            _Method(
              label: 'GitHub',
              icon: const _BrandGlyph(_githubMark),
              onPressed: busy ? null : () => _startOAuth(AuthMethod.github),
            ),
            _Method(
              label: 'Google',
              icon: const _BrandGlyph(_googleMark),
              onPressed: busy ? null : () => _startOAuth(AuthMethod.google),
            ),
            // Unconditional, never keyed on what the store recalls: visibility
            // that tracked the hint would flicker as the address is typed and
            // would tell anyone watching the screen which addresses this
            // device remembers.
            _Method(
              label: 'Password',
              icon: const CarbonIcon(CarbonIcons.password),
              onPressed: busy ? null : _useMyPassword,
            ),
          ],
        ),
        _gap(CarbonSpacing.spacing06),
        // A tile, not a fifth button, because it is not a way through this
        // screen — it leaves the account behind entirely, and the two lines it
        // needs never fitted on a button label anyway.
        //
        // Unguarded unlike the link below it: on mobile this screen is the
        // whole app until an account exists, so for an App Store reviewer — or
        // a tester whose desktop is somewhere else — it is the only affordance
        // here that leads anywhere at all.
        CarbonClickableTile(
          onPressed: busy ? null : _enterDemo,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                kDemoEntryLabel,
                // Carbon styles are non-inheriting, so the tile's text colour
                // never reaches this line unless it is set here.
                style: t.typography.heading.copyWith(
                  color: busy ? t.colors.textDisabled : t.colors.textPrimary,
                ),
              ),
              const SizedBox(height: CarbonSpacing.spacing01),
              Text(
                'No account needed. Explore the app on a built-in project.',
                style: t.typography.helper.copyWith(
                  color: busy ? t.colors.textDisabled : t.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        // The only text link on the screen, and the only one that leaves the
        // flow rather than choosing a way through it.
        if (canPop && !isMobilePlatform) ...[
          _gap(CarbonSpacing.spacing04),
          _link(
            'Continue without signing in',
            () => Navigator.of(context).maybePop(),
          ),
        ],
      ],
    );
  }

  /// Leaves sign-in for the offline demo.
  ///
  /// On desktop this screen is a pushed route and the demo replaces the root's
  /// content, so it has to come off the stack first or the demo renders
  /// underneath it. `enterDemoMode` does that for every entry point; `ref` is
  /// read here, before the call, because the pop leaves it defunct.
  void _enterDemo() => enterDemoMode(ref.container);

  Future<void> _signUp() => _submitPassword((email) async {
    final receipt = await ref
        .read(authServiceProvider)
        .signUpWithPassword(email: email, password: _passwordController.text);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.verifyEmail;
      _notice =
          'If this address is eligible, a verification link will arrive. Check your spam folder.';
    });
    _startResendCooldown(deadline: _receiptRetry(receipt));
  });

  Widget _signupBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Create an account with a password'),
        _gap(),
        Text(
          _emailController.text.trim(),
          textAlign: TextAlign.center,
          style: t.typography.body.copyWith(color: t.colors.textSecondary),
        ),
        _gap(),
        CarbonTextInput(
          controller: _passwordController,
          variant: CarbonTextInputVariant.password,
          label: 'Password',
          helperText: '$kMinPasswordLength–$kMaxPasswordLength characters',
          enabled: !busy,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.done,
          errorText: _error,
          announceError: true,
          onSubmitted: (_) =>
              detached('SignInScreen', 'Create account', _signUp),
        ),
        ?_message(t, errorInField: true),
        _gap(),
        _primary(
          busy ? 'Creating account…' : 'Create account',
          busy
              ? null
              : () => detached('SignInScreen', 'Create account', _signUp),
        ),
        _link('Sign in instead', busy ? null : () => _goToStep(_Step.password)),
        _link('Use a different email', busy ? null : _changeEmail),
      ],
    );
  }

  Widget _passwordStepBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter your password',
          textAlign: TextAlign.center,
          style: t.typography.body.copyWith(color: t.colors.textSecondary),
        ),
        _gap(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _emailController.text.trim(),
                overflow: TextOverflow.ellipsis,
                style: t.typography.helper.copyWith(
                  color: t.colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: CarbonSpacing.spacing03),
            CarbonLink(
              label: 'change',
              onPressed: busy ? null : _changeEmail,
              size: CarbonLinkSize.small,
            ),
          ],
        ),
        _gap(),
        CarbonTextInput(
          controller: _passwordController,
          variant: CarbonTextInputVariant.password,
          label: 'Password',
          enabled: !busy,
          textInputAction: TextInputAction.go,
          autofillHints: const [AutofillHints.password],
          errorText: _error,
          announceError: true,
          onSubmitted: (_) => busy ? null : _signInWithPassword(),
        ),
        if (_error == null) _reservedFieldMessage(t),
        ?_message(t, errorInField: true),
        _gap(),
        _primary(
          busy ? 'Signing in…' : 'Sign in',
          busy ? null : _signInWithPassword,
          arrow: true,
        ),
        _gap(),
        _link(
          'Create an account with a password',
          busy ? null : () => _goToStep(_Step.signup),
        ),
        _link('Forgot your password?', busy ? null : _forgotPassword),
        _link('Email me a link instead', busy ? null : _sendLink),
      ],
    );
  }

  /// The server-message line, or null when there is nothing to say. An error
  /// wins: the two are set as a pair (one always cleared with the other), so
  /// this only orders them when a later failure lands on an earlier success.
  ///
  /// Carbon files form-level server messages as inline notifications — an error
  /// for a failure, info for a confirmation — while a message about one field
  /// belongs on that field. [errorInField] says the error is already drawn
  /// there, leaving only a notice for this line.
  Widget? _message(CarbonThemeData t, {bool errorInField = false}) {
    final error = errorInField ? null : _error;
    final text = error ?? _notice;
    if (text == null) return null;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: CarbonSpacing.spacing03),
        child: CarbonNotification(
          kind: error != null
              ? CarbonNotificationKind.error
              : CarbonNotificationKind.info,
          subtitle: text,
        ),
      ),
    );
  }

  Widget _verifyEmailBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    final email = _emailController.text.trim();
    // Only a failed send sets `_error` on this screen, and every send clears it
    // first — so this reads as "the last send failed", which is what keeps the
    // claim below from asserting a link the user is never going to get.
    final sent = _error == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Check your email'),
        _gap(),
        _detail(
          t,
          'Check the inbox for $email. If this address is eligible, a link will arrive. It expires in one hour. Check your spam folder. '
          '${sent ? ' Verification was requested.' : ''}',
        ),
        ?_message(t),
        _gap(CarbonSpacing.spacing05),
        // The password is still in the field behind this screen, so verifying
        // and coming back costs one tap. If the OS killed the app during the
        // detour it is simply gone, and the user signs in normally — it is
        // never persisted anywhere.
        if (_passwordController.text.isNotEmpty)
          _primary("I've verified — sign in", () {
            _goToStep(_Step.password);
            unawaited(_signInWithPassword());
          }),
        _gap(),
        _link(
          _resendSecondsLeft > 0
              ? 'Resend the link (${_resendSecondsLeft}s)'
              : 'Resend the link',
          _resendSecondsLeft > 0 ? null : _resendVerification,
        ),
        _link('Use a different email', _backToForm),
      ],
    );
  }

  Widget _resetSentBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Check your email'),
        _gap(),
        _detail(
          t,
          // Enumeration-safe on the server, so the copy has to be too: it
          // answers a known and an unknown address identically.
          'If that address has an Antgrid account, a reset link is on its way. '
          'The link expires in one hour and opens in your browser.',
        ),
        _gap(CarbonSpacing.spacing05),
        _primary('Back to sign in', () => _goToStep(_Step.password)),
      ],
    );
  }

  Widget _pendingBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    final email = _emailController.text.trim();
    // A restored ticket can arrive without its address (older schema), and
    // there is nothing to re-send to then.
    final canResend = _resendSecondsLeft == 0 && _looksLikeEmail(email);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Check your email'),
        _gap(),
        _detail(
          t,
          'Approve the sign-in link sent to\n$email\n'
          // Straight from the window the server actually enforces, so the two
          // can never disagree about how long the user has.
          'The link expires in ${kMagicLinkWindow.inMinutes} minutes.',
        ),
        _gap(CarbonSpacing.spacing05),
        const Center(child: CarbonSpinner(size: 24, semanticLabel: 'Waiting')),
        ?_message(t),
        _gap(CarbonSpacing.spacing05),
        _link(
          _resendSecondsLeft > 0
              ? 'Resend the link (${_resendSecondsLeft}s)'
              : 'Resend the link',
          canResend ? _resendLink : null,
        ),
        _link('Use a different email', _backToForm),
      ],
    );
  }

  Widget _expiredBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Link expired'),
        _gap(),
        _detail(t, 'That sign-in link is no longer valid.'),
        _gap(CarbonSpacing.spacing05),
        _primary('Send a new link', _sendLink),
        _gap(),
        _link('Use a different email', _backToForm),
      ],
    );
  }

  Widget _bouncedBody(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t, 'Email bounced'),
        _gap(),
        _detail(
          t,
          "We couldn't deliver the link to\n${_emailController.text.trim()}.\nCheck the address and try again.",
        ),
        _gap(CarbonSpacing.spacing05),
        _primary('Use a different email', _backToForm),
      ],
    );
  }
}

/// The messages [_SignInScreenState._continue] and its siblings raise for an
/// address step 2 could not show; named so the field can claim them as its own.
const _emptyEmailMessage = 'Enter your email';
const _invalidEmailMessage = 'Enter a valid email';

String _emailFieldMessage(String email) =>
    email.trim().isEmpty ? _emptyEmailMessage : _invalidEmailMessage;

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final line = Expanded(
      child: ColoredBox(
        color: t.borderSubtle(CarbonLayer.of(context)),
        child: const SizedBox(height: 1),
      ),
    );
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing03,
          ),
          child: Text(
            'or',
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ),
        line,
      ],
    );
  }
}

/// Codicon `github`, inlined as a `currentColor` SVG string. Carbon's icon set
/// has no brand logos, and this is the same artwork the rest of the app shows
/// for GitHub, so the sign-in button does not look like a different service.
const String _githubMark =
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
    'viewBox="0 0 24 24"><path fill="currentColor" d="'
    'M12 0a12 12 0 100 24 12 12 0 000-24zm3.163 21.783h-.093a.513'
    '.513 0 01-.382-.14.513.513 0 01-.14-.372v-1.406c.006-.467.01'
    '-.94.01-1.416a3.693 3.693 0 00-.151-1.028 1.832 1.832 0 00-.'
    '542-.875 8.014 8.014 0 002.038-.471 4.051 4.051 0 001.466-.9'
    '64c.407-.427.71-.943.885-1.506a6.77 6.77 0 00.3-2.13 4.138 4'
    '.138 0 00-.26-1.476 3.892 3.892 0 00-.795-1.284 2.81 2.81 0 '
    '00.162-.582c.033-.2.05-.402.05-.604 0-.26-.03-.52-.09-.773a5'
    '.309 5.309 0 00-.221-.763.293.293 0 00-.111-.02h-.11c-.23.00'
    '2-.456.04-.674.111a5.34 5.34 0 00-.703.26 6.503 6.503 0 00-.'
    '661.343c-.215.127-.405.249-.573.362a9.578 9.578 0 00-5.143 0'
    ' 13.507 13.507 0 00-.572-.362 6.022 6.022 0 00-.672-.342 4.5'
    '16 4.516 0 00-.705-.261 2.203 2.203 0 00-.662-.111h-.11a.29.'
    '29 0 00-.11.02 5.844 5.844 0 00-.23.763c-.054.254-.08.513-.0'
    '81.773 0 .202.017.404.051.604.033.199.086.394.16.582A3.888 3'
    '.888 0 005.702 10a4.142 4.142 0 00-.263 1.476 6.871 6.871 0 '
    '00.292 2.12c.181.563.483 1.08.884 1.516.415.422.915.75 1.466'
    '.964.653.25 1.337.41 2.033.476a1.828 1.828 0 00-.452.633 2.9'
    '9 2.99 0 00-.2.744 2.754 2.754 0 01-1.175.27 1.788 1.788 0 0'
    '1-1.065-.3 2.904 2.904 0 01-.752-.824 3.1 3.1 0 00-.292-.382'
    ' 2.693 2.693 0 00-.372-.343 1.841 1.841 0 00-.432-.24 1.2 1.'
    '2 0 00-.481-.101c-.04.001-.08.005-.12.01a.649.649 0 00-.162.'
    '02.408.408 0 00-.13.06.116.116 0 00-.06.1.33.33 0 00.14.242c'
    '.093.074.17.131.232.171l.03.021c.133.103.261.214.382.333.112'
    '.098.213.209.3.33.09.119.168.246.231.381.073.134.15.288.231.'
    '463.188.474.522.875.954 1.145.453.243.961.364 1.476.351.174 '
    '0 .349-.01.522-.03.172-.028.343-.057.515-.091v1.743a.5.5 0 0'
    '1-.533.521h-.062a10.286 10.286 0 116.324 0v.005z'
    '"/></svg>';

/// Simple Icons `google` (CC0), inlined as a `currentColor` SVG string:
/// Carbon's icon set has no brand logos, and this is a third-party mark rather
/// than a UI affordance.
const String _googleMark =
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
    'viewBox="0 0 24 24"><path fill="currentColor" d="M12.48 10.92v3.28h7.84'
    'c-.24 1.84-.853 3.187-1.787 4.133c-1.147 1.147-2.933 2.4-6.053 2.4'
    'c-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 '
    '2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0C5.867 0 .307 5.387.307 12'
    's5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36c2.16-2.16 2.84-5.213 '
    '2.84-7.667c0-.76-.053-1.467-.173-2.053z"/></svg>';

/// A brand mark tinted by the surrounding [IconTheme], which is how a
/// [CarbonButton] hands its `icon` the right colour at rest, hover, press and
/// disabled — so these glyphs follow the button exactly as a Carbon icon does.
class _BrandGlyph extends StatelessWidget {
  const _BrandGlyph(this.svg);

  final String svg;

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    final color = icon.color ?? CarbonTheme.of(context).colors.iconPrimary;
    return SvgPicture.string(
      svg,
      width: icon.size,
      height: icon.size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

class _Method {
  const _Method({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final Widget icon;

  /// Null disables the button. Every method disables together — only
  /// [_Phase.submitting] ever does it.
  final VoidCallback? onPressed;
}

/// The step-1 method buttons: equal tertiary buttons that share one rule and
/// stay on one row for as long as their labels fit, and never clip them when
/// they do not.
///
/// Not a [CarbonButtonSet]: that stacks with the LAST child on top, so a set
/// listing GitHub, Google, Password in row order would read Password, Google,
/// GitHub down a phone — and either order chosen for the stack reverses the
/// row. Measuring the labels here lets both layouts read in the same order.
///
/// Three fits, tried in order: centred icon and label on one row; centred
/// labels alone on one row (the icon is the first thing to give, since the label
/// already names the method); then stacked full width with Carbon's own layout
/// and icons, which is what enlarged text lands on.
class _MethodRow extends StatefulWidget {
  const _MethodRow({required this.methods});

  final List<_Method> methods;

  @override
  State<_MethodRow> createState() => _MethodRowState();
}

class _MethodRowState extends State<_MethodRow> {
  // Adjacent outlines overlap by their own width so two borders draw as one
  // rule instead of a doubled 2px line.
  static const double _overlap = CarbonBorders.hairline;

  // Whichever overlapping neighbour paints last owns the shared rule, so the
  // button being pressed, focused or hovered is painted last; otherwise its
  // neighbour's resting edge would cut through its pressed border or focus
  // ring on one side.
  int? _pressed;
  int? _focused;
  int? _hovered;

  int? get _active => _pressed ?? _focused ?? _hovered;

  void _set(void Function() change) {
    if (mounted) setState(change);
  }

  @override
  Widget build(BuildContext context) {
    final methods = widget.methods;
    final t = CarbonTheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var widest = 0.0;
        for (final m in methods) {
          final painter = TextPainter(
            text: TextSpan(text: m.label, style: t.typography.control),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.width);
          painter.dispose();
        }
        // CarbonButtonContent.centered: 8 padding each side and 8 between icon
        // and label. The 1 is slack for sub-pixel rounding, since a wrong guess
        // clips.
        const padding = 2 * CarbonSpacing.spacing03;
        final withIcon =
            padding + t.iconSize + CarbonSpacing.spacing03 + widest + 1;
        final labelOnly = padding + widest + 1;
        final n = methods.length;
        // Every button is one share wide and each overlaps the last by the
        // hairline, so the shares add up to the width plus the overlaps.
        final share = (constraints.maxWidth + _overlap * (n - 1)) / n;

        Widget button(_Method m, {required bool icon, required bool centered}) =>
            CarbonButton(
              label: m.label,
              kind: CarbonButtonKind.tertiary,
              expand: true,
              content: centered
                  ? CarbonButtonContent.centered
                  : CarbonButtonContent.standard,
              onPressed: m.onPressed,
              icon: icon ? m.icon : null,
            );

        if (share >= labelOnly) {
          final icons = share >= withIcon;
          Widget cell(int i) => KeyedSubtree(
            key: ValueKey(i),
            child: Padding(
              // Directional, so the row reads from the start edge in RTL too.
              padding: EdgeInsetsDirectional.only(start: i * (share - _overlap)),
              child: SizedBox(
                width: share,
                child: MouseRegion(
                  onEnter: (_) => _set(() => _hovered = i),
                  onExit: (_) => _set(() {
                    if (_hovered == i) _hovered = null;
                  }),
                  child: Listener(
                    onPointerDown: (_) => _set(() => _pressed = i),
                    onPointerUp: (_) => _set(() {
                      if (_pressed == i) _pressed = null;
                    }),
                    onPointerCancel: (_) => _set(() {
                      if (_pressed == i) _pressed = null;
                    }),
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) => _set(() {
                        if (focused) {
                          _focused = i;
                        } else if (_focused == i) {
                          _focused = null;
                        }
                      }),
                      child: button(methods[i], icon: icons, centered: true),
                    ),
                  ),
                ),
              ),
            ),
          );
          final active = _active;
          // Each cell is inset from the start by the shares before it, so the
          // last one ends exactly at the row's end edge. Keys keep each
          // button's state when the paint order changes.
          return Stack(
            alignment: AlignmentDirectional.topStart,
            children: [
              for (var i = 0; i < n; i++)
                if (i != active) cell(i),
              if (active != null && active < n) cell(active),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: CarbonSpacing.spacing03,
          children: [
            for (final m in methods) button(m, icon: true, centered: false),
          ],
        );
      },
    );
  }
}

/// Sign in with Apple, built to Apple's button rules rather than Carbon's.
///
/// App Review holds this button to Apple's Human Interface Guidelines (App
/// Store guideline 4.8) and rejected the iOS build once already, so it is
/// deliberately NOT a [CarbonButton]: Apple's own logo artwork, Apple's black
/// or white fill with the opposite ink, the title spelled out as "Continue with
/// Apple", and no less prominent than the other providers — full width and at
/// least as tall as any of them. Carbon supplies only focus, keyboard
/// activation and semantics. Square corners are within the guidelines.
class _AppleButton extends StatelessWidget {
  const _AppleButton({required this.onPressed});

  final VoidCallback? onPressed;

  // Apple-mandated, not theme tokens: they must stay pure black and white
  // whatever Carbon palette is active.
  static const _black = Color(0xFF000000);
  static const _white = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    // Black on a light ground and white on a dark one, the two fills Apple
    // allows beside a coloured or neutral page, with the opposite ink.
    final light = t.brightness == Brightness.light;
    final fill = light ? _black : _white;
    final ink = light ? _white : _black;
    // The same height as Continue above it: never shorter than any other
    // provider, and no taller, so neither reads as the louder choice.
    final height = math.max(t.controlHeight, t.minTarget);
    // Apple fixes the title at about 43% of the button height whatever font is
    // used, and prefers the system font, so the title is sized from the button
    // and deliberately takes nothing from Carbon's type scale.
    final mark = (height * 0.43).roundToDouble();
    final style = TextStyle(
      inherit: false,
      fontSize: mark,
      fontWeight: FontWeight.w500,
      color: ink,
    );
    return CarbonInteraction(
      onPressed: onPressed,
      label: 'Continue with Apple',
      excludeChildSemantics: true,
      builder: (context, state, _) => Opacity(
        opacity: state.enabled ? 1 : 0.4,
        child: CarbonFocusRing(
          visible: state.focusVisible,
          onColor: true,
          child: Container(
            key: const ValueKey('sign-in-apple'),
            constraints: BoxConstraints(minHeight: height),
            padding: const EdgeInsets.symmetric(
              horizontal: CarbonSpacing.spacing05,
              vertical: CarbonSpacing.spacing03,
            ),
            alignment: Alignment.center,
            color: fill.withValues(
              alpha: state.pressed
                  ? 0.8
                  : state.hovered
                  ? 0.9
                  : 1,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: mark * 25 / 31,
                  height: mark,
                  child: CustomPaint(painter: AppleLogoPainter(color: ink)),
                ),
                const SizedBox(width: CarbonSpacing.spacing03),
                Flexible(
                  child: Text(
                    'Continue with Apple',
                    textAlign: TextAlign.center,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
