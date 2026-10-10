import 'dart:async';
import 'package:clock/clock.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AppleLogoPainter;
import '../demo/demo_identity.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../util/detached.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_brand_mark.dart';
import '../design/widgets/ab_focus_ring.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_password_field.dart';
import '../design/widgets/ab_text_field.dart';
import '../design/widgets/ab_touch_sizing.dart';
import '../project/limits.dart';
import '../analytics/events.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/demo_mode.dart';
import '../providers/device_revocation.dart';
import '../providers/subscription.dart';
import '../services/auth_service.dart';
import '../storage/last_auth_method_store.dart';

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
      setState(() => _error = 'Enter a valid email');
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
      setState(() => _error = 'Enter a valid email');
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
      setState(() => _error = 'Enter a valid email');
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
      setState(() => _error = 'Enter a valid email');
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
    final antgrid = context.antgrid;
    final canPop = Navigator.of(context).canPop();

    ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
      final user = next.value;
      if (user == null) return;
      // Load-bearing when the user got here by revocation: the notice is what
      // pins the root to this screen, so nothing else can retire it.
      clearRevokedNotice(ref.container);
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    });

    return Scaffold(
      backgroundColor: antgrid.bgDeepest,
      body: SafeArea(
        child: Stack(
          children: [
            if (canPop && !isMobilePlatform)
              Positioned(
                top: AbTokens.space8,
                right: AbTokens.space8,
                child: AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            // One group spanning BOTH steps, which is what makes the address
            // and the password a single credential to the platform password
            // manager: the two fields never coexist on screen, and a group per
            // step would commit the address on its own and offer to save a
            // password with no username attached.
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AbTokens.space16),
                child: AutofillGroup(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AbBrandMark.lockup(height: AbTokens.space16 * 5),
                        const SizedBox(height: AbTokens.space12),
                        switch (_phase) {
                          _Phase.pending => _pendingBody(context),
                          _Phase.bounced => _bouncedBody(context),
                          _Phase.expired => _expiredBody(context),
                          _Phase.verifyEmail => _verifyEmailBody(context),
                          _Phase.resetSent => _resetSentBody(context),
                          _Phase.form ||
                          _Phase.submitting => _formBody(context, canPop),
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
  }

  Widget _formBody(BuildContext context, bool canPop) => switch (_step) {
    _Step.email => _emailStepBody(context, canPop),
    _Step.password => _passwordStepBody(context),
    _Step.signup => _signupBody(context),
  };

  /// Step 1: an address and nothing else. No sign-in/sign-up fork, and no
  /// password field — that fork would make the user answer a question about
  /// their own account that only this device's memory can answer for them.
  ///
  /// Two tiers, and the split is what the hint is allowed to decide. Continue
  /// is the fast path and the only thing that reads the hint; every cell below
  /// the divider names its own method and ignores it, so a hint that is
  /// missing or wrong costs a tap rather than the account. None of them asks
  /// the server anything.
  ///
  /// Three visual classes, one per tier, so the tiers are told apart before
  /// they are read: the accent-filled Continue, the bordered method group, and
  /// the outlined demo card. Every one of these was a full-width button of the
  /// same weight once, and five of them stacked read as a wall rather than a
  /// hierarchy.
  Widget _emailStepBody(BuildContext context, bool canPop) {
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in or create an account',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: context.antgrid.textMuted),
        ),
        const SizedBox(height: AbTokens.space16),
        AbTextField(
          controller: _emailController,
          hintText: 'you@example.com',
          height: AbTokens.rowHeightLg,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          // `username`, not `email`: the manager has to file this against the
          // password on step 2 as ONE credential, and it is the username half
          // of that pair it looks for — a field tagged as a bare email address
          // is offered contact suggestions instead and saves nothing.
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => busy ? null : _continue(),
        ),
        ?_message(context),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: busy ? 'Continuing…' : 'Continue',
          onPressed: busy ? null : _continue,
          variant: _SignInButtonVariant.primary,
        ),
        const SizedBox(height: AbTokens.space12),
        const _OrDivider(),
        const SizedBox(height: AbTokens.space12),
        if (_offersAppleSignIn) ...[
          _SignInButton(
            label: 'Continue with Apple',
            leading: (color) => _AppleMark(color: color),
            appleInk: true,
            onPressed: busy
                ? null
                : () => detached(
                    'SignInScreen',
                    'Apple sign-in failed',
                    _startApple,
                  ),
          ),
          const SizedBox(height: AbTokens.space8),
        ],
        // One bordered group rather than stacked buttons: these are all
        // answers to a single question — how to prove the address is yours —
        // and [AbSegmented]'s construction is how this app already asks a small
        // closed set where the alternatives must stay visible. Not AbSegmented
        // itself: a cell here fires an action, and a selected state would
        // promise a choice that persists.
        //
        // The password cell is a peer, not a footnote. `_startOAuth` records
        // the TYPED address rather than the one the user authenticates as, so
        // the hint can land wrong, and this cell is the only thing that reaches
        // step 2 — and the link it carries — whatever the hint says.
        _AuthMethodRow(
          methods: [
            _AuthMethodSpec(
              icon: AbIcons.github,
              label: 'GitHub',
              onTap: busy ? null : () => _startOAuth(AuthMethod.github),
            ),
            _AuthMethodSpec(
              icon: _googleMark,
              label: 'Google',
              onTap: busy ? null : () => _startOAuth(AuthMethod.google),
            ),
            // Unconditional, never keyed on what the store recalls: visibility
            // that tracked the hint would flicker as the address is typed and
            // would tell anyone watching the screen which addresses this device
            // remembers.
            _AuthMethodSpec(
              icon: AbIcons.password,
              label: 'Password',
              onTap: busy ? null : _useMyPassword,
            ),
          ],
        ),
        const SizedBox(height: AbTokens.space24),
        // A card, not a fifth button, because it is not a way through this
        // screen — it leaves the account behind entirely, and the two lines it
        // needs never fitted on a centred button label anyway.
        //
        // Unguarded unlike the link below it: on mobile this screen is the
        // whole app until an account exists, so for an App Store reviewer — or
        // a tester whose desktop is somewhere else — it is the only affordance
        // here that leads anywhere at all.
        _DemoCard(onTap: busy ? null : _enterDemo),
        // The only muted thing on the screen, and the only one that leaves the
        // flow rather than choosing a way through it.
        if (canPop && !isMobilePlatform) ...[
          const SizedBox(height: AbTokens.space12),
          _MutedLink(
            label: 'Continue without signing in',
            onTap: () => Navigator.of(context).maybePop(),
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
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Create an account with a password',
          style: AbTokens.sansStyle(color: context.antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          _emailController.text.trim(),
          style: AbTokens.sansStyle(color: context.antgrid.textMuted),
        ),
        const SizedBox(height: AbTokens.space8),
        AbPasswordField(
          controller: _passwordController,
          hintText:
              'Password ($kMinPasswordLength?$kMaxPasswordLength characters)',
          enabled: !busy,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) =>
              detached('SignInScreen', 'Create account', _signUp),
        ),
        ?_message(context),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: busy ? 'Creating account...' : 'Create account',
          onPressed: busy
              ? null
              : () => detached('SignInScreen', 'Create account', _signUp),
          variant: _SignInButtonVariant.primary,
        ),
        _MutedLink(
          label: 'Sign in instead',
          onTap: busy ? null : () => _goToStep(_Step.password),
        ),
        _MutedLink(
          label: 'Use a different email',
          onTap: busy ? null : _changeEmail,
        ),
      ],
    );
  }

  Widget _passwordStepBody(BuildContext context) {
    final antgrid = context.antgrid;
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter your password',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textMuted),
        ),
        const SizedBox(height: AbTokens.space8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _emailController.text.trim(),
                overflow: TextOverflow.ellipsis,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: antgrid.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: AbTokens.space8),
            _MutedLink(label: 'change', onTap: busy ? null : _changeEmail),
          ],
        ),
        const SizedBox(height: AbTokens.space8),
        AbPasswordField(
          controller: _passwordController,
          hintText: 'Password',
          enabled: !busy,
          textInputAction: TextInputAction.go,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => busy ? null : _signInWithPassword(),
        ),
        ?_message(context),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: busy ? 'Signing in…' : 'Sign in',
          onPressed: busy ? null : _signInWithPassword,
          variant: _SignInButtonVariant.primary,
        ),
        const SizedBox(height: AbTokens.space8),
        _MutedLink(
          label: 'Create an account with a password',
          onTap: busy ? null : () => _goToStep(_Step.signup),
        ),
        _MutedLink(
          label: 'Forgot your password?',
          onTap: busy ? null : _forgotPassword,
        ),
        _MutedLink(
          label: 'Email me a link instead',
          onTap: busy ? null : _sendLink,
        ),
      ],
    );
  }

  /// The error or notice line, or null when there is neither. An error wins:
  /// the two are set as a pair (one always cleared with the other), so this
  /// only orders them when a later failure lands on an earlier success.
  Widget? _message(BuildContext context) {
    final text = _error ?? _notice;
    if (text == null) return null;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AbTokens.space8),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: _error != null
                ? context.antgrid.error
                : context.antgrid.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _verifyEmailBody(BuildContext context) {
    final antgrid = context.antgrid;
    final email = _emailController.text.trim();
    // Only a failed send sets `_error` on this screen, and every send clears it
    // first — so this reads as "the last send failed", which is what keeps the
    // claim below from asserting a link the user is never going to get.
    final sent = _error == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          'Check the inbox for $email. If this address is eligible, a link will arrive. It expires in one hour. Check your spam folder. '
          '${sent ? ' Verification was requested.' : ''}',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        ?_message(context),
        const SizedBox(height: AbTokens.space16),
        // The password is still in the field behind this screen, so verifying
        // and coming back costs one tap. If the OS killed the app during the
        // detour it is simply gone, and the user signs in normally — it is
        // never persisted anywhere.
        if (_passwordController.text.isNotEmpty)
          _SignInButton(
            label: "I've verified — sign in",
            onPressed: () {
              _goToStep(_Step.password);
              unawaited(_signInWithPassword());
            },
            variant: _SignInButtonVariant.primary,
          ),
        const SizedBox(height: AbTokens.space8),
        _MutedLink(
          label: _resendSecondsLeft > 0
              ? 'Resend the link (${_resendSecondsLeft}s)'
              : 'Resend the link',
          onTap: _resendSecondsLeft > 0 ? null : _resendVerification,
        ),
        _MutedLink(label: 'Use a different email', onTap: _backToForm),
      ],
    );
  }

  Widget _resetSentBody(BuildContext context) {
    final antgrid = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          // Enumeration-safe on the server, so the copy has to be too: it
          // answers a known and an unknown address identically.
          'If that address has an Antgrid account, a reset link is on its way. '
          'The link expires in one hour and opens in your browser.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        _SignInButton(
          label: 'Back to sign in',
          onPressed: () => _goToStep(_Step.password),
          variant: _SignInButtonVariant.primary,
        ),
      ],
    );
  }

  Widget _pendingBody(BuildContext context) {
    final antgrid = context.antgrid;
    final email = _emailController.text.trim();
    // A restored ticket can arrive without its address (older schema), and
    // there is nothing to re-send to then.
    final canResend = _resendSecondsLeft == 0 && _looksLikeEmail(email);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          'Approve the sign-in link sent to\n$email\n'
          // Straight from the window the server actually enforces, so the two
          // can never disagree about how long the user has.
          'The link expires in ${kMagicLinkWindow.inMinutes} minutes.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        const AbLoading(),
        ?_message(context),
        const SizedBox(height: AbTokens.space16),
        _MutedLink(
          label: _resendSecondsLeft > 0
              ? 'Resend the link (${_resendSecondsLeft}s)'
              : 'Resend the link',
          onTap: canResend ? _resendLink : null,
        ),
        _MutedLink(label: 'Use a different email', onTap: _backToForm),
      ],
    );
  }

  Widget _expiredBody(BuildContext context) {
    final antgrid = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Link expired',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          'That sign-in link is no longer valid.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        _SignInButton(
          label: 'Send a new link',
          onPressed: _sendLink,
          variant: _SignInButtonVariant.primary,
        ),
        const SizedBox(height: AbTokens.space8),
        _MutedLink(label: 'Use a different email', onTap: _backToForm),
      ],
    );
  }

  Widget _bouncedBody(BuildContext context) {
    final antgrid = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Email bounced',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: antgrid.textPrimary),
        ),
        const SizedBox(height: AbTokens.space8),
        Text(
          "We couldn't deliver the link to\n${_emailController.text.trim()}.\nCheck the address and try again.",
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        _SignInButton(
          label: 'Use a different email',
          onPressed: _backToForm,
          variant: _SignInButtonVariant.primary,
        ),
      ],
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final line = Expanded(
      child: Container(height: 1, color: antgrid.borderSubtle),
    );
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
          child: Text(
            'or',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: antgrid.textMuted,
            ),
          ),
        ),
        line,
      ],
    );
  }
}

