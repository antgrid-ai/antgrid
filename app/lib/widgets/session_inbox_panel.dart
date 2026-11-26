import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_section_header.dart';
import '../models/agent_event.dart';
import '../providers/session_bus_inbox.dart';
import '../util/relative_time.dart';
import 'transcript/rows/message_row.dart';
import 'transcript/selection/transcript_selection_scope.dart';
import 'transcript/transcript_rows.dart';

/// Day-aware rather than a bare clock: a post lands while its reader is away,
/// so this list routinely spans midnight — the same reason the handler feed
/// stamps its rows this way.
String _stamp(int epochMs) =>
    dayAwareTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

/// Opens the messages for [sessionId] over [context], which must outlive any
/// popup the caller dismissed on the way in.
Future<void> showSessionInbox(
  BuildContext context, {
  required String sessionId,
}) {
  return showAbAdaptiveSheet<void>(
    context,
    child: SessionInboxPanel(sessionId: sessionId),
  );
}

/// The posts other sessions have written to this one, and the thread behind any
/// of them.
///
/// A sheet, opened from the Messages row in the session kebab and nowhere else
/// — never a workspace tab. Almost everything a bus exchange does is
/// already in the terminal: a `notify` is written into the PTY as a prompt, and
/// an outbound send is an MCP tool call in the transcript. What is ONLY here is
/// what reaches neither — a `post` parked for an agent that has not looked, the
/// mailbox's own discards, and the delivery receipt on an outbound entry. That
/// is a surface to open on purpose, not a permanent slot mostly saying
/// "Nothing unread".
///
/// [sessionId] is given rather than read from focus, so this renders the
/// mailbox it was opened for even if focus moves out from under it.
///
/// Every read it makes is a PEEK. The read that marks a post read belongs to
/// the agent, and a human opening this must not spend it — the post would
/// disappear from the agent's own mailbox having never been delivered to it.
class SessionInboxPanel extends ConsumerStatefulWidget {
  const SessionInboxPanel({super.key, required this.sessionId});

  /// The session whose mailbox this is — a row's session, not the focused one.
  final String sessionId;

  @override
  ConsumerState<SessionInboxPanel> createState() => _SessionInboxPanelState();
}

class _SessionInboxPanelState extends ConsumerState<SessionInboxPanel> {
  /// The thread on screen, or null while the mailbox list is.
  String? _openThreadId;

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;

    final threadId = _openThreadId;
    if (threadId != null) {
      return _ThreadPane(
        sessionId: sessionId,
        threadId: threadId,
        onBack: () => setState(() => _openThreadId = null),
      );
    }

    final state = ref.watch(sessionInboxProvider(sessionId));
    return _Mailbox(
      state: state,
      onOpenThread: (id) => setState(() => _openThreadId = id),
    );
  }
}

class _Mailbox extends StatelessWidget {
  const _Mailbox({required this.state, required this.onOpenThread});

  final SessionInboxState state;
  final ValueChanged<String> onOpenThread;

