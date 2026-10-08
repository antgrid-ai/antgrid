// webview_all re-exports only the creation params; the platform classes a
// recording fake has to extend live in the transitive interface package.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

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

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loadedUrls.add(params.uri.toString());

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async =>
      retirements++;

  @override
  Future<void> reload() async => reloads++;

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class QuietNavigationDelegate extends PlatformNavigationDelegate {
  QuietNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

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
