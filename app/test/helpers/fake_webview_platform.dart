// webview_all re-exports only the creation params; the platform classes a
// recording fake has to extend live in the transitive interface package.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:webview_platform_interface/webview_platform_interface.dart';

/// Installs a fresh [RecordingWebViewPlatform] for the current test.
RecordingWebViewPlatform installRecordingWebViewPlatform() {
  final original = WebViewPlatform.instance;
  final platform = RecordingWebViewPlatform();
  WebViewPlatform.instance = platform;
  // The interface's setter rejects null, so a run that started with no
  // platform installed leaves the fake behind rather than restoring it.
  addTearDown(() {
    if (original != null) WebViewPlatform.instance = original;
  });
  return platform;
}

/// A webview platform that records every controller it creates and every load
/// each one is asked for.
class RecordingWebViewPlatform extends WebViewPlatform {
  final controllers = <RecordingWebViewController>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = RecordingWebViewController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => QuietNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => BlankWebViewWidget(params);
}

class RecordingWebViewController extends PlatformWebViewController {
  RecordingWebViewController(super.params) : super.implementation();

  final loadedUrls = <String>[];

  /// Blank-document loads, which is how a dropped controller is retired. Kept
  /// apart from [loadedUrls] so load-order expectations ignore teardown.
  int retirements = 0;

  int reloads = 0;

  /// While set, a blank-document load does not finish until it completes, so
  /// a test can hold a retirement open.
  Completer<void>? retireGate;

  /// While set, history queries do not answer until it completes, with its
  /// value as canGoBack.
  Completer<bool>? historyGate;

  /// The navigation delegate the screen installed, whose callbacks a test can
  /// fire as if this page had navigated.
  QuietNavigationDelegate? delegate;

  /// JS channels by name, for delivering a message as if this page sent it.
  final channels = <String, void Function(JavaScriptMessage)>{};

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loadedUrls.add(params.uri.toString());

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    retirements++;
    final g = retireGate;
    if (g != null) await g.future;
  }

  @override
  Future<void> reload() async => reloads++;

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    channels[javaScriptChannelParams.name] =
        javaScriptChannelParams.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    if (handler is QuietNavigationDelegate) delegate = handler;
  }

  @override
  Future<bool> canGoBack() async {
    final g = historyGate;
    return g == null ? false : await g.future;
  }

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

/// Keeps the page callbacks the screen registers so a test can fire them, and
/// drops the rest.
class QuietNavigationDelegate extends PlatformNavigationDelegate {
  QuietNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  UrlChangeCallback? onUrlChange;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async =>
      this.onUrlChange = onUrlChange;

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class BlankWebViewWidget extends PlatformWebViewWidget {
  BlankWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

// The result constructor throws unless every data type has exactly one
// outcome, so each fixture classifies all of them.

final kCompleteResult = WebViewDataClearingResult(
  clearedDataTypes: WebViewDataType.values.toSet(),
);

final kWindowsResult = WebViewDataClearingResult(
  clearedDataTypes: WebViewDataType.values.toSet()
    ..removeAll({
      WebViewDataType.sessionStorage,
      WebViewDataType.serviceWorkers,
    }),
  unsupportedDataTypes: {
    WebViewDataType.sessionStorage,
    WebViewDataType.serviceWorkers,
  },
);

final kAndroidLegacyResult = WebViewDataClearingResult(
  clearedDataTypes: {
    WebViewDataType.cookies,
    WebViewDataType.localStorage,
    WebViewDataType.webSql,
    WebViewDataType.cache,
  },
  unsupportedDataTypes: {
    WebViewDataType.sessionStorage,
    WebViewDataType.indexedDb,
    WebViewDataType.cacheStorage,
    WebViewDataType.serviceWorkers,
  },
);

final kOneFailureResult = WebViewDataClearingResult(
  failures: {WebViewDataType.cookies: 'x'},
  clearedDataTypes: WebViewDataType.values.toSet()
    ..remove(WebViewDataType.cookies),
);

final kAllUnsupportedResult = WebViewDataClearingResult(
  unsupportedDataTypes: WebViewDataType.values.toSet(),
);

/// A [PreviewWebsiteDataWipe] that counts its calls and can be scripted.
class WipeRecorder {
  int calls = 0;
  WebViewDataClearingResult? result = kCompleteResult;
  Object? throwing;

  /// While set, each call waits on it before answering.
  Completer<void>? gate;

  /// Runs at the start of every call, for tests that sample state at the
  /// moment a clear begins.
  void Function()? onCall;

  Future<WebViewDataClearingResult?> call() async {
    calls++;
    onCall?.call();
    final g = gate;
    if (g != null) await g.future;
    final t = throwing;
    if (t != null) throw t;
    return result;
  }
}