class _MutedLink extends StatefulWidget {
  const _MutedLink({required this.label, required this.onTap});
  final String label;

  /// Null renders the disabled state (opacity 0.4, no interaction), per the
  /// design system's disabled contract.
  final VoidCallback? onTap;

  @override
  State<_MutedLink> createState() => _MutedLinkState();
}

class _MutedLinkState extends State<_MutedLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final onTap = widget.onTap;
    if (onTap == null) {
      return Opacity(
        opacity: 0.4,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: AbTokens.sansStyle(
              color: antgrid.textMuted,
              fontSize: AbTokens.fontXs,
            ),
          ),
        ),
      );
    }
    return MergeSemantics(
      child: Semantics(
        link: true,
        enabled: true,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) {
            if (_focused != v) setState(() => _focused = v);
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: onTap,
            child: AbFocusRing(
              focused: _focused,
              borderRadius: AbTokens.borderRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
                child: Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: AbTokens.sansStyle(
                    color: antgrid.textMuted,
                    fontSize: AbTokens.fontXs,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Emphasis for [_SignInButton], mirroring [AbButtonVariant] so there is one
/// mental model for "this is the way through" across the app.
enum _SignInButtonVariant {
  /// Surface fill, 1px border. Every secondary action on the screen.
  normal,

  /// Accent fill. At most ONE per phase — the accent is what tells the primary
  /// action apart from its neighbours, and a second one spends that for
  /// nothing.
  primary,
}

class _SignInButton extends StatefulWidget {
  const _SignInButton({
    required this.label,
    required this.onPressed,
    this.variant = _SignInButtonVariant.normal,
    this.leading,
    this.appleInk = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final _SignInButtonVariant variant;

  /// A mark before the label, drawn in the label's colour.
  final Widget Function(Color color)? leading;

  /// Draws the label and mark in pure black or white, whichever contrasts
  /// with the fill behind them, as Apple requires of a Sign in with Apple
  /// button. Decided from the fill rather than a light/dark flag because
  /// custom themes can put any colour there.
  final bool appleInk;

  @override
  State<_SignInButton> createState() => _SignInButtonState();
}

class _SignInButtonState extends State<_SignInButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final enabled = widget.onPressed != null;
    final isPrimary = widget.variant == _SignInButtonVariant.primary;
    final fill = isPrimary
        ? (_hovered ? antgrid.accentHighlight : antgrid.accent)
        : (_hovered ? antgrid.bgElevated : antgrid.bgSurface);
    final foreground = widget.appleInk
        ? (fill.computeLuminance() > 0.5
              ? AbTokens.appleSignInInkOnLight
              : AbTokens.appleSignInInkOnDark)
        : isPrimary
        ? antgrid.accentForeground
        : antgrid.textPrimary;
    final visual = Container(
      constraints: BoxConstraints(minHeight: AbTouchSizing.extentOf(context)),
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space10),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(
          color: isPrimary ? antgrid.accent : antgrid.borderDefault,
        ),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.leading case final leading?) ...[
            leading(foreground),
            const SizedBox(width: AbTokens.space6),
          ],
          Flexible(
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              style: AbTokens.sansStyle(color: foreground),
            ),
          ),
        ],
      ),
    );
    if (!enabled) {
      return Semantics(
        button: true,
        enabled: false,
        child: Opacity(opacity: 0.4, child: visual),
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: true,
        onTap: widget.onPressed,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) {
            if (_focused != v) setState(() => _focused = v);
          },
          onShowHoverHighlight: (v) {
            if (_hovered != v) setState(() => _hovered = v);
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: widget.onPressed,
            child: AbFocusRing(
              focused: _focused,
              borderRadius: AbTokens.borderRadius5,
              child: visual,
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple Icons `google` (CC0), inlined as a `currentColor` SVG string for the
/// same reason [AbAgentMarks] inlines its marks: it renders through [AbIcon] on
/// the same path as every other glyph, with one tinting rule and no asset
/// manifest to keep in sync. It lives here rather than in [AbIcons] because
/// that file is the choke point for UI *affordance* icons and this is a
/// third-party brand mark — the same line [AbAgentMarks] draws. GitHub needs no
/// equivalent; Codicons ship one.
const String _googleMark =
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
    'viewBox="0 0 24 24"><path fill="currentColor" d="M12.48 10.92v3.28h7.84'
    'c-.24 1.84-.853 3.187-1.787 4.133c-1.147 1.147-2.933 2.4-6.053 2.4'
    'c-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 '
    '2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0C5.867 0 .307 5.387.307 12'
    's5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36c2.16-2.16 2.84-5.213 '
    '2.84-7.667c0-.76-.053-1.467-.173-2.053z"/></svg>';

/// Apple's logo artwork, sized to sit beside a [_SignInButton] title.
///
/// Sign in with Apple is a full-width outlined [_SignInButton] rather than a
/// cell in [_AuthMethodRow]: Apple's guidelines want its title spelled out,
/// and it may be no less prominent than the other providers. It is not the
/// plugin's `SignInWithAppleButton`, whose solid black or white fill competed
/// with the primary Continue button.
class _AppleMark extends StatelessWidget {
  const _AppleMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: AbTokens.fontBody * 25 / 31,
    height: AbTokens.fontBody,
    child: CustomPaint(painter: AppleLogoPainter(color: color)),
  );
}

/// One way to prove the address is yours, as rendered by [_AuthMethodRow].
class _AuthMethodSpec {
  const _AuthMethodSpec({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// Iconify SVG: an [AbIcons] constant, or an inlined brand mark.
  final String icon;
  final String label;

  /// Null disables the cell. The whole row disables together — only
  /// [_Phase.submitting] ever does it — so the group dims as one object.
  final VoidCallback? onTap;
}

/// The step-1 method group: one bordered box, one cell per method.
///
/// Built like [AbSegmented] — outer border, [ClipRRect], 1px dividers stretched
/// by [IntrinsicHeight], inset focus rings — because it has to read as a single
/// control answering a single question. Deliberately NOT an [AbSegmented]: a
/// cell here fires an action, and a selected state would promise a choice that
/// persists.
class _AuthMethodRow extends StatelessWidget {
  const _AuthMethodRow({required this.methods});

  final List<_AuthMethodSpec> methods;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: antgrid.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: ClipRRect(
        borderRadius: AbTokens.borderRadius5,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < methods.length; i++) ...[
                if (i > 0) Container(width: 1, color: antgrid.borderDefault),
                Expanded(child: _AuthMethodCell(spec: methods[i])),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthMethodCell extends StatefulWidget {
  const _AuthMethodCell({required this.spec});

  final _AuthMethodSpec spec;

  @override
  State<_AuthMethodCell> createState() => _AuthMethodCellState();
}

class _AuthMethodCellState extends State<_AuthMethodCell> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final onTap = widget.spec.onTap;
    final fg = _hovered ? antgrid.textPrimary : antgrid.textSecondary;

    final visual = AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      color: _hovered ? antgrid.bgElevated : antgrid.bgSurface,
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbIcon(widget.spec.icon, size: 16, color: fg),
          const SizedBox(height: AbTokens.space6),
          Text(
            widget.spec.label,
            style: AbTokens.sansStyle(fontSize: AbTokens.fontXs, color: fg),
          ),
        ],
      ),
    );

    if (onTap == null) return Opacity(opacity: 0.4, child: visual);
    return Semantics(
      button: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            // The cell sits under the group's ClipRRect; the default outset
            // ring would be clipped away entirely.
            inset: true,
            borderRadius: AbTokens.borderRadius5,
            child: visual,
          ),
        ),
      ),
    );
  }
}

