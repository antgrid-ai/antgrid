import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/screens/sign_in_screen.dart';
import 'package:antgrid/services/auth_service.dart';

/// Secure storage whose pending-ticket read is held open until the test
/// releases it, so a restore can be raced against user input the way a slow
/// keychain read is on a cold Android start.
class _GatedStorage implements AuthStorage {
  _GatedStorage(this._pending);
  String? _pending;
  final gate = Completer<void>();

  @override
  Future<String?> readPendingSignIn() async {
    await gate.future;
    return _pending;
  }

  @override
  Future<void> writePendingSignIn(String v) async => _pending = v;
  @override
  Future<void> clearPendingSignIn() async => _pending = null;
  @override
  Future<String?> readCookie() async => null;
  @override
  Future<void> writeCookie(String v) async {}
  @override
  Future<void> clearCookie() async {}
}

String _ticket({required String email}) => jsonEncode({
  'id': 'row-123',
  'bindCookie': 'row-123.tok',
  'email': email,
  'startedAt': DateTime.now().toUtc().toIso8601String(),
});

AuthService _authFor(AuthStorage storage) => AuthService(
  licenseApiUrl: 'https://lic.test',
  storage: storage,
  // Any poll a restore kicks off parks on pending — the test is about what
  // the screen does with the ticket, not the round-trip.
  httpClient: MockClient(
    (_) async => http.Response(jsonEncode({'status': 'pending'}), 200),
  ),
  // The default launcher is the REAL url_launcher Dart plugin on desktop
  // `flutter test`, which would open an actual browser on the test machine.
  launchUrl: (_) async => false,
);

Widget _wrap(AuthStorage storage) => _wrapService(_authFor(storage));

Widget _wrapService(AuthService auth) {
  return ProviderScope(
    overrides: [authServiceProvider.overrideWithValue(auth)],
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: const SignInScreen(),
    ),
  );
}

