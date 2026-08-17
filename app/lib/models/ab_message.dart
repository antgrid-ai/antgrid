import 'package:uuid/uuid.dart';

import 'agent_event.dart' show parseAgentEvent;
import 'agent_hello.dart';
import 'file_tree_models.dart';
import 'handler_state.dart' show HandlerEscalationChoice;
import 'layout_models.dart';
import 'preview_models.dart';
import 'service_status.dart';

// --- Data classes ---

class TerminalStatusInfo {
  final String terminalId;
  final String name;
  final bool running;
  final String? shell;
  final int? cols;
  final int? rows;
  final String? type; // "agent" | "service"
  final String? driverClientId;

  const TerminalStatusInfo({
    required this.terminalId,
    required this.name,
    required this.running,
    this.shell,
    this.cols,
    this.rows,
    this.type,
    this.driverClientId,
  });

  static TerminalStatusInfo? fromJson(Map<String, dynamic> json) {
    final terminalId = json['terminalId'];
    final name = json['name'];
    final running = json['running'];
    if (terminalId is! String || name is! String || running is! bool) {
      return null;
    }
    return TerminalStatusInfo(
      terminalId: terminalId,
      name: name,
      running: running,
      shell: json['shell'] as String?,
      cols: json['cols'] as int?,
      rows: json['rows'] as int?,
      type: json['type'] as String?,
      driverClientId: json['driverClientId'] as String?,
    );
  }
}

class AgentInfo {
  final String name;
  final String? version;

  const AgentInfo({required this.name, this.version});

  static AgentInfo? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String) return null;
    return AgentInfo(name: name, version: json['version'] as String?);
  }
}

class CommandInfo {
  final String name;
  final bool confirm;

  const CommandInfo({required this.name, this.confirm = false});

  static CommandInfo? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String) return null;
    return CommandInfo(name: name, confirm: json['confirm'] as bool? ?? false);
  }
}

class ProxyStatusInfo {
  final String name;
  final int port;
  final bool browser;

  const ProxyStatusInfo({
    required this.name,
    required this.port,
    this.browser = false,
  });

  static ProxyStatusInfo? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final port = json['port'];
    if (name is! String || port is! int) return null;
    return ProxyStatusInfo(
      name: name,
      port: port,
      browser: json['browser'] as bool? ?? false,
    );
  }
}

// --- Inbound message types (Agent → App) ---

class GitInfo {
  final String branch;

  const GitInfo({required this.branch});

  static GitInfo? fromJson(Map<String, dynamic> json) {
    final branch = json['branch'];
    if (branch is! String) return null;
    return GitInfo(branch: branch);
  }
}

class AgentStatusMessage {
  final String id;
  final int timestamp;
  final String? projectId;
  final List<TerminalStatusInfo> terminals;
  final List<ServiceStatus> services;
  final AgentInfo? agent;
  final LayoutConfig? layout;
  final List<CommandInfo>? commands;
  final List<ProxyStatusInfo>? proxies;
  final GitInfo? git;
  final bool? needsFirstRun;

  const AgentStatusMessage({
    required this.id,
    required this.timestamp,
    this.projectId,
    required this.terminals,
    this.services = const [],
    this.agent,
    this.layout,
    this.commands,
    this.proxies,
    this.git,
    this.needsFirstRun,
  });
}

class TerminalOutputMessage {
  final String id;
  final int timestamp;
  final String terminalId;
  final String data;
  final int? seq;

  const TerminalOutputMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
    required this.data,
    this.seq,
  });
}

class TerminalStartedMessage {
  final String id;
  final int timestamp;
  final String terminalId;
  final String? shell;
  final int? cols;
  final int? rows;
  final String? terminalType; // "agent" | "service"

  const TerminalStartedMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
    this.shell,
    this.cols,
    this.rows,
    this.terminalType,
  });
}

class TerminalExitedMessage {
  final String id;
  final int timestamp;
  final String terminalId;
  final int? exitCode;

  const TerminalExitedMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
    this.exitCode,
  });
}