  @override
  Widget build(BuildContext context) {
    final refusal = state.refusal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Messages',
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        // Rendered verbatim, and never collapsed into an empty mailbox: "this
        // terminal names no session" and "nobody has written to you" are
        // different facts, and only one of them is the reader's to act on.
        if (refusal != null)
          AbInlineBanner(
            text: refusal.message,
            color: context.antgrid.warning,
          ),
        // A LIFETIME total on the store, deliberately not worded as a delta:
        // the count never resets, so "since you last looked" would re-accuse
        // the mailbox of the same posts on every visit.
        //
        // It names the MAILBOX and never "the budget": the pair budget refuses
        // a send where its own sender can read the refusal and discards
        // nothing, so one word covering both points at the wrong mechanism.
        if (state.dropped > 0)
          AbInlineBanner(
            text: state.dropped == 1
                ? '1 post aged out of this mailbox, or was pushed out of it '
                      'when it filled.'
                : '${state.dropped} posts aged out of this mailbox, or were '
                      'pushed out of it when it filled.',
            color: context.antgrid.textMuted,
          ),
        Flexible(child: _posts(context)),
      ],
    );
  }

  Widget _posts(BuildContext context) {
    if (state.posts.isEmpty) {
      if (state.loading) {
        return const _Centered(
          child: AbEmptyState.compact(title: 'Reading the mailbox…'),
        );
      }
      return const _Centered(
        child: AbEmptyState(
          icon: AbIcons.inbox,
          title: 'Nothing unread',
          subtitle:
              'Posts from other sessions land here. The agent reads them at '
              'its next turn boundary, which is what clears them.',
        ),
      );
    }
    // Shrink-wrapped, unlike the thread list below: a mailbox is bounded at
    // MAX_MAILBOX_POSTS rows of plain text, and a sheet that hugs one unread
    // post is the right size for one unread post.
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AbTokens.space12),
      children: [
        AbSectionHeader(label: 'Unread', count: state.posts.length),
        for (final post in state.posts)
          _PostRow(post: post, onOpenThread: onOpenThread),
      ],
    );
  }
}

class _PostRow extends StatelessWidget {
  const _PostRow({required this.post, required this.onOpenThread});

  final SessionBusInboxPost post;
  final ValueChanged<String> onOpenThread;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final threadId = post.threadId;
    return AbListRow(
      crossAxisAlignment: CrossAxisAlignment.start,
      title: Text(
        post.summary.isEmpty ? '(no summary)' : post.summary,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: p.textPrimary,
        ),
      ),
      // Prose the sender wrote about its own message — clipped at one line it
      // is a decision made without its subject.
      titleMaxLines: 2,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An address, not a name: mono, so it reads as the identifier it is.
          Text(
            '${post.from.projectId} · ${post.from.sessionId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
          ),
          if (post.unexpected != null)
            Text(
              'Flagged as unexpected: ${post.unexpected}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.warning,
              ),
            ),
          if (post.artifacts.isNotEmpty)
            Text(
              post.artifacts.length == 1
                  ? '1 attachment'
                  : '${post.artifacts.length} attachments',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
        ],
      ),
      subtitleMaxLines: 3,
      trailing: Text(
        _stamp(post.at),
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: p.textMuted,
        ),
      ),
      divider: true,
      hoverable: threadId != null,
      // A post that opened no thread has nothing to open: the row states the
      // whole message it carries, and a dead tap target would promise more.
      onTap: threadId == null ? null : () => onOpenThread(threadId),
    );
  }
}

class _ThreadPane extends ConsumerWidget {
  const _ThreadPane({
    required this.sessionId,
    required this.threadId,
    required this.onBack,
  });

  final String sessionId;
  final String threadId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.antgrid;
    final thread = ref.watch(
      sessionBusThreadProvider((sessionId: sessionId, threadId: threadId)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.borderSubtle)),
          ),
          child: Row(
            children: [
              AbIconButton(
                icon: AbIcons.back,
                tooltip: 'Back to the mailbox',
                onTap: onBack,
              ),
              const SizedBox(width: AbTokens.space4),
              Expanded(
                child: Text(
                  threadId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textSecondary,
                  ),
                ),
              ),
              // The thread replaces the mailbox rather than stacking over it,
              // so this row is the sheet's only title row while it is up and
              // owes the same way out.
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Flexible(
          child: thread.when(
            loading: () => const _Centered(
              child: AbEmptyState.compact(title: 'Reading the thread…'),
            ),
            // Reached only by something the provider itself did not author —
            // a refusal and a timed-out read both come back as data (see
            // SessionBusThread.refusal), so this is a dropped frame and says
            // so rather than the reader's own answer.
            error: (error, _) => const _Centered(
              child: AbEmptyState.error(title: 'The thread did not come back.'),
            ),
            data: (value) {
              // A refusal is authored at the point of refusal, so it is shown
              // as written.
              final refusal = value.refusal;
              if (refusal != null) {
                return _Centered(
                  child: AbEmptyState.error(title: refusal.message),
                );
              }
              return value.entries.isEmpty
                  ? const _Centered(
                      child: AbEmptyState.compact(
                        title: 'This thread is empty.',
                      ),
                    )
                  : SessionBusThreadEntries(entries: value.entries);
            },
          ),
        ),
      ],
    );
  }
}

