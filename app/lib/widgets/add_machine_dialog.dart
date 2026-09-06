import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_text_field.dart';
import '../models/agent_event.dart';
import '../models/session_entry.dart';
import '../models/session_target.dart';
import '../providers/add_machine_action.dart';
import '../providers/agent_catalog.dart';
import '../providers/capability_catalog.dart';
import '../providers/control_plane.dart';
import '../providers/device_provisioning.dart';
import '../providers/machine_capability_card.dart';
import '../providers/new_session_picker.dart';
import '../providers/projects.dart';
import '../providers/sessions.dart';
import '../services/control_plane_client.dart';
import '../util/detached.dart';
import '../util/git_remote_match.dart';
import 'new_session/environment_menu.dart';
import 'new_session/picker_sources.dart';

/// Asks which other machine should join the session [leadSessionId] leads, and
/// what it is being asked to do (§7.5).
///
/// Nothing is created while this is open. Every control is local `State` and the
/// only traffic before Add is read-only — the machines' advertised projects,
/// their Capability Cards, and their installed tools — so a cancelled dialog
/// leaves no session anywhere.
///
/// [leadRegistrationId] is a LOCAL project id: only the lead machine's own app
/// owns the loopback socket that carries the link (D7), which is what the
/// kebab's visibility rule enforces before this opens.
Future<void> promptAddMachine(
  BuildContext context, {
  required String leadRegistrationId,
  required String leadSessionId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddMachineDialog(
      leadRegistrationId: leadRegistrationId,
      leadSessionId: leadSessionId,
    ),
  );
}

class _AddMachineDialog extends ConsumerStatefulWidget {
  const _AddMachineDialog({
    required this.leadRegistrationId,
    required this.leadSessionId,
  });

  final String leadRegistrationId;
  final String leadSessionId;

  @override
  ConsumerState<_AddMachineDialog> createState() => _AddMachineDialogState();
}

class _AddMachineDialogState extends ConsumerState<_AddMachineDialog> {
  String? _machineUuid;
  String? _machineLabel;

  /// Null means "whatever the repo match suggests" — the pre-selection is
  /// computed on every build rather than written into state, so a machine
  /// change re-derives it instead of stranding the previous machine's project
  /// in a field the user never touched.
  PickerProject? _project;

  String? _tool;
  String? _model;

  late final TextEditingController _brief;
  bool _briefEmpty = true;

  @override
  void initState() {
    super.initState();
    _brief = TextEditingController()..addListener(_onBriefChanged);
  }

  @override
  void dispose() {
    _brief.removeListener(_onBriefChanged);
    _brief.dispose();
    super.dispose();
  }

  void _onBriefChanged() {
    final empty = _brief.text.trim().isEmpty;
    if (empty != _briefEmpty) setState(() => _briefEmpty = empty);
  }

  void _cancel() => Navigator.of(context).pop();

  // Derived in build and read back by the press handlers below. Every one of
  // them comes out of a `ref.watch`, which is legal only while building; a
  // handler that recomputed them would be reading providers from a gesture.
  Set<String> _machinesInUse = const {};
  List<PickerProject> _projectRows = const [];
  PickerProject? _resolvedProject;
  RepoCard? _repoCard;
  SessionMemberCard? _memberCard;
  SessionMemberCard? _leadCard;

  /// Machines already carrying an active member of this session. A second
  /// session on a machine that is already in is not refused by the bridge, but
  /// it is never what the user meant by "add a machine".
  Set<String> _readMachinesInUse() {
    final session = ref.watch(activeSessionOrCachedProvider);
    if (session == null) return const {};
    return {
      for (final m in session.members)
        if (m.isActive) m.ref.machineId,
    };
  }

  List<PickerProject> _readProjectRows() {
    final uuid = _machineUuid;
    if (uuid == null) return const [];
    final state = ref.watch(controlPlaneStateProvider(uuid)).value;
    if (state == null) return const [];
    return buildRemoteProjectRows(uuid, state.projects);
  }

