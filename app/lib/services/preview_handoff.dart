import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/preview_models.dart';
import 'preview_port_forwarder.dart';

/// What a relay-mode preview leaves behind when its service is disposed: the
/// loopback listeners the WebView is still pointed at, and the tab state that
/// names them.
class ParkedPreview {
  ParkedPreview({
    required this.forwarders,
    required this.tabs,
    required this.activeTabId,
    required this.autoOpenConsidered,
  });

  final Map<int, PreviewPortForwarder> forwarders;
  final List<PreviewTab> tabs;
  final int? activeTabId;
  final Set<int> autoOpenConsidered;

  Future<void> close() async {
    for (final forwarder in forwarders.values) {
      await forwarder.close();
    }
  }
}

/// Carries a relay project's open preview from one [PreviewService] to the
/// next for the same project and checkout.
///
/// A redial swaps the machine session, which rebuilds the transport and with
/// it the whole project session, so the service that owns the tabs is disposed
/// on every reconnect. Closing its listeners there left the WebView pointed at
/// a dead loopback port that nothing would ever reopen. Parked listeners keep
/// their port, so the page's own retries land on the successor's transport and
/// the tab never reloads.
///
/// Nothing tells a disposing service whether a successor is coming (eviction,
/// sign-out and a deleted checkout dispose it the same way), so a parked
/// preview nobody claims within [grace] is closed.
class PreviewHandoff {
  PreviewHandoff({this.grace = const Duration(seconds: 60)});

  static final PreviewHandoff shared = PreviewHandoff();

  final Duration grace;
  final Map<String, ({ParkedPreview preview, Timer timer})> _parked = {};
  final Map<String, void Function(ParkedPreview)> _claimants = {};

  /// Takes what a predecessor parked under [key]. When nothing is parked yet,
  /// [onLatePark] receives it instead if the predecessor parks while the
  /// claimant is still live — the old session's teardown is not ordered
  /// against the new one's construction.
  ParkedPreview? claim(String key, void Function(ParkedPreview) onLatePark) {
    final parked = _parked.remove(key);
    if (parked != null) {
      parked.timer.cancel();
      return parked.preview;
    }
    _claimants[key] = onLatePark;
    return null;
  }

  /// Withdraws a claim made with [onLatePark]; a later claimant's is kept.
  void withdraw(String key, void Function(ParkedPreview) onLatePark) {
    if (identical(_claimants[key], onLatePark)) _claimants.remove(key);
  }

  void park(String key, ParkedPreview preview) {
    final claimant = _claimants.remove(key);
    if (claimant != null) {
      claimant(preview);
      return;
    }
    final previous = _parked.remove(key);
    if (previous != null) {
      previous.timer.cancel();
      unawaited(previous.preview.close());
    }
    _parked[key] = (
      preview: preview,
      timer: Timer(grace, () {
        if (identical(_parked[key]?.preview, preview)) _parked.remove(key);
        unawaited(preview.close());
      }),
    );
  }

  /// Closes everything parked and drops every claim.
  @visibleForTesting
  Future<void> clear() async {
    final parked = _parked.values.toList();
    _parked.clear();
    _claimants.clear();
    for (final p in parked) {
      p.timer.cancel();
      await p.preview.close();
    }
  }
}