void main() {
  testWidgets('a restored ticket does not clobber an email being typed', (
    tester,
  ) async {
    final storage = _GatedStorage(_ticket(email: 'old@example.com'));
    await tester.pumpWidget(_wrap(storage));

    // The keychain read is still in flight; the user starts over by hand.
    await tester.enterText(find.byType(TextField), 'new@example.com');
    await tester.pump();

    storage.gate.complete();
    await tester.pump();
    await tester.pump();

    expect(
      find.text('new@example.com'),
      findsOneWidget,
      reason: 'typed email survives a late restore',
    );
    expect(
      find.text('Check your email'),
      findsNothing,
      reason: 'the screen stays on the form the user is filling in',
    );
  });

  testWidgets('a restored ticket resumes an untouched sign-in screen', (
    tester,
  ) async {
    final storage = _GatedStorage(_ticket(email: 'old@example.com'));
    await tester.pumpWidget(_wrap(storage));

    storage.gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('old@example.com'), findsOneWidget);
  });

  testWidgets('a failed browser launch surfaces on the form', (tester) async {
    // The injected launcher reports the browser never opened. Previously the
    // resulting throw vanished into an unawaited callback and the screen never
    // changed.
    final storage = _GatedStorage(null)..gate.complete();
    await tester.pumpWidget(_wrap(storage));

    await tester.tap(find.text('Continue with GitHub'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not open the browser'), findsOneWidget);
  });

  testWidgets('a deep-link OAuth error bounce surfaces on the form', (
    tester,
  ) async {
    final storage = _GatedStorage(null)..gate.complete();
    final auth = _authFor(storage);
    await tester.pumpWidget(_wrapService(auth));

    // The web handoff bounces failures back as ?error= — the screen learns of
    // them only through the service's failure stream.
    await auth.handleDeepLink(
      Uri.parse('antgrid://auth/callback?error=no_session'),
    );
    await tester.pump();

    expect(find.text("Sign-in didn't complete. Try again."), findsOneWidget);
  });

  group('password', () {
    /// Drives the screen to the password form and fills both fields. Returns
    /// the paths every request hit, so a test can assert what the screen asked
    /// the server for as well as what it rendered.
    Future<List<String>> openPasswordForm(
      WidgetTester tester, {
      required Future<http.Response> Function(http.Request) respond,
      String email = 'user@example.com',
      String password = 'a-very-long-password',
      String mode = 'Sign in with a password',
    }) async {
      final paths = <String>[];
      final storage = _GatedStorage(null)..gate.complete();
      await tester.pumpWidget(
        _wrapService(
          AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: MockClient((req) async {
              paths.add(req.url.path);
              return respond(req);
            }),
            launchUrl: (_) async => false,
          ),
        ),
      );
      await tester.tap(find.text(mode));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, email);
      await tester.enterText(find.byType(TextField).last, password);
      await tester.pump();
      return paths;
    }

    testWidgets(
      'the password form is reached from a link, not shown by default',
      (tester) async {
        final storage = _GatedStorage(null)..gate.complete();
        await tester.pumpWidget(_wrap(storage));

        expect(find.byType(TextField), findsOneWidget);
        expect(find.text('Send magic link'), findsOneWidget);

        await tester.tap(find.text('Sign in with a password'));
        await tester.pump();

        expect(find.byType(TextField), findsNWidgets(2));
        expect(find.text('Sign in'), findsOneWidget);
        expect(
          find.text('Send magic link'),
          findsNothing,
          reason: 'the two forms are alternatives, not stacked',
        );
      },
    );

    testWidgets('an unverified sign-in asks for verification and resends', (
      tester,
    ) async {
      final paths = await openPasswordForm(
        tester,
        respond: (req) async =>
            http.Response(jsonEncode({'code': 'EMAIL_NOT_VERIFIED'}), 403),
      );

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('user@example.com'), findsOneWidget);
      // sendOnSignIn is off server-side, so the screen has to ask for the mail
      // itself or the user waits on something that was never sent.
      expect(paths, contains('/api/auth/send-verification-email'));
    });

    testWidgets(
      'a rejected credential shows one message and stays on the form',
      (tester) async {
        await openPasswordForm(
          tester,
          respond: (req) async => http.Response(
            jsonEncode({'code': 'INVALID_EMAIL_OR_PASSWORD'}),
            401,
          ),
        );

        await tester.tap(find.text('Sign in'));
        await tester.pumpAndSettle();

        expect(find.text('Invalid email or password'), findsOneWidget);
        expect(find.byType(TextField), findsNWidgets(2));
      },
    );

    testWidgets('sign-up lands on check-email without claiming the address was '
        'free', (tester) async {
      await openPasswordForm(
        tester,
        mode: 'Sign in with a password',
        respond: (req) async => http.Response(jsonEncode({'user': {}}), 200),
      );
      await tester.tap(find.text('Create an account'));
      await tester.pump();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Check your email'), findsOneWidget);
      expect(
        find.textContaining('Already had an account'),
        findsOneWidget,
        reason: 'sign-up answers a taken address with a synthetic success',
      );
    });

    testWidgets('a short password is refused before any request', (
      tester,
    ) async {
      final paths = await openPasswordForm(
        tester,
        mode: 'Sign in with a password',
        password: 'short',
        respond: (req) async => http.Response('{}', 200),
      );
      await tester.tap(find.text('Create an account'));
      await tester.pump();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(find.textContaining('at least'), findsOneWidget);
      expect(paths, isEmpty);
    });

    testWidgets('forgot-password answers identically for any address', (
      tester,
    ) async {
      final paths = await openPasswordForm(
        tester,
        respond: (req) async =>
            http.Response(jsonEncode({'status': true}), 200),
      );

      await tester.tap(find.text('Forgot your password?'));
      await tester.pumpAndSettle();

      expect(paths, contains('/api/auth/request-password-reset'));
      expect(
        find.textContaining('If that address has an Antgrid account'),
        findsOneWidget,
      );
    });
  });
}