/// The offline demo, filed as a destination rather than a credential.
///
/// Outlined on the page ground instead of filled like the controls above it, so
/// at rest it is the one element on the screen that does not look like a button
/// — which is what lets it stay prominent without competing with Continue. It
/// is also the only left-aligned, two-line thing here, so the caveat travels
/// with the offer instead of floating under it as an orphan line.
class _DemoCard extends StatefulWidget {
  const _DemoCard({required this.onTap});

  final VoidCallback? onTap;

  @override
  State<_DemoCard> createState() => _DemoCardState();
}

class _DemoCardState extends State<_DemoCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final onTap = widget.onTap;

    final visual = AnimatedContainer(
      duration: AbTokens.motionDefault,
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space10,
      ),
      decoration: BoxDecoration(
        color: _hovered ? antgrid.bgSurface : antgrid.bgDeep,
        border: Border.all(color: antgrid.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kDemoEntryLabel,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontMd,
                    color: antgrid.textPrimary,
                  ),
                ),
                const SizedBox(height: AbTokens.space2),
                Text(
                  'No account needed. Try every screen on a built-in project.',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: antgrid.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          AbIcon(
            AbIcons.send,
            size: 14,
            color: _hovered ? antgrid.textSecondary : antgrid.textMuted,
          ),
        ],
      ),
    );

    if (onTap == null) return Opacity(opacity: 0.4, child: visual);
    return Semantics(
      button: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onShowFocusHighlight: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AbFocusRing(
            focused: _focused,
            borderRadius: AbTokens.borderRadius5,
            child: visual,
          ),
        ),
      ),
    );
  }
}
