/// Timed playback for the offline demo.
///
/// A beat is a frame plus the delay after connect at which it is dispatched.
/// The opening script is FINITE and short: a loop would keep a timer alive for
/// as long as the demo is open and make the terminal look like it is still
/// doing work minutes after the user stopped watching.
library;

import 'fixtures/demo_workspace_fixtures.dart';

typedef DemoBeat = ({Duration at, String channel, Map<String, Object?> frame});

DemoBeat _control(int ms, Map<String, Object?> frame) =>
    (at: Duration(milliseconds: ms), channel: 'control', frame: frame);

Map<String, Object?> _terminalOutput(String data) => <String, Object?>{
  'type': 'terminal:output',
  'checkoutId': 'main',
  'terminalId': kDemoTerminalId,
  'data': data,
};

/// Plays once when the demo transport connects: a dev server starting, then the
/// port and preview URL it exposes. Ends deliberately at a shell prompt so the
/// terminal reads as idle rather than truncated.
final List<DemoBeat> kDemoScript = <DemoBeat>[
  _control(800, _terminalOutput('\r\n${kDemoShellPrompt}bun run dev\r\n')),
  _control(1700, _terminalOutput('\r\n  VITE ready in 412 ms\r\n')),
  _control(2500, _terminalOutput('  Local:   $kDemoPreviewUrlString/\r\n')),
  _control(3100, kDemoPortsUpdate),
  _control(3600, kDemoPreviewUrl),
  _control(4600, _terminalOutput('\r\n$kDemoShellPrompt')),
];

/// What the demo answers a typed prompt with.
///
/// The text says plainly that nothing ran, because the alternative — a canned
/// answer that reads like a real one — is the exact confusion the demo banner
/// exists to prevent. It still arrives as deltas so the streaming transcript,
/// the working indicator and the stop button all behave as they do live.
const List<String> _kReplyChunks = <String>[
  'Nothing ran — this is the built-in sample project, ',
  'so your message stayed on this device.\n\n',
  'Connect Antgrid on your computer and this pane drives the real agent: ',
  'your prompt goes to Claude Code, Codex or whichever CLI that project uses, ',
  'and its reply streams back here exactly like this one.',
];

/// Beats for one canned reply turn. The caller supplies the ids so the reply
/// lands in the session the user actually typed into.
List<DemoBeat> demoPromptReplyBeats({
  required String sessionId,
  required String turnId,
  required String promptText,
}) {
  Map<String, Object?> envelope(String type, Map<String, Object?> body) =>
      <String, Object?>{
        'type': type,
        'sessionId': sessionId,
        'turnId': turnId,
        ...body,
      };

  final beats = <DemoBeat>[
    _control(0, envelope('agent:turn-start', const <String, Object?>{})),
    _control(
      0,
      envelope('agent:item-added', <String, Object?>{
        'item': <String, Object?>{
          'itemId': '$turnId-user',
          'kind': 'message',
          'role': 'user',
          'text': promptText,
        },
      }),
    ),
    _control(
      600,
      envelope('agent:item-added', <String, Object?>{
        'item': <String, Object?>{
          'itemId': '$turnId-answer',
          'kind': 'message',
          'role': 'assistant',
          'text': '',
        },
      }),
    ),
  ];

  var ms = 900;
  for (final chunk in _kReplyChunks) {
    beats.add(
      _control(
        ms,
        envelope('agent:item-delta', <String, Object?>{
          'itemId': '$turnId-answer',
          'textChunk': chunk,
        }),
      ),
    );
    ms += 260;
  }
  beats.add(
    _control(
      ms,
      envelope('agent:turn-end', const <String, Object?>{
        'stopReason': 'end_turn',
      }),
    ),
  );
  return beats;
}
