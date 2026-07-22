import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import 'handler_reply_sheet.dart';

class HandlerScreen extends ConsumerWidget {
  const HandlerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(handlerStateProvider).value;
    final p = context.antgrid;

    if (state == null || !state.enabled) {
      return Center(
        child: Text(
          'Handler is off — enable it from the agent header to supervise.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(color: p.textMuted),
        ),
      );
    }

    Future<void> answer(HandlerEscalation e) async {
      final service = serviceWhenReady(ref, handlerServiceProvider);
      if (service == null) return;
      final text = await showHandlerReplySheet(context, e);
      if (text == null) return;
      service.reply(e, text);
    }

    return ListView(
      children: [
        if (state.escalations.isNotEmpty) ...[
          _SectionHeader(label: 'Needs you', color: p.accent),
          for (final e in state.escalations)
            AbListRow(
              title: Text(e.question,
                  style: AbTokens.sansStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(e.reasoning,
                  style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs, color: p.textMuted)),
              onTap: () => answer(e),
            ),
        ],
        _SectionHeader(label: 'Activity', color: p.textMuted),
        if (state.activity.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Text('No activity yet.',
                style: AbTokens.sansStyle(color: p.textMuted)),
          )
        else
          for (final a in state.activity)
            AbListRow(
              title: Text(a.reason, style: AbTokens.sansStyle()),
              subtitle: Text(
                a.decision,
                style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs, color: p.textMuted),
              ),
            ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AbTokens.space16, AbTokens.space12, AbTokens.space16, AbTokens.space4),
      child: Text(
        label.toUpperCase(),
        style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
