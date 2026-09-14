import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_snack_bar.dart';
import '../../models/handler_state.dart';
import '../../providers/providers.dart';
import '../../providers/sessions.dart';
import 'handler_ask_sheet.dart';
import 'handler_reply_sheet.dart';

/// The free-text answer path for one escalation — three routes, chosen by what
/// the row IS rather than by which surface it was tapped on.
///
/// Shared for the same reason the row itself is: the Handler tab and the agent
/// panel's overlay both render the same escalation, and the branch below is
/// where an answer the user typed gets silently dropped if one copy of it drifts
/// from the other.
///
/// Takes a [ProviderContainer] rather than a `WidgetRef`: every branch here
/// crosses an await on a sheet the user types into, and the row that opened it
/// can be rebuilt away in that window — a `WidgetRef` touched past that point
/// throws. [context] stays a widget context, used only behind `context.mounted`.
Future<void> answerHandlerEscalation(
  BuildContext context,
  ProviderContainer container,
  HandlerEscalation e,
) async {
  if (e.nonBlocking) {
    // An ask goes to its own sheet and its own transport. The reply sheet
    // would prefill the judge's draft and send the result into the session
    // as a submitted line — which is what an ask exists not to do: the
    // agent is still working, and the answer belongs to Handler.
    final result = await showHandlerAskSheet(context, e);
    if (result == null) return;
    // Re-resolved after the sheet for the reason spelled out below.
    final asked = focusedServiceOrNull(container, (s) => s.handlerService);
    if (asked == null) return;
    if (result is HandlerAskDecline) {
      asked.dismiss(e);
      return;
    }
    final sent = asked.answerAskText(e, (result as HandlerAskAnswer).text);
    // The one arm where a refusal costs the user real work. The service
    // refuses a row that stopped being an ask while the sheet was open —
    // the overnight case exactly, where the agent finishes the work the
    // question did not gate while the user is still typing. The sheet has
    // already popped and the text lives nowhere else, so saying nothing
    // here reads as an answer given. The tap arm needs none of this: the
    // card declines to latch and the user is out one tap.
    if (!sent && context.mounted) {
      showAbSnackBar(
        context,
        'That question changed while you were answering — your answer was '
        'not sent. Handler is waiting on it here.',
      );
    }
    return;
  }
  if (e.kind == 'resolve_in_session') {
    // Option-based prompt. The resolution UI belongs to the SESSION and differs
    // by mode — a chat slot's permission card / question form in the transcript,
    // a PTY agent's own prompt drawn in the terminal — but either way it holds
    // the id the driver is blocked on, which free text cannot carry. Focusing
    // the session is therefore the answer in both modes, and the one branch
    // that does not have to know which mode it is looking at.
    // Switching focus is not enough on mobile: the Handler tab is the workspace
    // page and the session is the agent page, so without the swipe the tap
    // looks like it did nothing. From the agent panel's own overlay both calls
    // are already no-ops — the user is looking at the prompt — which is why
    // that surface passes no `onReply` for this kind at all rather than
    // offering a tap that lands on the session it is floating over.
    container.read(activeSessionIdProvider.notifier).set(e.terminalId);
    container.read(switchToAgentProvider)?.call();
    return;
  }
  final text = await showHandlerReplySheet(context, e);
  if (text == null) return;
  // Re-resolved after the sheet: the sheet stays open for as long as the user
  // types, and the focused project's session can be rebuilt in that window. The
  // build-time instance would be disposed by then, and `reply` answers a
  // disposed service with `false` — an answer the user typed, silently dropped,
  // under a card that still reads as answered.
  focusedServiceOrNull(container, (s) => s.handlerService)?.reply(e, text);
}