/// A thread rendered with the transcript's own message rows.
///
/// No parallel bubble widget: a thread IS a list of wrapped lines that already
/// render, and a second renderer would drift from the first on markdown,
/// collapsing and selection alike.
///
/// Direction maps onto the transcript's own two treatments — what this session
/// SENT takes the accent-bordered block a user's own message takes, and what a
/// peer sent renders as prose. The stamp under an outbound entry is the only
/// end-to-end receipt anywhere in the design: its absence means no receipt has
/// come back yet, never that delivery failed, so it reads "Sent" rather than as
/// a warning.
class SessionBusThreadEntries extends StatefulWidget {
  const SessionBusThreadEntries({super.key, required this.entries});

  /// Oldest first, as the bridge orders them.
  final List<SessionBusThreadEntry> entries;

  @override
  State<SessionBusThreadEntries> createState() =>
      _SessionBusThreadEntriesState();
}

class _SessionBusThreadEntriesState extends State<SessionBusThreadEntries> {
  final _selection = TranscriptSelectionController();

  @override
  Widget build(BuildContext context) {
    // MessageRow's SelectableBlock registers with an ambient scope and expects
    // a SelectionArea above it; the transcript supplies both, so a thread
    // reusing the row has to supply them too.
    return TranscriptSelectionScope(
      controller: _selection,
      child: SelectionArea(
        onSelectionChanged: (content) =>
            _selection.onSelectionChanged(content?.plainText),
        // Deliberately NOT shrink-wrapped, where the mailbox above is: a
        // thread runs to MAX_LOG_ENTRIES rows of rendered markdown, so it fills
        // the sheet and scrolls lazily rather than laying all of them out to
        // decide a height.
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
          itemCount: widget.entries.length,
          itemBuilder: (context, index) {
            final entry = widget.entries[index];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MessageRow(
                  data: MessageRowData(
                    _itemFor(entry, index),
                    isUser: entry.outbound,
                    timestamp: DateTime.fromMillisecondsSinceEpoch(entry.at),
                  ),
                  rowIndex: index,
                ),
                if (entry.outbound)
                  _DeliveryStamp(deliveredAt: entry.deliveredAt),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The wire carries a summary and the wrapped lines separately; the row wants
/// one body. The summary leads because it is what the sender chose to be read
/// first, and it is all a collapsed row shows.
AgentItem _itemFor(SessionBusThreadEntry entry, int index) {
  final body = <String>[
    if (entry.summary.isNotEmpty) entry.summary,
    ...entry.text,
  ].join('\n\n');
  return AgentItem(
    // Stable across rebuilds so the row keeps its expanded/collapsed state
    // while the thread re-reads itself behind an arrival push.
    itemId: 'bus:${entry.at}:$index',
    kind: 'message',
    role: entry.outbound ? 'user' : 'assistant',
    text: body,
  );
}

class _DeliveryStamp extends StatelessWidget {
  const _DeliveryStamp({required this.deliveredAt});

  final int? deliveredAt;

  @override
  Widget build(BuildContext context) {
    final at = deliveredAt;
    return Padding(
      padding: const EdgeInsets.only(
        left: AbTokens.space8,
        bottom: AbTokens.space6,
      ),
      child: Text(
        at == null ? 'Sent' : 'Delivered ${_stamp(at)}',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXxs,
          color: context.antgrid.textMuted,
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AbTokens.space24),
    // Factors shrink-wrap it. Without them Center fills whatever the sheet
    // could give it, and an empty mailbox opens full height to say one line.
    child: Center(widthFactor: 1, heightFactor: 1, child: child),
  );
}