class TerminalNotificationMessage {
  final String id;
  final int timestamp;
  final String terminalId;
  final String kind; // "osc9" | "osc777"
  final String? title;
  final String? body;

  const TerminalNotificationMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
    required this.kind,
    this.title,
    this.body,
  });
}

class NotificationPushMessage {
  final String id;
  final int timestamp;
  final String
  notificationType; // task_complete | permission_request | awaiting_input | idle | error
  final String? message;
  final String? sessionTitle;

  /// Which session fired this, when the hook carried a terminal id. Absent for
  /// an unattributed hook. Lets the surfacer stay quiet about the chat the user
  /// is already reading — see workspace_shell's _onAgentNotificationPush.
  final String? sessionId;
  final String? projectId;

  const NotificationPushMessage({
    required this.id,
    required this.timestamp,
    required this.notificationType,
    this.message,
    this.sessionTitle,
    this.sessionId,
    this.projectId,
  });
}

class TerminalSizeMessage {
  final String terminalId;
  final int cols;
  final int rows;
  final String driverClientId;

  const TerminalSizeMessage({
    required this.terminalId,
    required this.cols,
    required this.rows,
    required this.driverClientId,
  });
}

/// Raw per-session maps — typed parsing (goal, backlog, run state, judge)
/// lives in `HandlerSessionState.fromWire` (`handler_state.dart`), not here.
class HandlerStatusMessage {
  final String id;
  final int timestamp;
  final String projectId;

  /// What an absent per-session judge tool resolves to for PTY slots (the
  /// project's agent tool); chat slots resolve from their own session entry.
  final String? defaultTool;
  final bool defaultNotifyOnly;
  final List<Map<String, dynamic>> sessions;

  /// Every §5.2 snapshot the project still knows about, replayed like the
  /// escalations so an app that restarted between the advert and the tap can
  /// still reach the undo. Project-level, not per session: the offer matters
  /// most once the session that took it has wrapped up.
  final List<Map<String, dynamic>> snapshots;

  const HandlerStatusMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    this.defaultTool,
    required this.defaultNotifyOnly,
    required this.sessions,
    this.snapshots = const [],
  });
}

/// Advert of one snapshot the bridge captured, re-sent whenever its state
/// changes. The payload is flat (`HandlerSnapshotWire` extended onto the
/// envelope), so the whole envelope is handed to `HandlerSnapshot.fromWire` —
/// the same parse the status replay uses, so the two paths cannot drift.
class HandlerSnapshotMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final Map<String, dynamic> snapshot;

  const HandlerSnapshotMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.snapshot,
  });
}

class HandlerEscalationMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String escalationId;
  final String terminalId;
  final String question;
  final String reasoning;
  final String draftReply;
  final String urgency; // 'normal' | 'high'
  final String? floorRule;
  final String? kind;

  /// Null unless the bridge offered a decision card; see
  /// [HandlerEscalationChoice.listFromWire], which is the single parse site
  /// this and the status replay share.
  final List<HandlerEscalationChoice>? choices;

  const HandlerEscalationMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.escalationId,
    required this.terminalId,
    required this.question,
    required this.reasoning,
    required this.draftReply,
    required this.urgency,
    this.floorRule,
    this.kind,
    this.choices,
  });
}

class HandlerActivityMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String recordId;
  final int at;
  final String terminalId;
  // Value list documented on HandlerActivityRecord (`handler_state.dart`),
  // which is the app-side lockstep site for the bridge's enum.
  final String decision;
  final String reason;
  final String? detail;

  const HandlerActivityMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.recordId,
    required this.at,
    required this.terminalId,
    required this.decision,
    required this.reason,
    this.detail,
  });
}

class CommandOutputMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String commandName;
  final String data;

  const CommandOutputMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.commandName,
    required this.data,
  });
}

class CommandDoneMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String commandName;
  final int? exitCode;

  const CommandDoneMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.commandName,
    this.exitCode,
  });
}