  /// The project the dialog is acting on: the user's own pick, else the one
  /// whose normalised remote matches the lead's.
  ///
  /// Derived rather than written into state on the machine pick, so a card that
  /// arrives after the pick still pre-selects, and changing machine cannot
  /// strand the previous machine's project in a field nobody touched.
  PickerProject? _readResolvedProject(List<PickerProject> rows) {
    if (_project != null) return _project;
    final uuid = _machineUuid;
    if (uuid == null) return null;
    final card = ref.watch(machineCapabilityCardProvider(uuid)).value;
    if (card == null) return null;
    final leadRemote = ref
        .watch(localProjectRemoteProvider(widget.leadRegistrationId))
        .value;
    final matchId = preselectProjectByRemote(
      leadRemote: leadRemote,
      candidateRemotes: {
        for (final e in card.projects.entries) e.key: e.value.remote,
      },
    );
    if (matchId == null) return null;
    for (final row in rows) {
      if (row.projectId == matchId) return row;
    }
    return null;
  }

  RepoCard? _readRepoCard(PickerProject? project) {
    final uuid = _machineUuid;
    final projectId = project?.projectId;
    if (uuid == null || projectId == null) return null;
    return ref
        .watch(machineCapabilityCardProvider(uuid))
        .value
        ?.projects[projectId];
  }

  /// The card as the membership carries it: the machine's OS beside the repo of
  /// the project that was picked, which is the pair the lead's agent is told.
  ///
  /// Null while the card is still in flight, and null for a machine that
  /// answered nothing — Add stays available either way, because a membership
  /// with no card is a machine joined and a refused one is not.
  SessionMemberCard? _readMemberCard(RepoCard? repo) {
    final uuid = _machineUuid;
    if (uuid == null) return null;
    final os = ref.watch(machineCapabilityCardProvider(uuid)).value?.os;
    if (os == null && repo == null) return null;
    final card = SessionMemberCard(
      osName: os?.name,
      osVersion: os?.version,
      osArch: os?.arch,
      repoLabel: repo?.label,
      repoRemote: repo?.remote,
      repoBranch: repo?.branch,
    );
    return card.isEmpty ? null : card;
  }

  /// THIS machine's card for the lead's project, as the peer's row will record
  /// it — the mirror of [_readMemberCard], read locally instead of over the
  /// control plane.
  ///
  /// The peer needs it because nothing else can tell it: a card may not ride in
  /// the brief, whose armed-Handler route runs `authorizeInstruction` over the
  /// whole text and reads a hostname or a repo path as a grant (see
  /// session-bus/delivery.ts). Carried on the membership, it reaches the peer's
  /// agent only through `antgrid_session_status`, which is a result the agent
  /// asked for rather than a prompt written into it.
  SessionMemberCard? _readLeadCard() {
    final id = widget.leadRegistrationId;
    final local = ref.watch(localCapabilityCardProvider(id)).value;
    if (local == null) return null;
    // A card is answered for the whole machine, so the OS half is always there;
    // the repo half is a lookup, and a project the host does not advertise is
    // omitted rather than reported empty.
    final repo = local.projects[id];
    final card = SessionMemberCard(
      osName: local.os.name,
      osVersion: local.os.version,
      osArch: local.os.arch,
      repoLabel: repo?.label,
      repoRemote: repo?.remote,
      repoBranch: repo?.branch,
    );
    return card.isEmpty ? null : card;
  }

  SessionTarget? get _peerTarget {
    final uuid = _machineUuid;
    final projectId = _resolvedProject?.projectId;
    if (uuid == null || projectId == null) return null;
    return RemoteProject(machineUuid: uuid, projectId: projectId);
  }

  bool get _canAdd =>
      _machineUuid != null &&
      _resolvedProject != null &&
      _tool != null &&
      !_briefEmpty;

  void _pickMachine(String uuid, String label) {
    setState(() {
      _machineUuid = uuid;
      _machineLabel = label;
      // Every downstream pick is scoped to the machine — a project id, an
      // installed tool and that tool's model catalog are all per-machine — so
      // carrying any of them across would name something that may not exist
      // there.
      _project = null;
      _tool = null;
      _model = null;
    });
  }

  void _pickProject(PickerProject project) {
    setState(() {
      _project = project;
      _tool = null;
      _model = null;
    });
  }

  void _pickTool(String tool) {
    setState(() {
      _tool = tool;
      // The model is an id the previous CLI understood; the new one rejects it
      // on every pass. Same reason `_JudgePanel._pickJudge` clears it.
      _model = null;
    });
  }

