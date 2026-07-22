import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../models/agent_event.dart';
import 'suggestion_panel.dart';

/// Prefix-filter [commands] against the composer's first token. [query] is the
/// token WITHOUT its leading slash.
List<AgentCapabilityCommand> filterSlashCommands(
  List<AgentCapabilityCommand> commands,
  String query,
) {
  final q = query.toLowerCase();
  return commands.where((c) => c.name.toLowerCase().startsWith(q)).toList();
}

/// Split a composer submission: a first token that matches an advertised
/// command (case-insensitively, mirroring [filterSlashCommands] — command
/// names come verbatim from the agent's filesystem/frontmatter, so mixed
/// case is realistic) becomes its commandId with only the args as text; an
/// unknown /token goes through verbatim as prompt text.
({String? commandId, String text}) resolveSubmission(
  String text,
  AgentCapabilities? caps,
) {
  if (caps == null || !text.startsWith('/')) {
    return (commandId: null, text: text);
  }
  final firstSpace = text.indexOf(' ');
  final name = (firstSpace < 0 ? text : text.substring(0, firstSpace))
      .substring(1)
      .toLowerCase();
  for (final c in caps.commands) {
    if (c.name.toLowerCase() == name) {
      final args = firstSpace < 0 ? '' : text.substring(firstSpace + 1).trim();
      return (commandId: c.id, text: args);
    }
  }
  return (commandId: null, text: text);
}

/// Suggestion panel rendered directly above the composer input while a slash
/// command is being typed. Pure display + tap: filtering, highlight index, and
/// keyboard handling live in the composer (it owns focus + controller).
class SlashSuggestions extends StatelessWidget {
  const SlashSuggestions({
    super.key,
    required this.commands,
    required this.selectedIndex,
    required this.onPick,
  });

  final List<AgentCapabilityCommand> commands;
  final int selectedIndex;
  final void Function(AgentCapabilityCommand command) onPick;

  @override
  Widget build(BuildContext context) {
    return SuggestionPanel<AgentCapabilityCommand>(
      items: commands,
      selectedIndex: selectedIndex,
      onPick: onPick,
      rowBuilder: _rowContent,
    );
  }

  Widget _rowContent(
    BuildContext context,
    AgentCapabilityCommand c,
    bool selected,
  ) {
    final colors = context.antgrid;
    return Row(
      children: [
        Text(
          '/${c.name}',
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            color: selected ? colors.textPrimary : colors.textSecondary,
          ),
        ),
        if (c.argHint != null) ...[
          const SizedBox(width: AbTokens.space4),
          Text(
            c.argHint!,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: colors.textMuted,
            ),
          ),
        ],
        if (c.description != null) ...[
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              c.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
