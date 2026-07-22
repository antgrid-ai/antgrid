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
import '../design/widgets/ab_text_field.dart';
import '../project/limits.dart';
import '../analytics/events.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
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
/// secondary options on the existing browser+deeplink path.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

enum _Phase { form, submitting, pending, expired, bounced }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  static const _pollInterval = Duration(seconds: 3);
  // ~11 minutes at the 3s interval — backstops the server's 10-min link
  // window so an unreachable server doesn't poll forever.
  static const _maxPollTicks = 220;

  final _emailController = TextEditingController();
  _Phase _phase = _Phase.form;
  String? _error;
  MagicLinkSession? _session;
  Timer? _pollTimer;
  bool _polling = false;
  int _pollTicks = 0;

  @override
  void initState() {
    super.initState();
    _restorePendingSignIn();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _emailController.dispose();
    super.dispose();
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
    // (_session set, or _phase moved off the form) or an address they are
    // part-way through typing. A cold-start keychain read can easily outlast
    // the first keystrokes, and clobbering them would swap the field back to a
    // stale address and strand the user on a pending screen they never asked
    // for.
    if (_session != null ||
        _phase != _Phase.form ||
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final canPop = Navigator.of(context).canPop();

    ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
      final user = next.value;
      if (user != null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
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
                    if (_phase == _Phase.pending)
                      _pendingBody(context)
                    else if (_phase == _Phase.bounced)
                      _bouncedBody(context)
                    else if (_phase == _Phase.expired)
                      _expiredBody(context)
                    else
                      _formBody(context, canPop),
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
    final antgrid = context.antgrid;
    final auth = ref.read(authServiceProvider);
    final busy = _phase == _Phase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in to continue',
          textAlign: TextAlign.center,
          style: AbTokens.monoStyle(color: antgrid.textMuted),
        ),
        const SizedBox(height: AbTokens.space16),
        AbTextField(
          controller: _emailController,
          hintText: 'you@example.com',
          height: AbTokens.rowHeightLg,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => busy ? null : _sendLink(),
        ),
        if (_error != null) ...[
          const SizedBox(height: AbTokens.space8),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: antgrid.error,
            ),
          ),
        ],
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: busy ? 'Sending…' : 'Send magic link',
          onPressed: busy ? null : _sendLink,
        ),
        const SizedBox(height: AbTokens.space16),
        const _OrDivider(),
        const SizedBox(height: AbTokens.space16),
        _SignInButton(
          label: 'Continue with GitHub',
          onPressed: () {
            ref
                .read(analyticsServiceProvider)
                ?.track(
                  AnalyticsEvents.signInStarted,
                  props: {'provider': 'github'},
                );
            auth.startOAuth('github');
          },
        ),
        const SizedBox(height: AbTokens.space8),
        _SignInButton(
          label: 'Continue with Google',
          onPressed: () {
            ref
                .read(analyticsServiceProvider)
                ?.track(
                  AnalyticsEvents.signInStarted,
                  props: {'provider': 'google'},
                );
            auth.startOAuth('google');
          },
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

  Widget _pendingBody(BuildContext context) {
    final antgrid = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: AbTokens.monoStyle(color: antgrid.textPrimary),
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
          style: AbTokens.monoStyle(color: antgrid.textPrimary),
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
          style: AbTokens.monoStyle(color: antgrid.textPrimary),
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
              color: antgrid.textDisabled,
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
  final VoidCallback onTap;

  @override
  State<_MutedLink> createState() => _MutedLinkState();
}

class _MutedLinkState extends State<_MutedLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AbFocusRing(
          focused: _focused,
          borderRadius: AbTokens.borderRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              style: AbTokens.monoStyle(
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
        style: AbTokens.monoStyle(color: antgrid.textPrimary),
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