class GitFileStatusEntry {
  final String path;
  final String status; // "M", "A", "D", "R", "U", "!"
  final bool staged;
  final String? oldPath; // pre-rename path, set only when status is "R"
  final int additions; // lines added vs HEAD, combined staged+unstaged
  final int deletions; // lines removed vs HEAD, combined staged+unstaged

  const GitFileStatusEntry({
    required this.path,
    required this.status,
    required this.staged,
    this.oldPath,
    this.additions = 0,
    this.deletions = 0,
  });

  static GitFileStatusEntry? fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final status = json['status'];
    if (path is! String || status is! String) return null;
    return GitFileStatusEntry(
      path: path,
      status: status,
      staged: json['staged'] as bool? ?? false,
      oldPath: json['oldPath'] as String?,
      additions: (json['additions'] as num?)?.toInt() ?? 0,
      deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    );
  }
}

class GitStatusMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final List<GitFileStatusEntry> files;

  const GitStatusMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.files,
  });
}

class GitDiffContentMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String path;
  final String? diff;
  final int additions;
  final int deletions;

  const GitDiffContentMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.path,
    this.diff,
    required this.additions,
    required this.deletions,
  });
}

class GitBranchesMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String current;
  final List<String> branches;

  const GitBranchesMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.current,
    required this.branches,
  });
}

class GitCheckoutResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String branch;
  final bool success;
  final String? error;

  const GitCheckoutResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.branch,
    required this.success,
    this.error,
  });
}

class GitCommitResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final bool success;
  final String? sha;
  final String? error;

  const GitCommitResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.success,
    this.sha,
    this.error,
  });
}

class GitDiscardResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final bool success;
  final List<String> files;
  final String? error;

  const GitDiscardResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.success,
    required this.files,
    this.error,
  });
}

class GitStageResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final bool success;
  final List<String> files;
  final String? error;

  const GitStageResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.success,
    required this.files,
    this.error,
  });
}

class GitUnstageResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final bool success;
  final List<String> files;
  final String? error;

  const GitUnstageResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.success,
    required this.files,
    this.error,
  });
}

class SearchMatchEntry {
  final String path;
  final int line;
  final int column;
  final String lineContent;
  final List<String> contextBefore;
  final List<String> contextAfter;

  const SearchMatchEntry({
    required this.path,
    required this.line,
    required this.column,
    required this.lineContent,
    required this.contextBefore,
    required this.contextAfter,
  });

  static SearchMatchEntry? fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final line = json['line'];
    final column = json['column'];
    final lineContent = json['lineContent'];
    if (path is! String ||
        line is! int ||
        column is! int ||
        lineContent is! String) {
      return null;
    }
    return SearchMatchEntry(
      path: path,
      line: line,
      column: column,
      lineContent: lineContent,
      contextBefore: (json['contextBefore'] as List?)?.cast<String>() ?? [],
      contextAfter: (json['contextAfter'] as List?)?.cast<String>() ?? [],
    );
  }
}

class FileSearchResultMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String requestId;
  final List<SearchMatchEntry> matches;

  const FileSearchResultMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.requestId,
    required this.matches,
  });
}

class FileSearchDoneMessage {
  final String id;
  final int timestamp;
  final String projectId;
  final String requestId;
  final int totalMatches;
  final int totalFiles;
  final int duration;
  final String engine;
  final String? error;

  const FileSearchDoneMessage({
    required this.id,
    required this.timestamp,
    required this.projectId,
    required this.requestId,
    required this.totalMatches,
    required this.totalFiles,
    required this.duration,
    required this.engine,
    this.error,
  });
}

class ClientFocusStateMessage {
  final String id;
  final int timestamp;
  final bool paused;

  const ClientFocusStateMessage({
    required this.id,
    required this.timestamp,
    required this.paused,
  });
}

class TerminalSnapshotRequestMessage {
  final String id;
  final int timestamp;
  final String terminalId;

  const TerminalSnapshotRequestMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
  });
}

class TerminalSnapshotMessage {
  final String id;
  final int timestamp;
  final String terminalId;
  final String scrollback;
  final int seq;

