import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../demo/demo_identity.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_brand_mark.dart';
import '../design/widgets/ab_focus_ring.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_password_field.dart';
import '../design/widgets/ab_text_field.dart';
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
/// entirely over HTTPS — no browser, no deeplink. GitHub/Google remain as
/// secondary options on the existing browser+deeplink path.
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
enum _Step { email, password }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  static const _pollInterval = Duration(seconds: 3);
  // ~11 minutes at the 3s interval — backstops the server's 10-min link
  // window so an unreachable server doesn't poll forever.
  static const _maxPollTicks = 220;

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
  int _pollTicks = 0;
  StreamSubscription<String>? _oauthFailureSub;

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

  @override
  void initState() {
    super.initState();
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
  void dispose() {
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
    if (!mounted || _phase != _Phase.form) return;
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

  Future<void> _startOAuth(String provider) async {
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInStarted, props: {'provider': provider});
    final email = _emailController.text.trim();
    // Captured up front: the hint below is written after the await, and the
    // browser detour can outlive this widget — a `ref` touched then throws.
    final store = ref.read(lastAuthMethodStoreProvider);
    final auth = ref.read(authServiceProvider);
    // Back to the form even if Continue routed us here from [_Phase.submitting]:
    // OAuth's outcome arrives as a deep link much later, and [_onOAuthFailure]
    // only shows itself on the form.
    setState(() {
      _phase = _Phase.form;
      _error = null;
    });
    try {
      await auth.startOAuth(provider);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      return;
    }
    // Only once the browser is actually up: written before the launch, the hint
    // outlives a launch that never happened and then routes every later
    // Continue back to a provider that has never worked. It still records the
    // TYPED address, not whichever one the user authenticates as — the callback
    // deep link carries none — so a hint can still land wrong. What keeps that
    // survivable is "Continue with a password": it reaches step 2 whatever the
    // hint says, and step 2 carries the link.
    _remember(
      email,
      provider == 'github' ? AuthMethod.github : AuthMethod.google,
      store: store,
    );
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
    // The ticket carries no send time, so the conservative reading is that the
    // link just went out — better one 45s wait than a resend burst on relaunch.
    _startResendCooldown();
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
        await _startOAuth('github');
      case AuthMethod.google:
        await _startOAuth('google');
      // A remembered link, and an address this device has never seen, take the
      // same path — the link is what works without knowing anything.
      case AuthMethod.link:
      case null:
        await _sendLink();
    }
  }

  /// Starts a magic link for [email]. Every ref read happens before the await
  /// so nothing here depends on the widget outliving the request; the caller
  /// owns the mounted check and the UI transition.
  Future<MagicLinkSession> _startMagicLink(String email) {
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
    return auth.startMagicLink(email);
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
      _startResendCooldown();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
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
    if (_resendSecondsLeft > 0) return;
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
    try {
      final session = await _startMagicLink(email);
      if (!mounted) return;
      if (_flowGeneration != generation || _phase != _Phase.pending) {
        // The user abandoned this link while the send was in the air.
        // [AuthService.startMagicLink] persists its ticket before returning, so
        // it landed AFTER [_backToForm]'s discard; left there it would restore
        // the abandoned address on the next launch. This can also drop a ticket
        // a newer send just wrote, which costs that flow only its
        // relaunch-restore — its in-memory session still polls to completion.
        unawaited(ref.read(authServiceProvider).discardPendingMagicLink());
        return;
      }
      setState(() {
        _session = session;
        // Confirms the REQUEST — the server answers identically whether or not
        // it had somewhere to send to, and we cannot vouch for delivery.
        _notice = 'Sent. Check your inbox again in a moment.';
      });
      _startPolling();
    } on AuthException catch (e) {
      if (!mounted ||
          _flowGeneration != generation ||
          _phase != _Phase.pending) {
        return;
      }
      setState(() => _error = e.message);
    }
  }

  void _startResendCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendSecondsLeft = _resendCooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Only the two screens carrying a resend show this counting down, so a
      // flow that has moved on — approved, expired, bounced — must not keep
      // rebuilding once a second for the rest of the window.
      if (!mounted ||
          (_phase != _Phase.pending && _phase != _Phase.verifyEmail)) {
        timer.cancel();
        _cooldownTimer = null;
        return;
      }
      setState(() => _resendSecondsLeft--);
      if (_resendSecondsLeft <= 0) {
        timer.cancel();
        _cooldownTimer = null;
      }
    });
  }

  void _goToStep(_Step step) {
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
        ref
            .read(analyticsServiceProvider)
            ?.track(AnalyticsEvents.signInCompleted);
        // Cookie already persisted by the service. Same warm-up as the
        // magic-link ready path so pricing is ready when the shell opens.
        ref.invalidate(currentUserProvider);
        ref.invalidate(subscriptionProvider);
        ref.invalidate(pricingCatalogProvider);
        prefetchSubscriptionCache(ref);
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
          await ref.read(authServiceProvider).sendVerificationEmail(email);
          if (!mounted) return;
          // This screen IS the landing after that send, so the resend beneath
          // it starts its clock here rather than offering an instant retry of
          // mail that has not had time to arrive.
          _startResendCooldown();
        } on AuthException catch (e) {
          if (!mounted) return;
          // Handled here rather than left to `_submitPassword`: the sign-in
          // reached a verdict, so bouncing back to the form would throw away
          // a correct password over a failed follow-up send. The resend
          // button on this screen is the retry.
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
      await ref.read(authServiceProvider).sendVerificationEmail(email);
      if (abandoned()) return;
      // The server answers identically whether or not it sent anything, so
      // this confirms the REQUEST, not a delivery we cannot vouch for.
      setState(() => _notice = 'Sent. Check your inbox again in a moment.');
    } on AuthException catch (e) {
      if (abandoned()) return;
      setState(() => _error = e.message);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTicks = 0;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final session = _session;
    if (session == null || _polling) return;
    // Client-side backstop: once the link window has lapsed, stop polling
    // and surface the expired state even if the server is unreachable
    // (which would otherwise return MagicLinkStatus.error forever).
    _pollTicks++;
    if (_pollTicks > _maxPollTicks) {
      _pollTimer?.cancel();
      if (mounted) setState(() => _phase = _Phase.expired);
      return;
    }
    _polling = true;
    try {
      final poll = await ref.read(authServiceProvider).pollStatus(session);
      // Drop a response whose session was replaced while it was in flight
      // (user tapped "Use a different email" or started a new link): the timer
      // was cancelled but this future was already awaiting, so without this
      // guard a stale result would snap the UI to bounced or sign in on an
      // abandoned flow.
      if (!mounted || !identical(_session, session)) return;

      // A hard bounce means the link will never arrive — stop polling and tell
      // the user. ZeptoMail reports no "delivered" event, so there is no success
      // signal; we just keep waiting for approval until then.
      if (poll.delivery == DeliveryStatus.bounced) {
        _pollTimer?.cancel();
        unawaited(ref.read(authServiceProvider).discardPendingMagicLink());
        setState(() => _phase = _Phase.bounced);
        return;
      }

      switch (poll.status) {
        case MagicLinkStatus.ready:
          _pollTimer?.cancel();
          ref
              .read(analyticsServiceProvider)
              ?.track(AnalyticsEvents.signInCompleted);
          // Cookie already persisted by pollStatus. Warm billing in parallel
          // with the user refresh so pricing is ready as soon as the shell opens.
          ref.invalidate(currentUserProvider);
          ref.invalidate(subscriptionProvider);
          ref.invalidate(pricingCatalogProvider);
          prefetchSubscriptionCache(ref);
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
    } finally {
      _polling = false;
    }
  }

  void _backToForm() {
    _pollTimer?.cancel();
    _pollTicks = 0;
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
          ],
        ),
      ),
    );
  }

  Widget _formBody(BuildContext context, bool canPop) => switch (_step) {
    _Step.email => _emailStepBody(context, canPop),
    _Step.password => _passwordStepBody(context),
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
        // One bordered group rather than three stacked buttons: these are three
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
              onTap: busy ? null : () => _startOAuth('github'),
            ),
            _AuthMethodSpec(
              icon: _googleMark,
              label: 'Google',
              onTap: busy ? null : () => _startOAuth('google'),
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

  /// Step 2. The address is settled, so it reads as text rather than an input;
  /// "change" is the only way back. Every exit stays open — reset, and the
  /// magic link, which is also the answer for an account whose password was
  /// never set (the case INVALID_EMAIL_OR_PASSWORD refuses to distinguish).
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
    return Padding(
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
          'Your password is correct, but\n$email\nhasn\'t been verified '
          'yet.${sent ? ' We sent a fresh link.' : ''}',
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
    return FocusableActionDetector(
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
  });
  final String label;
  final VoidCallback? onPressed;
  final _SignInButtonVariant variant;

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
    final visual = Container(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space10),
      decoration: BoxDecoration(
        color: isPrimary
            ? (_hovered ? antgrid.accentHighlight : antgrid.accent)
            : (_hovered ? antgrid.bgElevated : antgrid.bgSurface),
        border: Border.all(
          color: isPrimary ? antgrid.accent : antgrid.borderDefault,
        ),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Text(
        widget.label,
        textAlign: TextAlign.center,
        style: AbTokens.sansStyle(
          color: isPrimary ? antgrid.accentForeground : antgrid.textPrimary,
        ),
      ),
    );
    if (!enabled) return Opacity(opacity: 0.4, child: visual);
    return FocusableActionDetector(
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
                  'No account needed. Sample data, nothing is connected.',
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
