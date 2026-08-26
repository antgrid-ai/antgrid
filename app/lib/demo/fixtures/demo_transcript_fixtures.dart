/// Canned session list and chat transcripts for the offline demo.
///
/// Times are built relative to a caller-supplied `now` rather than baked in: a
/// hard-coded epoch would render every demo turn as years old, and the session
/// rows sort and label themselves off `lastUsedAt`.
library;

import '../demo_identity.dart';
import 'demo_workspace_fixtures.dart';

const String kDemoSessionCheckoutName = 'Add checkout validation';
const String kDemoSessionCartName = 'Fix flaky cart test';

const String _kTurnOne = 'demo-turn-1';
const String _kCartTurnOne = 'demo-cart-turn-1';

/// Both rows are `running: true` so the workspace bootstrap has nothing to
/// start — a demo that had to answer `session:start` before it could show a
/// transcript would spend its first seconds on a spinner.
List<Map<String, Object?>> demoSessionEntries(DateTime now) {
  final createdCheckout = now.subtract(const Duration(hours: 3));
  final createdCart = now.subtract(const Duration(days: 1));
  return <Map<String, Object?>>[
    <String, Object?>{
      'id': kDemoSessionCheckoutId,
      'name': kDemoSessionCheckoutName,
      'createdAt': createdCheckout.millisecondsSinceEpoch,
      'lastUsedAt': now
          .subtract(const Duration(minutes: 4))
          .millisecondsSinceEpoch,
      'archived': false,
      'running': true,
      'tool': kDemoAgentTool,
      'mode': 'chat',
      'agentSessionResumable': true,
      'agentSessionId': kDemoSessionCheckoutId,
      'checkoutId': 'main',
      'checkoutKind': 'main',
      'checkoutState': 'ready',
    },
    <String, Object?>{
      'id': kDemoSessionCartId,
      'name': kDemoSessionCartName,
      'createdAt': createdCart.millisecondsSinceEpoch,
      'lastUsedAt': now
          .subtract(const Duration(hours: 20))
          .millisecondsSinceEpoch,
      'archived': false,
      'running': true,
      'tool': kDemoAgentTool,
      'mode': 'chat',
      'agentSessionResumable': true,
      'agentSessionId': kDemoSessionCartId,
      'checkoutId': 'main',
      'checkoutKind': 'main',
      'checkoutState': 'ready',
    },
  ];
}

Map<String, Object?> demoSessionsListResult({
  required String requestId,
  required DateTime now,
}) => <String, Object?>{
  'type': 'session:list:result',
  'projectId': kDemoProjectId,
  'requestId': requestId,
  'sessions': demoSessionEntries(now),
};

/// Capabilities the chat composer reads: model/mode pickers and slash commands
/// all render from this one frame.
Map<String, Object?> demoCapabilities(String sessionId) => <String, Object?>{
  'type': 'agent:capabilities',
  'sessionId': sessionId,
  'ready': true,
  'commands': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'review',
      'name': 'review',
      'description': 'Review the working tree',
    },
    <String, Object?>{
      'id': 'test',
      'name': 'test',
      'description': 'Run the test suite',
      'argHint': '[path]',
    },
  ],
  'modes': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'default',
      'name': 'Default',
      'description': 'Ask before editing',
    },
    <String, Object?>{
      'id': 'auto',
      'name': 'Auto',
      'description': 'Edit without asking',
    },
  ],
  'models': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'demo-model',
      'name': 'Sample model',
      'provider': 'demo',
      'efforts': <String>['low', 'high'],
      'defaultEffort': 'high',
    },
  ],
  'currentModelId': 'demo-model',
  'currentModeId': 'default',
  'currentEffortId': 'high',
};