  void _add() {
    final peer = _peerTarget;
    final project = _resolvedProject;
    final tool = _tool;
    if (peer is! RemoteProject || project == null || tool == null) return;

    final container = ref.container;
    // The navigator's own context, not this dialog's: the report below lands
    // long after this route is gone.
    final navigator = Navigator.of(context);
    final host = navigator.context;
    final leadRef = _leadRef();
    final brief = _brief.text.trim();
    final model = _model;
    final peerCard = _memberCard;
    final add = container.read(addMachineActionProvider);

    navigator.pop();
    detached('AddMachine', 'add machine to session failed', () async {
      final outcome = await add(
        container,
        leadRegistrationId: widget.leadRegistrationId,
        leadSessionId: widget.leadSessionId,
        leadRef: leadRef,
        peer: peer,
        tool: tool,
        brief: brief,
        model: model,
        // Always terminal: a chat session gets no Antgrid MCP server at all
        // (see the driver's own comment, e.g. claude-code/driver.ts), so a
        // chat peer would have no session-bus tools and could never receive
        // a task, report, or ask the lead.
        mode: 'terminal',
        sessionName: project.name,
        peerMachineLabel: _machineLabel,
        peerProjectLabel: project.name,
        peerCard: peerCard,
      );
      // The message, not the error: a join that landed can still owe the user a
      // sentence — a peer whose agent would not start is added and idle, which
      // is nothing they can see from the member tab alone.
      final message = outcome.message;
      if (message != null && host.mounted) showAbSnackBar(host, message);
    });
  }

  /// The lead half of the membership, as the peer's row will record it.
  ///
  /// Labels and the card are best-effort by schema, and the ones that exist are
  /// worth carrying: they are the only account a peer machine that has never
  /// dialled this one has of the session it answers to.
  SessionMemberRef _leadRef() {
    final machineId = ref.read(localDeviceUuidProvider).value ?? '';
    String? projectLabel;
    String? machineLabel;
    for (final p in ref.read(projectsProvider)) {
      if (p.projectId != widget.leadRegistrationId) continue;
      projectLabel = p.displayName;
      machineLabel = p.hostMachineName;
      break;
    }
    return SessionMemberRef(
      machineId: machineId,
      projectId: widget.leadRegistrationId,
      sessionId: widget.leadSessionId,
      machineLabel: machineLabel,
      projectLabel: projectLabel,
      sessionName: ref.read(activeSessionOrCachedProvider)?.name,
      card: _leadCard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    _machinesInUse = _readMachinesInUse();
    _projectRows = _readProjectRows();
    _resolvedProject = _readResolvedProject(_projectRows);
    _repoCard = _readRepoCard(_resolvedProject);
    _memberCard = _readMemberCard(_repoCard);
    _leadCard = _readLeadCard();
    final project = _resolvedProject;
    final peer = _peerTarget;
    final card = _repoCard;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              abDialogTitle('Add machine', onClose: _cancel),
              const SizedBox(height: AbTokens.space12),
              Text(
                'Another machine starts a session of its own and joins this '
                'one. It is told the brief below, and the two can talk while '
                'they work.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              _FieldRow(
                label: 'Machine',
                child: ComposerChip(
                  icon: AbIcons.deviceDesktop,
                  label: _machineLabel ?? 'Select machine…',
                  attention: _machineUuid == null,
                  onTap: _openMachinePane,
                ),
              ),
              _FieldRow(
                label: 'Project',
                child: ComposerChip(
                  icon: AbIcons.folder,
                  label: project?.name ?? 'Select project…',
                  attention: _machineUuid != null && project == null,
                  enabled: _machineUuid != null,
                  onTap: _openProjectPane,
                ),
              ),
              if (card != null) _CardLine(card: card),
              _FieldRow(
                label: 'Agent',
                child: ComposerChip(
                  icon: AbIcons.terminal,
                  label: _toolLabel(),
                  secondaryLabel: _model,
                  attention: project != null && _tool == null,
                  enabled: peer != null,
                  onTap: _openToolPane,
                ),
              ),
              _FieldRow(
                label: 'Model',
                child: ComposerChip(
                  icon: AbIcons.code,
                  label: _model ?? 'Default',
                  enabled: peer != null && _tool != null,
                  onTap: _openModelPane,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              Text(
                'Brief',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space6),
              AbTextField(
                controller: _brief,
                hintText: 'What is this machine being asked to do?',
                minLines: 3,
                maxLines: 6,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(kMaxBriefChars),
                ],
              ),
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(label: 'Cancel', onTap: _cancel),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: 'Add',
                    variant: AbButtonVariant.primary,
                    onTap: _canAdd ? _add : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _toolLabel() {
    final tool = _tool;
    if (tool == null) return 'Select agent…';
    final peer = _peerTarget;
    final detected = peer == null
        ? null
        : ref.watch(detectedToolsForProvider(peer)).value?[tool];
    return detected ?? ref.watch(agentCatalogProvider)[tool]?.label ?? tool;
  }

  Future<void> _openPane(
    BuildContext anchor,
    WidgetBuilder builder, {
    double width = 280,
  }) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    await showAbPanel<void>(
      context: anchor,
      anchorRect: rect,
      width: width,
      builder: builder,
    );
  }

  void _openMachinePane(BuildContext anchor) {
    final inUse = _machinesInUse;
    detached('AddMachine', 'machine pane failed', () {
      return _openPane(
        anchor,
        (_) => _MachinePane(
          excludedMachineIds: inUse,
          selected: _machineUuid,
          onPick: _pickMachine,
        ),
      );
    });
  }

  void _openProjectPane(BuildContext anchor) {
    final rows = _projectRows;
    final selectedId = _resolvedProject?.id;
    detached('AddMachine', 'project pane failed', () {
      return _openPane(anchor, (paneContext) {
        if (rows.isEmpty) {
          return const PanelHint(
            'This machine is offline, or remote access is off for it.',
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PanelSectionHeader('Project'),
            for (final row in rows)
              PanelRow(
                icon: AbIcons.folder,
                label: row.name,
                selected: row.id == selectedId,
                onTap: () {
                  Navigator.of(paneContext).pop();
                  _pickProject(row);
                },
              ),
          ],
        );
      });
    });
  }

  void _openToolPane(BuildContext anchor) {
    final peer = _peerTarget;
    if (peer == null) return;
    detached('AddMachine', 'agent pane failed', () {
      return _openPane(
        anchor,
        (paneContext) => _ToolPane(
          target: peer,
          selected: _tool,
          onPick: (tool) {
            Navigator.of(paneContext).pop();
            _pickTool(tool);
          },
        ),
      );
    });
  }

  void _openModelPane(BuildContext anchor) {
    final peer = _peerTarget;
    final tool = _tool;
    if (peer == null || tool == null) return;
    detached('AddMachine', 'model pane failed', () {
      return _openPane(
        anchor,
        (paneContext) => _ModelPane(
          target: peer,
          tool: tool,
          selected: _model,
          onPick: (model) {
            Navigator.of(paneContext).pop();
            setState(() => _model = model);
          },
        ),
      );
    });
  }
}

/// A labelled control row, so every pick in the dialog reads down one column.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AbTokens.space6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ),
          Flexible(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }
}

/// What the picked machine says about the picked project — read-only, and shown
/// only once both resolve.
///
/// The remote is rendered as the matching key it is, never as a URL to dial:
/// it is what tells the user this really is the same repo before they hand the
/// machine a brief.
class _CardLine extends StatelessWidget {
  const _CardLine({required this.card});

