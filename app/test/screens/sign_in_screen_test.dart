import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_password_field.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/screens/sign_in_screen.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/storage/last_auth_method_store.dart';

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

  /// What a relaunch would restore. The only place a write racing a discard is
  /// visible, since neither shows on screen.
  String? get pending => _pending;

  @override
  Future<String?> readCookie() async => null;
  @override
  Future<void> writeCookie(String v) async {}
  @override
  Future<void> clearCookie() async {}
}

/// In-memory hint store. Faked rather than driven through prefs because the
/// hint is the ONLY input to the screen's step routing, so a test needs to read
/// back exactly what a commit wrote — and the enumeration-safety rule these
/// tests exist to pin ("no server lookup") is only visible when the hint is the
/// one thing that varies.
class _FakeAuthMethodStore extends LastAuthMethodStore {
  _FakeAuthMethodStore([Map<String, AuthMethod>? seed])
    : memory = <String, AuthMethod>{...?seed};

  final Map<String, AuthMethod> memory;

  @override
  Future<AuthMethod?> recall(String email) async => memory[_key(email)];

  @override
  Future<void> remember(String email, AuthMethod method) async {
    memory[_key(email)] = method;
  }

  /// Mirrors the real store's normalization so a differently-cased address
  /// recalls what it recorded.
  static String _key(String email) => email.trim().toLowerCase();
}

String _ticket({required String email}) => jsonEncode({
  'id': 'row-123',
  'bindCookie': 'row-123.tok',
  'email': email,
  'startedAt': DateTime.now().toUtc().toIso8601String(),
});

const _startPath = '/api/auth/sign-in/cross-device/start';
const _statusPath = '/api/auth/sign-in/cross-device/status';

/// A server that starts links and parks every poll on pending. The bind cookie
/// has to come back on the `Set-Cookie` header or [AuthService.startMagicLink]
/// rejects the response.
Future<http.Response> _magicLinkServer(http.Request req) async {
  if (req.url.path == _startPath) {
    return http.Response(
      jsonEncode({'id': 'row-1'}),
      200,
      headers: {'set-cookie': 'antgrid.cross_device_token=bind-1; Path=/'},
    );
  }
  return http.Response(jsonEncode({'status': 'pending'}), 200);
}

AuthService _authFor(
  AuthStorage storage, {
  Future<http.Response> Function(http.Request)? respond,
  List<String>? paths,
  Future<bool> Function(Uri url)? launchUrl,
}) => AuthService(
  licenseApiUrl: 'https://lic.test',
  storage: storage,
  httpClient: MockClient((req) async {
    paths?.add(req.url.path);
    // Any poll a restore kicks off parks on pending — those tests are about
    // what the screen does with the ticket, not the round-trip.
    return (respond ?? _magicLinkServer)(req);
  }),
  // The default launcher is the REAL url_launcher Dart plugin on desktop
  // `flutter test`, which would open an actual browser on the test machine.
  // Refusing doubles as the only signal that OAuth (and not the link) is what
  // a tap reached for; pass a launcher that opens to exercise the other side.
  launchUrl: launchUrl ?? (_) async => false,
);

Widget _wrap(AuthStorage storage) => _wrapService(_authFor(storage));

Widget _wrapService(AuthService auth, {LastAuthMethodStore? store}) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      lastAuthMethodStoreProvider.overrideWithValue(
        store ?? _FakeAuthMethodStore(),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: const SignInScreen(),
    ),
  );
}

/// Mounts the screen on step 1 with no pending ticket, and returns the paths
/// every request hits — so a test can assert what the screen asked the server
/// for as well as what it rendered. Pass [storage] to keep a handle on the
/// ticket store, which is the only way to see what a later launch would restore.
Future<List<String>> _pumpScreen(
  WidgetTester tester, {
  Future<http.Response> Function(http.Request)? respond,
  LastAuthMethodStore? store,
  _GatedStorage? storage,
  Future<bool> Function(Uri url)? launchUrl,
}) async {
  final paths = <String>[];
  final tickets = storage ?? (_GatedStorage(null)..gate.complete());
  await tester.pumpWidget(
    _wrapService(
      _authFor(tickets, respond: respond, paths: paths, launchUrl: launchUrl),
      store: store,
    ),
  );
  // Let the (empty) restore resolve so it cannot land mid-test.
  await tester.pump();
  return paths;
}

