import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/agent_hello.dart';
import '../models/preview_models.dart';
import '../models/service_status.dart';
import '../models/ab_message.dart';
import 'project_message_classification.dart';

/// Immutable snapshot of the aggregate status for a single project.
///
/// Acts as the foundational data class for the multi-project app aggregate
/// (Plan B). All fields are value-typed; equality is structural.
@immutable
class ProjectStatus {
  final bool configError;
  final String? configErrorMessage;
  final String? activeCommandName;
  final List<int> detectedPorts;
  final List<ServiceStatus> services;
  final AgentHello? agentHello;
  final DateTime? lastUpdatedAt;

  const ProjectStatus({
    this.configError = false,
    this.configErrorMessage,
    this.activeCommandName,
    this.detectedPorts = const [],
    this.services = const [],
    this.agentHello,
    this.lastUpdatedAt,
  });

  const ProjectStatus.empty() : this();

  ProjectStatus copyWith({
    bool? configError,
    String? configErrorMessage,
    String? activeCommandName,
    List<int>? detectedPorts,
    List<ServiceStatus>? services,
    AgentHello? agentHello,
    DateTime? lastUpdatedAt,
    bool clearConfigErrorMessage = false,
    bool clearActiveCommandName = false,
    bool clearAgentHello = false,
  }) {
    return ProjectStatus(
      configError: configError ?? this.configError,
      configErrorMessage: clearConfigErrorMessage
          ? null
          : (configErrorMessage ?? this.configErrorMessage),
      activeCommandName: clearActiveCommandName
          ? null
          : (activeCommandName ?? this.activeCommandName),
      detectedPorts: detectedPorts ?? this.detectedPorts,
      services: services ?? this.services,
      agentHello: clearAgentHello ? null : (agentHello ?? this.agentHello),
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'configError': configError,
    if (configErrorMessage != null) 'configErrorMessage': configErrorMessage,
    if (activeCommandName != null) 'activeCommandName': activeCommandName,
    'detectedPorts': detectedPorts,
    'services': services.map((s) => s.toJson()).toList(),
    if (agentHello != null) 'agentHello': agentHello!.toJson(),
    if (lastUpdatedAt != null)
      'lastUpdatedAt': lastUpdatedAt!.toIso8601String(),
  };

  factory ProjectStatus.fromJson(Map<String, dynamic> j) {
    final servicesRaw = (j['services'] as List?) ?? const [];
    final services = <ServiceStatus>[];
    for (final entry in servicesRaw) {
      if (entry is Map<String, dynamic>) {
        final svc = ServiceStatus.fromJson(entry);
        if (svc != null) services.add(svc);
      }
    }
    final helloRaw = j['agentHello'];
    return ProjectStatus(
      configError: (j['configError'] as bool?) ?? false,
      configErrorMessage: j['configErrorMessage'] as String?,
      activeCommandName: j['activeCommandName'] as String?,
      detectedPorts:
          (j['detectedPorts'] as List?)?.cast<int>() ?? const <int>[],
      services: services,
      agentHello: helloRaw is Map<String, dynamic>
          ? AgentHello.fromJson(helloRaw)
          : null,
      lastUpdatedAt: j['lastUpdatedAt'] is String
          ? DateTime.parse(j['lastUpdatedAt'] as String)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectStatus &&
          configError == other.configError &&
          configErrorMessage == other.configErrorMessage &&
          activeCommandName == other.activeCommandName &&
          listEquals(detectedPorts, other.detectedPorts) &&
          listEquals(services, other.services) &&
          agentHello == other.agentHello &&
          lastUpdatedAt == other.lastUpdatedAt;

  @override
  int get hashCode => Object.hash(
    configError,
    configErrorMessage,
    activeCommandName,
    Object.hashAll(detectedPorts),
    Object.hashAll(services),
    agentHello,
    lastUpdatedAt,
  );
}

/// Mutable holder for a project's [ProjectStatus]. Subscribes to a
/// status-tier envelope stream (typically `MessageRouter.status`) and applies
/// updates immutably.
class ProjectStatusNotifier extends ValueNotifier<ProjectStatus> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _disposed = false;

  // Status-tier types this notifier reduces into [ProjectStatus] (beyond the
  // config dot). Anything else round-trips through parseAbMessage for nothing,
  // so it's skipped. Frame-invariant — a static const, not a per-call literal.
  static const Set<String> _reducerTypes = {
    'agent:status',
    'agent:hello',
    'ports:update',
    'command:done',
  };

  ProjectStatusNotifier(Stream<Map<String, dynamic>> statusStream)
    : super(const ProjectStatus.empty()) {
    _sub = statusStream.listen(_apply);
  }

  /// Hydrate from disk-cached status (Plan C). Replaces value wholesale.
  void hydrate(ProjectStatus cached) {
    if (_disposed) return;
    value = cached;
  }

  void _apply(Map<String, dynamic> envelope) {
    if (_disposed) return;
    var next = value;

    final type = envelope['type'];
    final rawErr = envelope['error'];
    final frameHasError = rawErr is String && rawErr.isNotEmpty;

    // The drawer dot tracks structural (config) problems only — the project
    // stays broken until the YAML is fixed. Transient operational errors
    // (file read, search, git checkout, session) are surfaced where they
    // happen, not via this persistent flag. [kConfigValidityTypes] is the
    // shared source of truth for which frames carry config validity.
    if (type is String && kConfigValidityTypes.contains(type)) {
      if (frameHasError) {
        // Only on a genuine transition (new error or changed message): a
        // repeated identical error frame must not churn the drawer/cache.
        if (!next.configError || next.configErrorMessage != rawErr) {
          next = next.copyWith(
            configError: true,
            configErrorMessage: rawErr,
            lastUpdatedAt: DateTime.now(),
          );
        }
      } else if (next.configError) {
        // A clean config frame means the config reloaded successfully — the
        // only signal that clears the dot. Skip when already clean so a benign
        // config:changed (fired on every valid save) doesn't churn the cache.
        next = next.copyWith(
          configError: false,
          clearConfigErrorMessage: true,
          lastUpdatedAt: DateTime.now(),
        );
      }
    }

    if (type is! String || !_reducerTypes.contains(type)) {
      if (next != value) value = next;
      return;
    }

    final parsed = parseAbMessage(envelope);
    if (parsed is AgentStatusMessage) {
      next = next.copyWith(
        services: parsed.services,
        lastUpdatedAt: DateTime.now(),
      );
    } else if (parsed is AgentHello) {
      next = next.copyWith(agentHello: parsed, lastUpdatedAt: DateTime.now());
    } else if (parsed is PortsUpdateMessage) {
      final ports = parsed.ports.map((p) => p.port).toList(growable: false);
      next = next.copyWith(detectedPorts: ports, lastUpdatedAt: DateTime.now());
    } else if (parsed is CommandDoneMessage) {
      next = next.copyWith(
        clearActiveCommandName: true,
        lastUpdatedAt: DateTime.now(),
      );
    }

    if (next != value) value = next;
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