  final RepoCard card;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final parts = [?card.branch, ?card.remote];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 68, bottom: AbTokens.space8),
      child: Text(
        parts.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: p.textMuted,
        ),
      ),
    );
  }
}

/// The machines that may join, from the same rail sources the composer picks
/// from. The lead's own machine is excluded in MVP (§7.5), and so is every
/// machine already holding an active member.
class _MachinePane extends ConsumerWidget {
  const _MachinePane({
    required this.excludedMachineIds,
    required this.selected,
    required this.onPick,
  });

  final Set<String> excludedMachineIds;
  final String? selected;
  final void Function(String uuid, String label) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = [
      for (final s in ref.watch(pickerSourcesProvider))
        if (!s.isLocal &&
            s.machineUuid != null &&
            !excludedMachineIds.contains(s.machineUuid))
          s,
    ];
    if (sources.isEmpty) {
      return const PanelHint('No other machine is signed in to this account.');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Machine'),
        for (final source in sources)
          _MachineRow(
            uuid: source.machineUuid!,
            label: source.label,
            selected: source.machineUuid == selected,
            onPick: onPick,
          ),
      ],
    );
  }
}

/// One machine row, live on its own control-plane state.
///
/// A machine advertises no projects when it is offline OR when its owner has
/// remote access switched off; both mean it cannot join, and neither is worth
/// a different row. Rendered disabled rather than hidden, so a machine the user
/// is looking for is visibly present-but-unavailable.
class _MachineRow extends ConsumerWidget {
  const _MachineRow({
    required this.uuid,
    required this.label,
    required this.selected,
    required this.onPick,
  });

