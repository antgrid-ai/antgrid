import 'dart:convert';

/// Clipboard payloads are transient and must never be included in diagnostics.
class TerminalClipboardMessage {
  const TerminalClipboardMessage(
    this.type,
    this.context,
    this.requestId,
    this.claimId,
    this.epoch,
    this.lifetimeMs,
    this.eventId,
    this.text,
    this.reason,
  );
  final String type;
  final ({
    String checkoutId,
    String terminalId,
    String runId,
    String attachmentId,
  })
  context;
  final String? requestId, claimId, eventId, text, reason;
  final int? epoch, lifetimeMs;

  static TerminalClipboardMessage? parse(Map<String, dynamic> json) {
    final type = json['type'];
    if (!const {
      'terminal:clipboard:claimed',
      'terminal:clipboard:revoked',
      'terminal:clipboard:write',
      'terminal:clipboard:host-text',
    }.contains(type)) {
      return null;
    }
    final timestamp = json['timestamp'];
    if (!_uuid(json['id']) ||
        timestamp is! num ||
        !timestamp.isFinite ||
        !_withinWireLimit(json)) {
      return null;
    }
    final checkout = json['checkoutId'];
    final terminal = json['terminalId'];
    final run = json['runId'];
    final attachment = json['attachmentId'];
    if (type is! String ||
        checkout is! String ||
        checkout.isEmpty ||
        checkout.length > 256 ||
        terminal is! String ||
        terminal.isEmpty ||
        terminal.length > 256 ||
        !_uuid(run) ||
        !_uuid(attachment)) {
      return null;
    }
    final grant = json['grant'];
    if (grant != null && grant is! Map<String, dynamic>) return null;
    final identity = grant is Map<String, dynamic> ? grant : json;
    final claim = identity['claimId'];
    final epoch = identity['epoch'];
    final lifetime = identity['lifetimeMs'];
    final request = json['requestId'];
    final event = json['eventId'];
    if ((claim != null && !_uuid(claim)) ||
        (epoch != null && (epoch is! int || epoch < 0)) ||
        (request != null && !_uuid(request)) ||
        (event != null && !_uuid(event)) ||
        (lifetime != null &&
            (lifetime is! int || lifetime < 1 || lifetime > 5000))) {
      return null;
    }
    if ((type.endsWith(':claimed') || type.endsWith(':host-text')) &&
        request == null) {
      return null;
    }
    if ((type.endsWith(':write') ||
            type.endsWith(':revoked') ||
            grant != null) &&
        (claim == null || epoch == null)) {
      return null;
    }
    if (grant != null && lifetime == null) return null;
    if (type.endsWith(':write') && event == null) return null;
    final encoded = json['text'];
    final text = encoded == null ? null : decodeText(encoded);
    if ((encoded != null && text == null) ||
        (type.endsWith(':write') && text == null)) {
      return null;
    }
    if (type.endsWith(':claimed') &&
        ((grant == null) == (json['reason'] == null))) {
      return null;
    }
    if (type.endsWith(':host-text') &&
        ((text == null) == (json['error'] == null))) {
      return null;
    }
    if (json['reason'] != null &&
        !const {
          'unavailable',
          'conflict',
          'stale',
          'denied',
        }.contains(json['reason'])) {
      return null;
    }
    if (json['error'] != null &&
        !const {
          'unsupported',
          'empty',
          'too-large',
          'unavailable',
          'failed',
        }.contains(json['error'])) {
      return null;
    }
    if (type.endsWith(':revoked') && json['reason'] == null) return null;
    final reason = json['reason'] ?? json['error'];
    if (reason != null && reason is! String) return null;
    return TerminalClipboardMessage(
      type,
      (
        checkoutId: checkout,
        terminalId: terminal,
        runId: run as String,
        attachmentId: attachment as String,
      ),
      request as String?,
      claim as String?,
      epoch as int?,
      lifetime as int?,
      event as String?,
      text,
      reason as String?,
    );
  }

  static bool _uuid(Object? value) =>
      value is String &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value);

  /// Count encoded bytes without allocating another copy of an untrusted body.
  static bool _withinWireLimit(Map<String, dynamic> json) {
    var remaining = 140 * 1024;
    bool count(Object? value, int depth) {
      if (depth > 8 || remaining < 0) return false;
      if (value is String) {
        remaining -= 2;
        if (value.length > remaining) return false;
        for (var i = 0; i < value.length; i++) {
          final code = value.codeUnitAt(i);
          if (code == 34 || code == 92) {
            remaining -= 2;
          } else if (code < 32) {
            remaining -= const {8, 9, 10, 12, 13}.contains(code) ? 2 : 6;
          } else if (code < 128) {
            remaining--;
          } else if (code < 2048) {
            remaining -= 2;
          } else if (code >= 0xd800 &&
              code <= 0xdbff &&
              i + 1 < value.length &&
              value.codeUnitAt(i + 1) >= 0xdc00 &&
              value.codeUnitAt(i + 1) <= 0xdfff) {
            remaining -= 4;
            i++;
          } else {
            remaining -= code >= 0xd800 && code <= 0xdfff ? 6 : 3;
          }
          if (remaining < 0) return false;
        }
      } else if (value is Map<String, dynamic>) {
        remaining -= 2;
        var first = true;
        for (final entry in value.entries) {
          remaining -= first ? 1 : 2;
          first = false;
          if (!count(entry.key, depth + 1) || !count(entry.value, depth + 1)) {
            return false;
          }
        }
      } else if (value is List) {
        remaining -= 2;
        var first = true;
        for (final item in value) {
          if (!first) remaining--;
          first = false;
          if (!count(item, depth + 1)) return false;
        }
      } else if (value == null ||
          value is bool ||
          (value is num && value.isFinite)) {
        remaining -= value.toString().length;
      } else {
        return false;
      }
      return remaining >= 0;
    }

    return count(json, 0);
  }

  static String? decodeText(Object encoded) {
    if (encoded is! String ||
        encoded.isEmpty ||
        encoded.length > 133336 ||
        encoded.length % 4 != 0 ||
        !RegExp(
          r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
        ).hasMatch(encoded)) {
      return null;
    }
    try {
      final bytes = base64.decode(encoded);
      if (bytes.length > 100000 || base64.encode(bytes) != encoded) return null;
      final text = utf8.decode(bytes);
      return text.isEmpty || text.contains('\x00') ? null : text;
    } on FormatException {
      return null;
    }
  }
}