  const TerminalSnapshotMessage({
    required this.id,
    required this.timestamp,
    required this.terminalId,
    required this.scrollback,
    required this.seq,
  });
}

class FileTreeSnapshotRequestMessage {
  final String id;
  final int timestamp;

  const FileTreeSnapshotRequestMessage({
    required this.id,
    required this.timestamp,
  });
}

class FileTreeSnapshotMessage {
  final String id;
  final int timestamp;
  final FileNode tree;
  final int seq;

  const FileTreeSnapshotMessage({
    required this.id,
    required this.timestamp,
    required this.tree,
    required this.seq,
  });
}

class PreviewSnapshotRequestMessage {
  final String id;
  final int timestamp;

  const PreviewSnapshotRequestMessage({
    required this.id,
    required this.timestamp,
  });
}

class PreviewUrlEntry {
  final int port;
  final String url;
  final String? label;

  /// Detected dev-server scheme — mirrors the bridge's PreviewUrlEntrySchema
  /// (absent = unknown → http).
  final String? scheme;

  const PreviewUrlEntry({
    required this.port,
    required this.url,
    this.label,
    this.scheme,
  });

  static PreviewUrlEntry? fromJson(Map<String, dynamic> json) {
    final port = json['port'];
    final url = json['url'];
    if (port is! int || url is! String) return null;
    return PreviewUrlEntry(
      port: port,
      url: url,
      label: json['label'] as String?,
      scheme: json['scheme'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'port': port,
    'url': url,
    if (label != null) 'label': label,
    if (scheme != null) 'scheme': scheme,
  };
}

/// A single preview entry pushed live, as opposed to the full
/// [PreviewSnapshotMessage] replayed on welcome. Same payload shape as one
/// [PreviewUrlEntry], so it merges through the identical path.
class PreviewUrlMessage {
  final String id;
  final int timestamp;
  final PreviewUrlEntry entry;

  const PreviewUrlMessage({
    required this.id,
    required this.timestamp,
    required this.entry,
  });
}

class PreviewSnapshotMessage {
  final String id;
  final int timestamp;
  final List<PreviewUrlEntry> urls;

  const PreviewSnapshotMessage({
    required this.id,
    required this.timestamp,
    required this.urls,
  });
}

// --- Parser ---

Object? parseAbMessage(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  final id = json['id'] as String? ?? '';
  final timestamp = json['timestamp'] as int? ?? 0;

  switch (type) {
    case 'agent:hello':
      final version = json['version'];
      if (version is! String) return null;
      return AgentHello.fromJson(json);

    case 'agent:status':
      final terminalsJson = json['terminals'];
      final terminals = <TerminalStatusInfo>[];
      if (terminalsJson is List) {
        for (final t in terminalsJson) {
          if (t is Map<String, dynamic>) {
            final info = TerminalStatusInfo.fromJson(t);
            if (info != null) terminals.add(info);
          }
        }
      }
      final agentJson = json['agent'];
      final agent = agentJson is Map<String, dynamic>
          ? AgentInfo.fromJson(agentJson)
          : null;

      final layoutJson = json['layout'];
      final layout = layoutJson is Map<String, dynamic>
          ? LayoutConfig.fromJson(layoutJson)
          : null;

      final commandsJson = json['commands'];
      final commands = <CommandInfo>[];
      if (commandsJson is List) {
        for (final c in commandsJson) {
          if (c is Map<String, dynamic>) {
            final info = CommandInfo.fromJson(c);
            if (info != null) commands.add(info);
          }
        }
      }

      final proxiesJson = json['proxies'];
      final proxies = <ProxyStatusInfo>[];
      if (proxiesJson is List) {
        for (final p in proxiesJson) {
          if (p is Map<String, dynamic>) {
            final info = ProxyStatusInfo.fromJson(p);
            if (info != null) proxies.add(info);
          }
        }
      }

      final gitJson = json['git'];
      final git = gitJson is Map<String, dynamic>
          ? GitInfo.fromJson(gitJson)
          : null;

      final servicesJson = json['services'];
      final services = <ServiceStatus>[];
      if (servicesJson is List) {
        for (final s in servicesJson) {
          if (s is Map<String, dynamic>) {
            final info = ServiceStatus.fromJson(s);
            if (info != null) services.add(info);
          }
        }
      }

      return AgentStatusMessage(
        id: id,
        timestamp: timestamp,
        projectId: json['projectId'] as String?,
        terminals: terminals,
        services: services,
        agent: agent,
        layout: layout,
        commands: commands.isEmpty ? null : commands,
        proxies: proxies.isEmpty ? null : proxies,
        git: git,
        needsFirstRun: json['needsFirstRun'] as bool?,
      );

    case 'terminal:output':
      final terminalId = json['terminalId'];
      final data = json['data'];
      if (terminalId is! String || data is! String) return null;
      return TerminalOutputMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
        data: data,
        seq: json['seq'] as int?,
      );

    case 'terminal:started':
      final terminalId = json['terminalId'];
      if (terminalId is! String) return null;
      return TerminalStartedMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
        shell: json['shell'] as String?,
        cols: json['cols'] as int?,
        rows: json['rows'] as int?,
        terminalType: json['terminalType'] as String?,
      );

    case 'terminal:exited':
      final terminalId = json['terminalId'];
      if (terminalId is! String) return null;
      return TerminalExitedMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
        exitCode: json['exitCode'] as int?,
      );

