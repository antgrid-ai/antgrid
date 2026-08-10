import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_window_controls.dart';
import '../window/window_capabilities.dart';
import 'window_title_bar.dart';

/// Neutral splash shown while sign-in state is unknown (cold start before
/// `currentUserProvider` resolves and no cached cookie was observed). Renders
/// in the design-system theme so there's no flash to a contrasting palette.
class AuthSplash extends StatelessWidget {
  const AuthSplash({super.key});

  @override
  Widget build(BuildContext context) {
    // MediaQuery.disableAnimations is the design system's single reduce-motion
    // distribution point (OS flag OR the in-app toggle — see AbApp).
    final fadeDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AbTokens.motionSettle;
    final splash = Center(
      // Ease the wordmark in and pulse a cursor below it: this screen can hold
      // for seconds on a cold network start, and a static popped-in frame
      // reads as frozen.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: fadeDuration,
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/logo/antgrid-wordmark.svg',
              height: AbTokens.space16 * 4.5,
              semanticsLabel: 'antgrid',
            ),
            const SizedBox(height: AbTokens.space16),
            const AbLoading(),
          ],
        ),
      ),
    );
    return Scaffold(
      body: appOwnsWindowChrome
          // The OS bar is already hidden by the time the first frame lands, so
          // even this pre-auth screen needs somewhere to drag from and a close
          // button — resolving the session can stall on a slow network. Bare
          // chrome only: the data-bearing contents watch project providers
          // that have no meaning before sign-in resolves.
          ? Column(
              children: [
                const WindowTitleBar(
                  child: Row(children: [Spacer(), AbWindowControls()]),
                ),
                Expanded(child: splash),
              ],
            )
          : splash,
    );
  }
}