  final String uuid;
  final String label;
  final bool selected;
  final void Function(String uuid, String label) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(controlPlaneStateProvider(uuid)).value?.projects;
    final available = projects != null && projects.isNotEmpty;
    return PanelRow(
      icon: AbIcons.deviceDesktop,
      label: label,
      selected: selected,
      onTap: available
          ? () {
              Navigator.of(context).pop();
              onPick(uuid, label);
            }
          : null,
    );
  }
}

/// The agents installed on the peer's machine, as that machine advertises them.
class _ToolPane extends ConsumerWidget {
  const _ToolPane({
    required this.target,
    required this.selected,
    required this.onPick,
  });

  final SessionTarget target;
  final String? selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detected = ref.watch(detectedToolsForProvider(target)).value;
    if (detected == null || detected.isEmpty) {
      return const PanelHint(
        'This machine has not said which agents it has installed.',
      );
    }
    final catalog = ref.watch(agentCatalogProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Agent'),
        for (final entry in detected.entries)
          PanelRow(
            icon: AbIcons.terminal,
            label: entry.value ?? catalog[entry.key]?.label ?? entry.key,
            selected: entry.key == selected,
            onTap: () => onPick(entry.key),
          ),
      ],
    );
  }
}

/// The models the peer's machine has heard this agent list, plus Default.
///
/// Empty is a real answer, not a loading state — a machine that has only ever
/// run this agent in a terminal has no catalog — so typing an id is always
/// available and is the ONLY way to name a model there.
class _ModelPane extends ConsumerStatefulWidget {
  const _ModelPane({
    required this.target,
    required this.tool,
    required this.selected,
    required this.onPick,
  });

  final SessionTarget target;
  final String tool;
  final String? selected;
  final ValueChanged<String?> onPick;

  @override
  ConsumerState<_ModelPane> createState() => _ModelPaneState();
}

class _ModelPaneState extends ConsumerState<_ModelPane> {
  late final TextEditingController _freeText;
  late final TextEditingController _search;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _freeText = TextEditingController(text: widget.selected ?? '');
    _search = TextEditingController()..addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _search.removeListener(_onQueryChanged);
    _search.dispose();
    _freeText.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() => _query = _search.text);

  void _commitFreeText(String text) {
    final trimmed = text.trim();
    widget.onPick(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final models = cachedModelsForSource(
      ref,
      capabilitySourceKey(widget.target),
      widget.tool,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Model'),
        // Above the filter and outside the searched list: putting the model
        // back must never require clearing a query first.
        PanelRow(
          icon: AbIcons.code,
          label: 'Default',
          selected: widget.selected == null,
          onTap: () => widget.onPick(null),
        ),
        if (models.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.all(AbTokens.space8),
            child: AbTextField(
              controller: _freeText,
              hintText: 'Model id',
              autofocus: true,
              // Committed on submit, not per keystroke: a half-typed id is one
              // the agent would be started with.
              onSubmitted: _commitFreeText,
            ),
          ),
          const PanelHint(
            "This machine hasn't heard this agent list its models — type an id.",
          ),
        ] else
          ..._listBranch(models),
      ],
    );
  }

  List<Widget> _listBranch(List<AgentCapabilityModel> models) {
    final query = _query.trim().toLowerCase();
    final filtered = models.where((m) {
      if (query.isEmpty) return true;
      return m.name.toLowerCase().contains(query) ||
          m.id.toLowerCase().contains(query);
    }).toList();
    return [
      Padding(
        padding: const EdgeInsets.all(AbTokens.space8),
        child: AbTextField(
          controller: _search,
          hintText: 'Search models…',
          prefixIcon: AbIcons.search,
        ),
      ),
      const AbSeparator.horizontal(weight: AbSeparatorWeight.strong),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: filtered.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(AbTokens.space12),
                child: PanelHint('No matching models'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (_, index) {
                  final m = filtered[index];
                  return PanelRow(
                    icon: AbIcons.code,
                    label: m.name,
                    selected: m.id == widget.selected,
                    onTap: () => widget.onPick(m.id),
                  );
                },
              ),
      ),
    ];
  }
}