    case 'terminal:size':
      final terminalId = json['terminalId'];
      final cols = json['cols'];
      final rows = json['rows'];
      final driverClientId = json['driverClientId'];
      if (terminalId is! String ||
          cols is! int ||
          rows is! int ||
          driverClientId is! String) {
        return null;
      }
      return TerminalSizeMessage(
        terminalId: terminalId,
        cols: cols,
        rows: rows,
        driverClientId: driverClientId,
      );

    case 'terminal:notification':
      final terminalId = json['terminalId'];
      final kind = json['kind'];
      if (terminalId is! String || kind is! String) return null;
      return TerminalNotificationMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
        kind: kind,
        title: json['title'] as String?,
        body: json['body'] as String?,
      );

    case 'notification:push':
      final notificationType = json['notificationType'];
      if (notificationType is! String) return null;
      return NotificationPushMessage(
        id: id,
        timestamp: timestamp,
        notificationType: notificationType,
        message: json['message'] as String?,
        sessionTitle: json['sessionTitle'] as String?,
        sessionId: json['sessionId'] as String?,
        projectId: json['projectId'] as String?,
      );

    case 'tree:full':
      final projectId = json['projectId'];
      final rootJson = json['root'];
      if (projectId is! String || rootJson is! Map<String, dynamic>) {
        return null;
      }
      final root = FileNode.fromJson(rootJson);
      if (root == null) return null;
      return TreeFullMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        root: root,
        seq: json['seq'] as int?,
      );

    case 'tree:update':
      final projectId = json['projectId'];
      if (projectId is! String) return null;
      final added = <FileNode>[];
      final addedJson = json['added'];
      if (addedJson is List) {
        for (final a in addedJson) {
          if (a is Map<String, dynamic>) {
            final node = FileNode.fromJson(a);
            if (node != null) added.add(node);
          }
        }
      }
      final modified = <FileNode>[];
      final modifiedJson = json['modified'];
      if (modifiedJson is List) {
        for (final m in modifiedJson) {
          if (m is Map<String, dynamic>) {
            final node = FileNode.fromJson(m);
            if (node != null) modified.add(node);
          }
        }
      }
      final removed = <String>[];
      final removedJson = json['removed'];
      if (removedJson is List) {
        for (final r in removedJson) {
          if (r is String) removed.add(r);
        }
      }
      return TreeUpdateMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        added: added,
        modified: modified,
        removed: removed,
        seq: json['seq'] as int?,
      );

    case 'file:content':
      final projectId = json['projectId'];
      final path = json['path'];
      if (projectId is! String || path is! String) return null;
      return FileContentMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        path: path,
        content: json['content'] as String?,
        size: json['size'] as int? ?? 0,
        error: json['error'] as String?,
        encoding: json['encoding'] as String? ?? 'utf8',
        mimeType: json['mimeType'] as String?,
      );

    case 'ports:update':
      final projectId = json['projectId'];
      if (projectId is! String) return null;
      final portsJson = json['ports'];
      if (portsJson is! List) return null;
      final ports = <PortInfo>[];
      for (final p in portsJson) {
        if (p is Map<String, dynamic>) {
          final info = PortInfo.fromJson(p);
          if (info != null) ports.add(info);
        }
      }
      return PortsUpdateMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        ports: ports,
      );

    case 'tunnel:http-response':
      return TunnelHttpResponse.fromJson(json);

    case 'command:output':
      final projectId = json['projectId'];
      final commandName = json['commandName'];
      final data = json['data'];
      if (projectId is! String || commandName is! String || data is! String) {
        return null;
      }
      return CommandOutputMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        commandName: commandName,
        data: data,
      );

    case 'command:done':
      final projectId = json['projectId'];
      final commandName = json['commandName'];
      if (projectId is! String || commandName is! String) return null;
      return CommandDoneMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        commandName: commandName,
        exitCode: json['exitCode'] as int?,
      );

    case 'git:status':
      final projectId = json['projectId'];
      if (projectId is! String) return null;
      final filesJson = json['files'];
      final files = <GitFileStatusEntry>[];
      if (filesJson is List) {
        for (final f in filesJson) {
          if (f is Map<String, dynamic>) {
            final entry = GitFileStatusEntry.fromJson(f);
            if (entry != null) files.add(entry);
          }
        }
      }
      return GitStatusMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        files: files,
      );

    case 'git:diff-content':
      final projectId = json['projectId'];
      final path = json['path'];
      if (projectId is! String || path is! String) return null;
      return GitDiffContentMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        path: path,
        diff: json['diff'] as String?,
        additions: json['additions'] as int? ?? 0,
        deletions: json['deletions'] as int? ?? 0,
      );

    case 'git:branches':
      final projectId = json['projectId'];
      final current = json['current'];
      if (projectId is! String || current is! String) return null;
      final branchesJson = json['branches'];
      final branches = <String>[];
      if (branchesJson is List) {
        for (final b in branchesJson) {
          if (b is String) branches.add(b);
        }
      }
      return GitBranchesMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        current: current,
        branches: branches,
      );

    case 'git:checkout-result':
      final projectId = json['projectId'];
      final branch = json['branch'];
      final success = json['success'];
      if (projectId is! String || branch is! String || success is! bool) {
        return null;
      }
      return GitCheckoutResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        branch: branch,
        success: success,
        error: json['error'] as String?,
      );

    case 'git:commit-result':
      final projectId = json['projectId'];
      final success = json['success'];
      if (projectId is! String || success is! bool) return null;
      return GitCommitResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        success: success,
        sha: json['sha'] as String?,
        error: json['error'] as String?,
      );

    case 'git:discard-result':
      final projectId = json['projectId'];
      final success = json['success'];
      if (projectId is! String || success is! bool) return null;
      final filesJson = json['files'];
      final files = <String>[];
      if (filesJson is List) {
        for (final f in filesJson) {
          if (f is String) files.add(f);
        }
      }
      return GitDiscardResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        success: success,
        files: files,
        error: json['error'] as String?,
      );

    case 'git:stage-result':
      final stageProjectId = json['projectId'];
      final stageSuccess = json['success'];
      if (stageProjectId is! String || stageSuccess is! bool) return null;
      final stageFilesJson = json['files'];
      final stageFiles = <String>[];
      if (stageFilesJson is List) {
        for (final f in stageFilesJson) {
          if (f is String) stageFiles.add(f);
        }
      }
      return GitStageResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: stageProjectId,
        success: stageSuccess,
        files: stageFiles,
        error: json['error'] as String?,
      );

    case 'git:unstage-result':
      final unstageProjectId = json['projectId'];
      final unstageSuccess = json['success'];
      if (unstageProjectId is! String || unstageSuccess is! bool) return null;
      final unstageFilesJson = json['files'];
      final unstageFiles = <String>[];
      if (unstageFilesJson is List) {
        for (final f in unstageFilesJson) {
          if (f is String) unstageFiles.add(f);
        }
      }
      return GitUnstageResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: unstageProjectId,
        success: unstageSuccess,
        files: unstageFiles,
        error: json['error'] as String?,
      );

    case 'file:search-result':
      final projectId = json['projectId'];
      final requestId = json['requestId'];
      if (projectId is! String || requestId is! String) return null;
      final matchesJson = json['matches'];
      final matches = <SearchMatchEntry>[];
      if (matchesJson is List) {
        for (final m in matchesJson) {
          if (m is Map<String, dynamic>) {
            final entry = SearchMatchEntry.fromJson(m);
            if (entry != null) matches.add(entry);
          }
        }
      }
      return FileSearchResultMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        requestId: requestId,
        matches: matches,
      );

    case 'file:search-done':
      final projectId = json['projectId'];
      final requestId = json['requestId'];
      final totalMatches = json['totalMatches'];
      final totalFiles = json['totalFiles'];
      final duration = json['duration'];
      final engine = json['engine'];
      if (projectId is! String ||
          requestId is! String ||
          totalMatches is! int ||
          totalFiles is! int ||
          duration is! int ||
          engine is! String) {
        return null;
      }
      return FileSearchDoneMessage(
        id: id,
        timestamp: timestamp,
        projectId: projectId,
        requestId: requestId,
        totalMatches: totalMatches,
        totalFiles: totalFiles,
        duration: duration,
        engine: engine,
        error: json['error'] as String?,
      );

    case 'client:focus-state':
      final paused = json['paused'];
      if (paused is! bool) return null;
      return ClientFocusStateMessage(
        id: id,
        timestamp: timestamp,
        paused: paused,
      );

    case 'terminal:snapshot:request':
      final terminalId = json['terminalId'];
      if (terminalId is! String) return null;
      return TerminalSnapshotRequestMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
      );

    case 'terminal:snapshot':
      final terminalId = json['terminalId'];
      final scrollback = json['scrollback'];
      final seq = json['seq'];
      if (terminalId is! String || scrollback is! String || seq is! int) {
        return null;
      }
      return TerminalSnapshotMessage(
        id: id,
        timestamp: timestamp,
        terminalId: terminalId,
        scrollback: scrollback,
        seq: seq,
      );

    case 'file:tree:snapshot:request':
      return FileTreeSnapshotRequestMessage(id: id, timestamp: timestamp);

    case 'file:tree:snapshot':
      final treeJson = json['tree'];
      final seq = json['seq'];
      if (treeJson is! Map<String, dynamic> || seq is! int) return null;
      final tree = FileNode.fromJson(treeJson);
      if (tree == null) return null;
      return FileTreeSnapshotMessage(
        id: id,
        timestamp: timestamp,
        tree: tree,
        seq: seq,
      );

    case 'preview:snapshot:request':
      return PreviewSnapshotRequestMessage(id: id, timestamp: timestamp);

    case 'preview:url':
      {
        final entry = PreviewUrlEntry.fromJson(json);
        if (entry == null) return null;
        return PreviewUrlMessage(id: id, timestamp: timestamp, entry: entry);
      }

    case 'preview:snapshot':
      final urlsJson = json['urls'];
      final urls = <PreviewUrlEntry>[];
      if (urlsJson is List) {
        for (final u in urlsJson) {
          if (u is Map<String, dynamic>) {
            final entry = PreviewUrlEntry.fromJson(u);
            if (entry != null) urls.add(entry);
          }
        }
      }
      return PreviewSnapshotMessage(id: id, timestamp: timestamp, urls: urls);

    case 'handler:status':
      {
        final projectId = json['projectId'];
        final sessionsJson = json['sessions'];
        if (projectId is! String || sessionsJson is! List) return null;
        final sessions = <Map<String, dynamic>>[];
        for (final s in sessionsJson) {
          if (s is Map<String, dynamic>) sessions.add(s);
        }
        // Absent is empty, not a parse failure: a bridge older than the undo
        // offer still has to deliver its armed sessions.
        final snapshotsJson = json['snapshots'];
        final snapshots = <Map<String, dynamic>>[];
        if (snapshotsJson is List) {
          for (final s in snapshotsJson) {
            if (s is Map<String, dynamic>) snapshots.add(s);
          }
        }
        return HandlerStatusMessage(
          id: id,
          timestamp: timestamp,
          projectId: projectId,
          defaultTool: json['defaultTool'] is String
              ? json['defaultTool'] as String
              : null,
          defaultNotifyOnly: json['defaultNotifyOnly'] == true,
          sessions: sessions,
          snapshots: snapshots,
        );
      }

    case 'handler:snapshot':
      {
        final projectId = json['projectId'];
        if (projectId is! String) return null;
        return HandlerSnapshotMessage(
          id: id,
          timestamp: timestamp,
          projectId: projectId,
          snapshot: json,
        );
      }

    case 'handler:escalation':
      {
        final projectId = json['projectId'];
        final escalationId = json['escalationId'];
        final terminalId = json['terminalId'];
        final question = json['question'];
        final reasoning = json['reasoning'];
        final draftReply = json['draftReply'];
        final urgency = json['urgency'];
        if (projectId is! String ||
            escalationId is! String ||
            terminalId is! String ||
            question is! String ||
            reasoning is! String ||
            draftReply is! String ||
            urgency is! String) {
          return null;
        }
        final floorRule = json['floorRule'];
        final kind = json['kind'] is String ? json['kind'] as String : null;
        return HandlerEscalationMessage(
          id: id,
          timestamp: timestamp,
          projectId: projectId,
          escalationId: escalationId,
          terminalId: terminalId,
          question: question,
          reasoning: reasoning,
          draftReply: draftReply,
          urgency: urgency,
          // is-check, not a cast: parseAbMessage has no try/catch, so a
          // non-string here would throw out of the message stream instead of
          // degrading to "no floor rule".
          floorRule: floorRule is String ? floorRule : null,
          kind: kind,
          choices: HandlerEscalationChoice.listFromWire(
            json['choices'],
            kind: kind,
          ),
        );
      }

    case 'handler:activity':
      {
        final projectId = json['projectId'];
        final recordId = json['recordId'];
        final at = json['at'];
        final terminalId = json['terminalId'];
        final decision = json['decision'];
        final reason = json['reason'];
        if (projectId is! String ||
            recordId is! String ||
            at is! num ||
            terminalId is! String ||
            decision is! String ||
            reason is! String) {
          return null;
        }
        return HandlerActivityMessage(
          id: id,
          timestamp: timestamp,
          projectId: projectId,
          recordId: recordId,
          at: at.toInt(),
          terminalId: terminalId,
          decision: decision,
          reason: reason,
          detail: json['detail'] is String ? json['detail'] as String : null,
        );
      }

    case 'agent:turn-start':
    case 'agent:session-reset':
    case 'agent:turn-end':
    case 'agent:item-added':
    case 'agent:item-delta':
    case 'agent:item-updated':
    case 'agent:transcript-replay':
    case 'agent:snapshot':
    case 'agent:permission-request':
    case 'agent:question':
    case 'agent:request-retracted':
    case 'agent:error':
    case 'agent:usage':
    case 'agent:background-tasks':
    case 'agent:capabilities':
    case 'agent:updateAvailable':
    case 'agent:updateResult':
      return parseAgentEvent(json);

    default:
      return null;
  }
}

// --- Outbound message builder ---

Map<String, dynamic> createAbMessage(String type, Map<String, dynamic> fields) {
  return {
    'type': type,
    'id': const Uuid().v4(),
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    ...fields,
  };
}
