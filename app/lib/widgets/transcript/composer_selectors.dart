import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart';
import '../../models/agent_event.dart';

/// MODEL / EFFORT / MODE selector pills for the transcript composer. Each pill
/// opens an [AbMenu] of the advertised options; picking one fires [onSetConfig].
/// Labels reflect only the bridge's echoed `current*` ids, with no optimistic
/// state, so each pill always shows what is actually applied.
class ComposerSelectors extends StatelessWidget {
  const ComposerSelectors({
    super.key,
    this.capabilities,
    required this.onSetConfig,
  });

  final AgentCapabilities? capabilities;
  final void Function(String key, String value) onSetConfig;

  @override
  Widget build(BuildContext context) {
    final caps = capabilities;
    final model = caps?.currentModel;
    final efforts = model?.efforts ?? const <String>[];
    final currentEffort = caps?.currentEffortId ?? model?.defaultEffort;
    AgentCapabilityMode? currentMode;
    for (final m in caps?.modes ?? const <AgentCapabilityMode>[]) {
      if (m.id == caps?.currentModeId) currentMode = m;
    }

    // Discovery still in flight: the model/effort/mode lists aren't populated
    // yet, so show a placeholder instead of an empty row (or a partial one that
    // pops in a pill at a time as claude's two frames arrive).
    final loading = caps != null && !caps.ready;

    final children = <Widget>[
      if (loading) _loadingIndicator(context),
      if (!loading && caps != null && caps.models.isNotEmpty)
        _pill(
          label: model?.name ?? 'model',
          header: 'model',
          configKey: 'model',
          entries: [
            for (final m in caps.models)
              AbMenuItem(
                label: m.provider == null
                    ? m.name
                    : '${m.name} · ${m.provider}',
                value: m.id,
                shortcut: m.id == caps.currentModelId ? '●' : null,
              ),
          ],
        ),
      if (!loading && efforts.isNotEmpty)
        _pill(
          label: currentEffort == null
              ? 'effort'
              : _displayLabel(currentEffort),
          header: 'effort',
          configKey: 'effort',
          entries: [
            for (final e in efforts)
              AbMenuItem(
                label: _displayLabel(e),
                value: e,
                shortcut: e == currentEffort ? '●' : null,
              ),
          ],
        ),
      if (!loading && caps != null && caps.modes.isNotEmpty)
        _pill(
          label: currentMode == null ? 'mode' : _displayLabel(currentMode.name),
          header: 'mode',
          configKey: 'mode',
          entries: [
            for (final m in caps.modes)
              AbMenuItem(
                label: _displayLabel(m.name),
                value: m.id,
                shortcut: m.id == caps.currentModeId ? '●' : null,
              ),
          ],
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    // No outer padding: this row is docked inside the composer surface's
    // control strip (agent_transcript_view), which owns the insets.
    return Wrap(
      spacing: AbTokens.space4,
      runSpacing: AbTokens.space4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  // Inline "discovering models…" placeholder shown while capabilities load.
  Widget _loadingIndicator(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: AbTokens.space10,
          height: AbTokens.space14,
          child: AbLoading(size: AbTokens.space8),
        ),
        const SizedBox(width: AbTokens.space8),
        Text(
          'loading models…',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: context.antgrid.textMuted,
          ),
        ),
      ],
    ),
  );

  // Builder gives each chip its own context so the menu anchors to the chip's
  // render box, not the whole row.
  Widget _pill({
    required String label,
    required String header,
    required String configKey,
    required List<AbMenuItem> entries,
  }) => Builder(
    builder: (chipContext) => AbChip.toggle(
      label: label,
      selected: false,
      onTap: () => _open(
        chipContext,
        header: header,
        configKey: configKey,
        entries: entries,
      ),
    ),
  );

  // codex/opencode expose mode/effort ids as the only label (":read-only",
  // "xhigh") with no separate display name; title-case them for the UI only
  // — the raw id is still what's sent in onSetConfig.
  static String _displayLabel(String raw) {
    final stripped = raw.startsWith(':') ? raw.substring(1) : raw;
    final words = stripped.split(RegExp(r'[-_]+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return stripped;
    return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  Future<void> _open(
    BuildContext context, {
    required String header,
    required String configKey,
    required List<AbMenuItem> entries,
  }) async {
    final anchorRect = abMenuAnchorRect(context);
    if (anchorRect == null) return;
    final picked = await showAbMenu<String>(
      context: context,
      anchorRect: anchorRect,
      preferred: AbMenuPlacement.above,
      header: header,
      entries: entries,
    );
    if (picked != null) onSetConfig(configKey, picked);
  }
}