/// Types [email] into step 1 and commits it. Deliberately NOT `pumpAndSettle`:
/// Continue can land on the pending screen, whose poll timer is periodic and
/// would never settle. One pump arms the submit, one resolves the hint recall,
/// one resolves whatever that routed to.
Future<void> _continueWith(WidgetTester tester, String email) async {
  await tester.enterText(find.byType(TextField), email);
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// Drives the screen to step 2 through a remembered `password` hint and fills
/// the password field. Step 1's "Continue with a password" is the other way
/// in; it has its own tests.
Future<List<String>> _openPasswordStep(
  WidgetTester tester, {
  required _FakeAuthMethodStore store,
  Future<http.Response> Function(http.Request)? respond,
  String email = 'user@example.com',
  String password = 'a-very-long-password',
}) async {
  final paths = await _pumpScreen(tester, respond: respond, store: store);
  await _continueWith(tester, email);
  if (password.isNotEmpty) {
    await tester.enterText(find.byType(TextField), password);
    await tester.pump();
  }
  return paths;
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

  group('step one', () {
    testWidgets('asks for an address and nothing else', (tester) async {
      final paths = await _pumpScreen(tester);

      expect(find.byType(AbTextField), findsOneWidget);
      expect(
        find.byType(AbPasswordField),
        findsNothing,
        reason: 'offering a password here would ask the user a question about '
            'their own account that only this device can answer',
      );
      expect(find.text('Continue'), findsOneWidget);
      expect(
        paths,
        isEmpty,
        reason: 'no address is handed to the server before the user commits',
      );
    });

    testWidgets('with nothing remembered, Continue sends a magic link', (
      tester,
    ) async {
      final paths = await _pumpScreen(tester);

      await _continueWith(tester, 'user@example.com');

      expect(paths, contains(_startPath));
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('user@example.com'), findsOneWidget);
    });

    testWidgets('with a password remembered, Continue goes to step two', (
      tester,
    ) async {
      final paths = await _pumpScreen(
        tester,
        store: _FakeAuthMethodStore({'user@example.com': AuthMethod.password}),
      );

      // Cased differently from the stored hint: the store normalizes, so this
      // must still route.
      await _continueWith(tester, 'User@Example.com');

      expect(find.text('Enter your password'), findsOneWidget);
      expect(find.byType(AbPasswordField), findsOneWidget);
      expect(
        paths,
        isEmpty,
        reason: 'the step is chosen from the device hint alone — asking the '
            'server would hand out an enumeration oracle',
      );
    });

    testWidgets('with a provider remembered, Continue starts that provider', (
      tester,
    ) async {
      final paths = await _pumpScreen(
        tester,
        store: _FakeAuthMethodStore({'user@example.com': AuthMethod.github}),
      );

      await _continueWith(tester, 'user@example.com');

      // The injected launcher refuses to open, which is how we can tell OAuth
      // (and not the link) is what Continue reached for.
      expect(find.text('Could not open the browser'), findsOneWidget);
      expect(paths, isEmpty);
    });

    testWidgets('a remembered provider can still be escaped for the link', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore({
        'user@example.com': AuthMethod.github,
      });
      final paths = await _pumpScreen(tester, store: store);

      // The hint is wrong for this address, and Continue proves it by reaching
      // for a provider the browser refuses to open.
      await _continueWith(tester, 'user@example.com');
      expect(find.text('Could not open the browser'), findsOneWidget);

      // Step 1 offers no link of its own, so this is the whole escape route:
      // the password button ignores the hint, and the step it reaches is where
      // the link lives. Without it a provider hint would relaunch itself on
      // every Continue with no way out short of clearing the device's storage.
      await tester.tap(find.text('Continue with a password'));
      await tester.pump();
      expect(find.text('Enter your password'), findsOneWidget);

      await tester.tap(find.text('Email me a link instead'));
      await tester.pump();
      await tester.pump();

      expect(paths, contains(_startPath));
      expect(find.text('Check your email'), findsOneWidget);
      expect(
        store.memory['user@example.com'],
        AuthMethod.link,
        reason: 'the escape retires the hint that caused the trap, so the next '
            'Continue does not walk back into it',
      );
    });

    testWidgets('a password this device has never seen is still reachable', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore();
      final paths = await _pumpScreen(tester, store: store);

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with a password'));
      await tester.pump();

      expect(find.text('Enter your password'), findsOneWidget);
      expect(find.byType(AbPasswordField), findsOneWidget);
      expect(
        paths,
        isEmpty,
        reason: 'the escape is a step change and nothing more — asking the '
            'server whether this address has a password is the oracle the '
            'whole flow is built to avoid',
      );
      expect(
        store.memory,
        isEmpty,
        reason: 'taking the escape is a guess, not a commitment: a hint '
            'written here would route every later Continue back to a password '
            'the user may not have',
      );
    });

    testWidgets('the password escape refuses an address step two cannot show', (
      tester,
    ) async {
      await _pumpScreen(tester);

      await tester.tap(find.text('Continue with a password'));
      await tester.pump();

      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(
        find.byType(AbPasswordField),
        findsNothing,
        reason: 'step 2 renders the address as settled text with no field to '
            'fix it, so arriving without one is a dead end',
      );
    });

    testWidgets('a password accepted after the escape is remembered', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore();
      await _pumpScreen(
        tester,
        store: store,
        // Reached only AFTER the password verified, so it proves acceptance
        // through the same `_remember` call a clean sign-in takes.
        respond: (req) async =>
            req.url.path == '/api/auth/send-verification-email'
            ? http.Response(jsonEncode({'status': true}), 200)
            : http.Response(jsonEncode({'code': 'EMAIL_NOT_VERIFIED'}), 403),
      );

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with a password'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'a-very-long-password');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(
        store.memory['user@example.com'],
        AuthMethod.password,
        reason: 'the escape should be needed once — the hint it seeds is what '
            'sends every later Continue straight to step 2',
      );
    });

    testWidgets('a password rejected after the escape is not remembered', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore();
      await _pumpScreen(
        tester,
        store: store,
        respond: (req) async => http.Response(
          jsonEncode({'code': 'INVALID_EMAIL_OR_PASSWORD'}),
          401,
        ),
      );

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with a password'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'not-the-password');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid email or password'), findsOneWidget);
      expect(
        store.memory,
        isEmpty,
        reason: 'the address may have no password at all — the server refuses '
            'to say which, and a hint here would strand the user on a step '
            'that can never work for them',
      );
    });

    testWidgets('sending a link remembers the link method for that address', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore();
      await _pumpScreen(tester, store: store);

      await _continueWith(tester, 'user@example.com');

      expect(store.memory['user@example.com'], AuthMethod.link);
    });

    testWidgets('a provider the browser refused is not remembered', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore();
      await _pumpScreen(tester, store: store);

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with GitHub'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not open the browser'), findsOneWidget);
      expect(
        store.memory,
        isEmpty,
        reason: 'a hint written before the launch outlives a launch that never '
            'happened, and then sends every later Continue back to a provider '
            'that has never worked',
      );
    });

    testWidgets('a provider the browser opened is remembered', (tester) async {
      final store = _FakeAuthMethodStore();
      await _pumpScreen(tester, store: store, launchUrl: (_) async => true);

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with GitHub'));
      await tester.pump();
      await tester.pump();

      expect(store.memory['user@example.com'], AuthMethod.github);
    });
  });

  group('pending', () {
    testWidgets('the resend is disabled for the length of its cooldown', (
      tester,
    ) async {
      final paths = await _pumpScreen(tester);
      await _continueWith(tester, 'user@example.com');

      expect(find.text('Resend the link (45s)'), findsOneWidget);
      // Disabled means unhittable, not merely styled: the label has no gesture
      // detector behind it while the cooldown runs.
      await tester.tap(
        find.text('Resend the link (45s)'),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump();
      expect(
        paths.where((p) => p == _startPath),
        hasLength(1),
        reason: 'one send, however many times the label is tapped',
      );

      await tester.pump(const Duration(seconds: 45));

      expect(find.text('Resend the link'), findsOneWidget);
    });

    testWidgets('a resend landing after the flow was abandoned is dropped', (
      tester,
    ) async {
      final resend = Completer<void>();
      var starts = 0;
      final storage = _GatedStorage(null)..gate.complete();
      final paths = await _pumpScreen(
        tester,
        storage: storage,
        respond: (req) async {
          // Nothing hides the pending screen while a resend is outstanding, so
          // holding the second send open here IS the window in which "Use a
          // different email" sits live under the user's thumb.
          if (req.url.path == _startPath && ++starts > 1) await resend.future;
          return _magicLinkServer(req);
        },
      );
      await _continueWith(tester, 'user@example.com');
      await tester.pump(const Duration(seconds: 45));

      await tester.tap(find.text('Resend the link'));
      await tester.pump();
      expect(
        paths.where((p) => p == _startPath),
        hasLength(2),
        reason: 'the resend really went out — otherwise the race below is not '
            'the one being tested',
      );

      await tester.tap(find.text('Use a different email'));
      await tester.pump();
      expect(find.text('Continue'), findsOneWidget);
      expect(
        storage.pending,
        isNull,
        reason: 'the abandon discarded the ticket while the resend was still '
            'in the air, which is the ordering the whole race turns on',
      );
      final pollsWhenAbandoned = paths.where((p) => p == _statusPath).length;
      expect(
        pollsWhenAbandoned,
        greaterThan(0),
        reason: 'polls land in `paths`, so a flat count below means the timer '
            'stopped — not that polls were never counted',
      );

      resend.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Check your email'),
        findsNothing,
        reason: 'the address the user walked away from must not pull them back',
      );
      expect(
        find.text('Sent. Check your inbox again in a moment.'),
        findsNothing,
        reason: 'a notice about a link claims a flow the user has left',
      );
      expect(find.text('Continue'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30));
      expect(
        paths.where((p) => p == _statusPath),
        hasLength(pollsWhenAbandoned),
        reason: 'a restarted poll would snap the user out of the field they '
            'are typing in, and a ready one would sign them into the '
            'abandoned address',
      );
      expect(
        storage.pending,
        isNull,
        reason: 'the ticket is written inside the send, so it lands after the '
            'abandon discarded one — left there it strands the user on the '
            'abandoned address at next launch',
      );
    });
  });

  group('step two', () {
    testWidgets('an unverified sign-in asks for verification and resends', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore({
        'user@example.com': AuthMethod.password,
      });
      final paths = await _openPasswordStep(
        tester,
        store: store,
        respond: (req) async =>
            http.Response(jsonEncode({'code': 'EMAIL_NOT_VERIFIED'}), 403),
      );
      // Everything after this point is what the sign-in itself wrote, not the
      // seed that got us here.
      store.memory.clear();

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('user@example.com'), findsOneWidget);
      // sendOnSignIn is off server-side, so the screen has to ask for the mail
      // itself or the user waits on something that was never sent.
      expect(paths, contains('/api/auth/send-verification-email'));
      expect(
        store.memory['user@example.com'],
        AuthMethod.password,
        reason: 'the password was accepted, so the hint stands even though the '
            'address still needs verifying',
      );
    });

    testWidgets(
      'a rejected credential shows one message and stays on the form',
      (tester) async {
        final store = _FakeAuthMethodStore({
          'user@example.com': AuthMethod.password,
        });
        await _openPasswordStep(
          tester,
          store: store,
          respond: (req) async => http.Response(
            jsonEncode({'code': 'INVALID_EMAIL_OR_PASSWORD'}),
            401,
          ),
        );
        store.memory.clear();

        await tester.tap(find.text('Sign in'));
        await tester.pumpAndSettle();

        expect(find.text('Invalid email or password'), findsOneWidget);
        expect(find.byType(AbPasswordField), findsOneWidget);
        expect(
          store.memory,
          isEmpty,
          reason: 'nothing was proved about this address, so nothing is '
              'recorded about it',
        );
      },
    );

    testWidgets('an empty password is refused before any request', (
      tester,
    ) async {
      final paths = await _openPasswordStep(
        tester,
        store: _FakeAuthMethodStore({
          'user@example.com': AuthMethod.password,
        }),
        password: '',
      );

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(
        find.text('Enter your password'),
        findsNWidgets(2),
        reason: 'the heading, plus the same words as an inline error',
      );
      expect(find.byType(AbPasswordField), findsOneWidget);
      expect(paths, isEmpty);
    });

    testWidgets('taking the link instead re-remembers the link method', (
      tester,
    ) async {
      final store = _FakeAuthMethodStore({
        'user@example.com': AuthMethod.password,
      });
      final paths = await _openPasswordStep(tester, store: store);

      await tester.tap(find.text('Email me a link instead'));
      await tester.pump();
      await tester.pump();

      expect(paths, contains(_startPath));
      expect(find.text('Check your email'), findsOneWidget);
      expect(
        store.memory['user@example.com'],
        AuthMethod.link,
        reason: 'the hint follows the method the user just committed to',
      );
    });

    testWidgets('forgot-password answers identically for any address', (
      tester,
    ) async {
      final paths = await _openPasswordStep(
        tester,
        store: _FakeAuthMethodStore({
          'user@example.com': AuthMethod.password,
        }),
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

  group('autofill', () {
    testWidgets('the address and the password are one saved credential', (
      tester,
    ) async {
      await _pumpScreen(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).autofillHints,
        contains(AutofillHints.username),
        reason: 'the username half of the pair — a field tagged as a bare '
            'email address gets contact suggestions and saves nothing',
      );

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.pump();
      await tester.tap(find.text('Continue with a password'));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).autofillHints,
        contains(AutofillHints.password),
      );
      expect(
        find.byType(AutofillGroup),
        findsOneWidget,
        reason: 'the two fields never coexist on screen, so only a group '
            'spanning both steps can offer them to the manager as one '
            'credential',
      );
    });
  });

  group('verify email', () {
    const sendPath = '/api/auth/send-verification-email';

    /// A correct password on an unverified address, and a mailer that works.
    /// The screen sends the first verification itself on the way in, so the
    /// resend under it is always a SECOND send.
    Future<http.Response> unverified(http.Request req) async =>
        req.url.path == sendPath
        ? http.Response(jsonEncode({'status': true}), 200)
        : http.Response(jsonEncode({'code': 'EMAIL_NOT_VERIFIED'}), 403);

    _FakeAuthMethodStore seeded() =>
        _FakeAuthMethodStore({'user@example.com': AuthMethod.password});

    /// Sign in with the right password on an unverified address, landing on the
    /// verification screen with its auto-send already away.
    Future<void> reachVerifyScreen(WidgetTester tester) async {
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the verification resend is paced like every other send', (
      tester,
    ) async {
      final paths = await _openPasswordStep(
        tester,
        store: seeded(),
        respond: unverified,
      );
      await reachVerifyScreen(tester);

      expect(paths.where((p) => p == sendPath), hasLength(1));
      expect(
        find.text('Resend the link (45s)'),
        findsOneWidget,
        reason: 'the screen itself just sent one, so an instant retry would '
            'race the mail it is meant to replace',
      );

      // Disabled means unhittable, not merely styled.
      await tester.tap(find.text('Resend the link (45s)'), warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(
        paths.where((p) => p == sendPath),
        hasLength(1),
        reason: 'one send, however many times the label is tapped — the server '
            'bucket behind this is 5 burst, 1 per minute',
      );

      await tester.pump(const Duration(seconds: 45));
      expect(find.text('Resend the link'), findsOneWidget);

      await tester.tap(find.text('Resend the link'));
      await tester.pump();
      await tester.pump();
      expect(paths.where((p) => p == sendPath), hasLength(2));
    });

    testWidgets('a resend landing after the flow was abandoned is dropped', (
      tester,
    ) async {
      final resend = Completer<void>();
      var sends = 0;
      await _openPasswordStep(
        tester,
        store: seeded(),
        respond: (req) async {
          if (req.url.path != sendPath) return unverified(req);
          // Nothing hides this screen while a resend is outstanding, so holding
          // the second send open here IS the window in which "Use a different
          // email" sits live under the user's thumb.
          if (++sends > 1) await resend.future;
          return unverified(req);
        },
      );
      await reachVerifyScreen(tester);
      await tester.pump(const Duration(seconds: 45));

      await tester.tap(find.text('Resend the link'));
      await tester.pump();
      expect(
        sends,
        2,
        reason: 'the resend really went out — otherwise the race below is not '
            'the one being tested',
      );

      await tester.tap(find.text('Use a different email'));
      await tester.pump();
      expect(find.text('Continue'), findsOneWidget);

      resend.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Sent. Check your inbox again in a moment.'),
        findsNothing,
        reason: 'a notice about a verification claims a flow the user has left',
      );
      expect(
        find.text('Continue'),
        findsOneWidget,
        reason: 'the address the user walked away from must not pull them back',
      );
    });
  });
}