/// The settled transcript served for [kDemoSessionCheckoutId].
///
/// Each frame carries its own `timestamp` because the reducer dates items from
/// the envelope, not from arrival — that is what makes a replayed turn read as
/// history instead of as something that just happened.
List<Map<String, Object?>> demoCheckoutTranscript(DateTime now) {
  final t0 = now.subtract(const Duration(minutes: 6));
  int at(int seconds) =>
      t0.add(Duration(seconds: seconds)).millisecondsSinceEpoch;

  Map<String, Object?> frame(
    String type,
    int seconds,
    Map<String, Object?> body,
  ) => <String, Object?>{
    'type': type,
    'timestamp': at(seconds),
    'sessionId': kDemoSessionCheckoutId,
    'turnId': _kTurnOne,
    ...body,
  };

  Map<String, Object?> item(int seconds, Map<String, Object?> body) =>
      frame('agent:item-added', seconds, <String, Object?>{'item': body});

  return <Map<String, Object?>>[
    frame('agent:turn-start', 0, const <String, Object?>{}),
    item(0, const <String, Object?>{
      'itemId': 'demo-item-user',
      'kind': 'message',
      'role': 'user',
      'text':
          'The checkout endpoint accepts empty carts and malformed emails. '
          'Add validation and a test.',
    }),
    item(2, const <String, Object?>{
      'itemId': 'demo-item-reasoning',
      'kind': 'reasoning',
      'text':
          'validateCheckout is a stub that returns immediately, so nothing '
          'guards the cart or the email. The cart total helper counts lines '
          'instead of summing them, which would make a zero-price order look '
          'valid.',
    }),
    item(4, const <String, Object?>{
      'itemId': 'demo-item-plan',
      'kind': 'plan',
      'title': 'Plan',
      'entries': <Map<String, Object?>>[
        <String, Object?>{
          'text': 'Read src/checkout.ts',
          'status': 'completed',
        },
        <String, Object?>{
          'text': 'Add cart, email and total guards',
          'status': 'completed',
        },
        <String, Object?>{'text': 'Cover both refusals', 'status': 'completed'},
      ],
    }),
    item(6, const <String, Object?>{
      'itemId': 'demo-item-read',
      'kind': 'tool_call',
      'toolKind': 'read',
      'title': 'Read src/checkout.ts',
      'status': 'completed',
      'content': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'text',
          'text':
              'export function validateCheckout(input: CheckoutInput): '
              'void {\n  return;\n}',
        },
      ],
    }),
    item(11, <String, Object?>{
      'itemId': 'demo-item-edit',
      'kind': 'tool_call',
      'toolKind': 'edit',
      'title': 'Edit src/checkout.ts',
      'status': 'completed',
      'content': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'diff',
          'path': 'src/checkout.ts',
          'oldText':
              'export function validateCheckout(input: CheckoutInput): void {\n'
              '  return;\n'
              '}\n',
          'newText':
              'export function validateCheckout(input: CheckoutInput): void {\n'
              "  if (input.cart.lines.length === 0) {\n"
              "    throw new CheckoutError('cart', 'Cart is empty');\n"
              '  }\n'
              "  if (!input.email.includes('@')) {\n"
              "    throw new CheckoutError('email', 'Enter a valid email address');\n"
              '  }\n'
              '  if (cartTotal(input.cart) <= 0) {\n'
              "    throw new CheckoutError('cart', 'Order total must be positive');\n"
              '  }\n'
              '}\n',
        },
      ],
    }),
    item(19, const <String, Object?>{
      'itemId': 'demo-item-test',
      'kind': 'tool_call',
      'toolKind': 'terminal',
      'title': 'bun test',
      'status': 'completed',
      'content': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'terminal',
          'data':
              'bun test v1.3.14\n\ntests/checkout.test.ts:\n'
              '  (pass) rejects an empty cart\n'
              '  (pass) rejects a malformed email\n\n'
              ' 3 pass\n 0 fail\n',
        },
      ],
    }),
    item(24, const <String, Object?>{
      'itemId': 'demo-item-answer',
      'kind': 'message',
      'role': 'assistant',
      'text':
          'Checkout now refuses an empty cart, a malformed email and a '
          'non-positive total, each as a typed `CheckoutError` naming the '
          'offending field. `cartTotal` sums line totals instead of counting '
          'lines, so a zero-price order no longer passes. Added '
          '`tests/checkout.test.ts` covering both refusals — 3 pass, 0 fail.',
    }),
    frame('agent:usage', 25, const <String, Object?>{
      'itemId': 'demo-item-answer',
      'total': <String, Object?>{
        'totalTokens': 19680,
        'inputTokens': 18420,
        'outputTokens': 1260,
      },
      'last': <String, Object?>{
        'totalTokens': 9880,
        'inputTokens': 9240,
        'outputTokens': 640,
      },
      'contextWindow': 200000,
    }),
    frame('agent:turn-end', 25, const <String, Object?>{
      'stopReason': 'end_turn',
    }),
  ];
}

/// The second session opens on a single settled turn — enough to show that the
/// switcher lands somewhere real, without a second full conversation to read.
List<Map<String, Object?>> demoCartTranscript(DateTime now) {
  final t0 = now.subtract(const Duration(hours: 20));
  int at(int seconds) =>
      t0.add(Duration(seconds: seconds)).millisecondsSinceEpoch;

  Map<String, Object?> frame(
    String type,
    int seconds,
    Map<String, Object?> body,
  ) => <String, Object?>{
    'type': type,
    'timestamp': at(seconds),
    'sessionId': kDemoSessionCartId,
    'turnId': _kCartTurnOne,
    ...body,
  };

  return <Map<String, Object?>>[
    frame('agent:turn-start', 0, const <String, Object?>{}),
    frame('agent:item-added', 0, const <String, Object?>{
      'item': <String, Object?>{
        'itemId': 'demo-cart-item-user',
        'kind': 'message',
        'role': 'user',
        'text': 'tests/cart.test.ts fails about one run in five. Why?',
      },
    }),
    frame('agent:item-added', 8, const <String, Object?>{
      'item': <String, Object?>{
        'itemId': 'demo-cart-item-answer',
        'kind': 'message',
        'role': 'assistant',
        'text':
            'The suite seeds the cart from a module-level object that an '
            'earlier test mutates, so the totals depend on file order. Give '
            'each test its own cart and the flake goes away.',
      },
    }),
    frame('agent:turn-end', 8, const <String, Object?>{
      'stopReason': 'end_turn',
    }),
  ];
}

/// Transcript frames keyed by session id, for the `session.transcriptSnapshot`
/// RPC.
Map<String, List<Map<String, Object?>>> demoTranscripts(DateTime now) =>
    <String, List<Map<String, Object?>>>{
      kDemoSessionCheckoutId: demoCheckoutTranscript(now),
      kDemoSessionCartId: demoCartTranscript(now),
    };
