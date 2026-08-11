import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_focus_ring.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_password_field.dart';
import '../design/widgets/ab_text_field.dart';
import '../project/limits.dart';
import '../analytics/events.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/device_revocation.dart';
import '../providers/subscription.dart';
import '../services/auth_service.dart';

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
/// Magic-link is the primary method: the email form drives the web
/// cross-device flow ([AuthService.startMagicLink] / [AuthService.pollStatus])
/// entirely over HTTPS — no browser, no deeplink. GitHub/Google remain as
/// secondary options on the existing browser+deeplink path. Email + password is
/// secondary too, reached from a link under the form.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

/// What the screen is DOING. Kept separate from [_FormMode], which is what the
/// form is asking for: [pending]/[expired]/[bounced] belong to the magic link
/// alone and [verifyEmail]/[resetSent] to the password paths, and folding the
/// two axes into one enum would put the magic link's restore-and-poll
/// invariants (see [_SignInScreenState._restorePendingSignIn]) on states that
/// have nothing to do with it.
enum _Phase {
  form,
  submitting,
  pending,
  expired,
  bounced,
  verifyEmail,
  resetSent,
}

/// What the form is ASKING FOR. Magic link is the default and stays the primary
/// method; password is reached deliberately, mirroring the web's disclosure.
enum _FormMode { magicLink, password, signUp }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  static const _pollInterval = Duration(seconds: 3);
  // ~11 minutes at the 3s interval — backstops the server's 10-min link
  // window so an unreachable server doesn't poll forever.
  static const _maxPollTicks = 220;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  _Phase _phase = _Phase.form;
  _FormMode _mode = _FormMode.magicLink;
  String? _error;

  /// Non-error status line (a resend landed, a reset went out). Separate from
  /// [_error] so a success message can never be styled as a failure.
  String? _notice;
  MagicLinkSession? _session;
  Timer? _pollTimer;
  bool _polling = false;
  int _pollTicks = 0;
  StreamSubscription<String>? _oauthFailureSub;

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

  Future<void> _startOAuth(String provider) async {
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.signInStarted, props: {'provider': provider});
    setState(() => _error = null);
    try {
      await ref.read(authServiceProvider).startOAuth(provider);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
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
    // part-way through typing, or a switch to one of the password modes — the
    // restored ticket is a MAGIC-LINK sign-in, so resuming it would yank
    // someone out of the form they deliberately opened. A cold-start keychain
    // read can easily outlast the first keystrokes, and clobbering them would
    // swap the field back to a stale address and strand the user on a pending
    // screen they never asked for.
    if (_session != null ||
        _phase != _Phase.form ||
        _mode != _FormMode.magicLink ||
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
  }

  bool _looksLikeEmail(String s) {
    final t = s.trim();
    return t.contains('@') &&
        t.indexOf('@') > 0 &&
        t.indexOf('@') < t.length - 1;
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
      final session = await ref.read(authServiceProvider).startMagicLink(email);
      if (!mounted) return;
      ref
          .read(analyticsServiceProvider)
          ?.track(
            AnalyticsEvents.signInStarted,
            props: {'provider': 'magic_link'},
          );
      setState(() {
        _session = session;
        _phase = _Phase.pending;
      });
      _startPolling();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
      });
    }
  }

  void _setMode(_FormMode mode) {
    setState(() {
      _mode = mode;
      _phase = _Phase.form;
      _error = null;
      _notice = null;
    });
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
    switch (outcome) {
      case PasswordSignIn.ok:
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

  Future<void> _signUpWithPassword() => _submitPassword((email) async {
    final password = _passwordController.text;
    final lengthError = passwordLengthError(password);
    if (lengthError != null) {
      setState(() {
        _phase = _Phase.form;
        _error = lengthError;
      });
      return;
    }
    ref
        .read(analyticsServiceProvider)
        ?.track(
          AnalyticsEvents.signInStarted,
          props: {'provider': 'password_signup'},
        );
    await ref
        .read(authServiceProvider)
        .signUpWithPassword(email: email, password: password);
    if (!mounted) return;
    setState(() => _phase = _Phase.verifyEmail);
  });

  Future<void> _forgotPassword() => _submitPassword((email) async {
    await ref.read(authServiceProvider).requestPasswordReset(email);
    if (!mounted) return;
    setState(() => _phase = _Phase.resetSent);
  });

  Future<void> _resendVerification() async {
    final email = _emailController.text.trim();
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      await ref.read(authServiceProvider).sendVerificationEmail(email);
      if (!mounted) return;
      // The server answers identically whether or not it sent anything, so
      // this confirms the REQUEST, not a delivery we cannot vouch for.
      setState(() => _notice = 'Sent. Check your inbox again in a moment.');
    } on AuthException catch (e) {
      if (!mounted) return;
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
    unawaited(ref.read(authServiceProvider).discardPendingMagicLink());
    setState(() {
      _phase = _Phase.form;
      _session = null;
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
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SvgPicture.asset(
                      'assets/logo/antgrid-wordmark.svg',
                      height: AbTokens.space16 * 4,
                      semanticsLabel: 'antgrid',
                    ),
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
          ],
        ),
      ),
    );
  }

  Widget _formBody(BuildContext context, bool canPop) {
    final busy = _phase == _Phase.submitting;
    final isSignUp = _mode == _FormMode.signUp;
    final wantsPassword = _mode != _FormMode.magicLink;
    final submit = switch (_mode) {
      _FormMode.magicLink => _sendLink,
      _FormMode.password => _signInWithPassword,
      _FormMode.signUp => _signUpWithPassword,
    };
    final busyLabel = switch (_mode) {
      _FormMode.magicLink => 'Sending…',
      _FormMode.password => 'Signing in…',
      _FormMode.signUp => 'Creating…',
    };
    final label = switch (_mode) {
      _FormMode.magicLink => 'Send magic link',
      _FormMode.password => 'Sign in',
      _FormMode.signUp => 'Create account',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isSignUp ? 'Create your account' : 'Sign in to continue',
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
          // With a password below, Enter should reach it rather than submit a
          // half-filled form.
          textInputAction: wantsPassword
              ? TextInputAction.next
              : TextInputAction.go,
          onSubmitted: wantsPassword ? null : (_) => busy ? null : _sendLink(),
        ),
        if (wantsPassword) ...[
          const SizedBox(height: AbTokens.space8),
          AbPasswordField(
            controller: _passwordController,
            hintText: isSignUp
                ? 'At least $kMinPasswordLength characters'
                : 'Password',
            enabled: !busy,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => busy ? null : submit(),
          ),
        ],
        ?_message(context),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: busy ? busyLabel : label,
          onPressed: busy ? null : submit,
        ),
        const SizedBox(height: AbTokens.space8),
        ..._modeLinks(busy),
        const SizedBox(height: AbTokens.space8),
        const _OrDivider(),
        const SizedBox(height: AbTokens.space16),
        _SignInButton(
          label: 'Continue with GitHub',
          onPressed: () => _startOAuth('github'),
        ),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: 'Continue with Google',
          onPressed: () => _startOAuth('google'),
        ),
        if (canPop && !isMobilePlatform) ...[
          const SizedBox(height: AbTokens.space16),
          _MutedLink(
            label: 'Continue without signing in',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ],
    );
  }

  /// The links under the primary button. Each mode offers exactly the ways out
  /// of it, so no mode is a dead end: password reaches reset and sign-up,
  /// sign-up reaches sign-in, and both can fall back to the magic link — which
  /// is also the answer for an account that has no password at all, the case
  /// INVALID_EMAIL_OR_PASSWORD deliberately refuses to distinguish.
  List<Widget> _modeLinks(bool busy) {
    switch (_mode) {
      case _FormMode.magicLink:
        return [
          _MutedLink(
            label: 'Sign in with a password',
            onTap: () => _setMode(_FormMode.password),
          ),
        ];
      case _FormMode.password:
        return [
          _MutedLink(
            label: 'Forgot your password?',
            onTap: busy ? null : _forgotPassword,
          ),
          _MutedLink(
            label: 'Create an account',
            onTap: () => _setMode(_FormMode.signUp),
          ),
          _MutedLink(
            label: 'Use a magic link instead',
            onTap: () => _setMode(_FormMode.magicLink),
          ),
        ];
      case _FormMode.signUp:
        return [
          _MutedLink(
            label: 'Already have an account? Sign in',
            onTap: () => _setMode(_FormMode.password),
          ),
          _MutedLink(
            label: 'Use a magic link instead',
            onTap: () => _setMode(_FormMode.magicLink),
          ),
        ];
    }
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
    final fromSignUp = _mode == _FormMode.signUp;
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
          fromSignUp
              ? 'Open the verification link sent to\n$email\nto finish creating '
                    "your account — you can't sign in until you do."
              : 'Your password is correct, but\n$email\nhasn\'t been verified '
                    'yet.${sent ? ' We sent a fresh link.' : ''}',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        // Sign-up answers an address that already has an account with a
        // synthetic success and sends nothing, so that it cannot be used to
        // enumerate users. That user is otherwise left waiting on mail that
        // will never arrive — say so without claiming which case they are in.
        if (fromSignUp) ...[
          const SizedBox(height: AbTokens.space8),
          Text(
            'Already had an account with this address? Nothing was sent — sign '
            'in instead.',
            textAlign: TextAlign.center,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: antgrid.textMuted,
            ),
          ),
        ],
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
              _setMode(_FormMode.password);
              unawaited(_signInWithPassword());
            },
          ),
        const SizedBox(height: AbTokens.space8),
        _MutedLink(label: 'Resend the link', onTap: _resendVerification),
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
          onPressed: () => _setMode(_FormMode.password),
        ),
      ],
    );
  }

  Widget _pendingBody(BuildContext context) {
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
          'Approve the sign-in link sent to\n${_emailController.text.trim()}',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: antgrid.textMuted,
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        const AbLoading(),
        const SizedBox(height: AbTokens.space16),
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
        _SignInButton(label: 'Send a new link', onPressed: _sendLink),
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
        _SignInButton(label: 'Use a different email', onPressed: _backToForm),
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
            'or continue with',
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

class _SignInButton extends StatefulWidget {
  const _SignInButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

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
    final visual = Container(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space10),
      decoration: BoxDecoration(
        color: _hovered ? antgrid.bgElevated : antgrid.bgSurface,
        border: Border.all(color: antgrid.borderDefault),
        borderRadius: AbTokens.borderRadius,
      ),
      child: Text(
        widget.label,
        textAlign: TextAlign.center,
        style: AbTokens.sansStyle(color: antgrid.textPrimary),
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
          borderRadius: AbTokens.borderRadius,
          child: visual,
        ),
      ),
    );
  }
}
