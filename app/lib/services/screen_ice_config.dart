/// ICE configuration shared by the two screen-share peer connections.
///
/// ICE here is STUN plus host candidates, nothing else. Host candidates carry
/// the highest priority, so two devices on one subnet connect with no server,
/// no egress and no configuration at all — the dominant case, and the reason
/// nothing in this file is required for the feature to work. STUN widens that
/// to devices whose NATs hole-punch. Sessions no hole punching will connect
/// have no path yet; the planned fallback tunnels ICE-TCP through an Iroh
/// stream rather than standing up a relay server.
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

@immutable
class IceServer {
  const IceServer({required this.urls});

  final List<String> urls;

  /// The shape `createPeerConnection` expects for one `iceServers` entry.
  Map<String, dynamic> toMap() => {'urls': urls};
}

const List<String> kScreenShareStunUrls = ['stun:stun.l.google.com:19302'];

const IceServer kScreenShareStunServer = IceServer(urls: kScreenShareStunUrls);

/// Resolves the ICE servers for ONE session.
///
/// Called per session rather than once per backend so an injected resolver
/// sees each session afresh.
typedef IceServerResolver = Future<List<IceServer>> Function();

Future<List<IceServer>> defaultIceServers() async => const [
  kScreenShareStunServer,
];

/// Runs [resolver], degrading to STUN alone if it fails.
///
/// A resolver that throws must not take the session down: host and STUN
/// candidates connect every case this configuration can connect at all.
Future<List<IceServer>> resolveIceServersOrStun(
  IceServerResolver resolver,
) async {
  try {
    return await resolver();
  } catch (err) {
    developer.log(
      'screen share: ICE configuration unavailable, falling back to STUN: '
      '$err',
      name: 'antgrid.screen',
    );
    return const [kScreenShareStunServer];
  }
}

List<Map<String, dynamic>> encodeIceServers(List<IceServer> servers) =>
    servers.map((server) => server.toMap()).toList(growable: false);
