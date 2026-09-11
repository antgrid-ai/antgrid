/// Canned workspace frames for the offline demo.
///
/// These are raw wire envelopes, not view models: every one is dispatched
/// through the real [MessageRouter] and parsed by `parseAbMessage`, so the demo
/// exercises the same reducers a live bridge drives. Keep each map inside the
/// shape its `parseAbMessage` case requires — a frame that fails to parse is
/// dropped silently and the surface it feeds just stays empty.
///
/// `id`/`timestamp` are deliberately absent: `DemoTransport` stamps them at
/// dispatch so relative times read as "now" rather than 1970.
library;

import '../demo_identity.dart';

const String kDemoBranch = 'checkout';

/// Shared by the wire frame below and the New Session picker's branch catalog,
/// which cannot go to a bridge for the sample project's branches.
const List<String> kDemoBranches = <String>[
  kDemoBranch,
  'main',
  'fix/cart-totals',
];
const String kDemoTerminalId = 'demo-terminal';

/// The `dev` service's log terminal. `ServicesListView` opens a service's logs
/// by looking its `id` up in the terminal tabs, so the service and the terminal
/// have to be the same id or "View logs" resolves to nothing and bounces back.
/// Typed `service`, which is what keeps it out of the ad-hoc Terminals list
/// (`terminal_list_view.dart` filters on exactly that).
const String kDemoServiceTerminalId = 'dev';

/// Session the demo opens on — its transcript is complete.
const String kDemoSessionCheckoutId = 'demo-session-checkout';

/// Second row in the list, so the session switcher has somewhere to go.
const String kDemoSessionCartId = 'demo-session-cart';

const String kDemoAgentTool = 'claude';

const int kDemoPreviewPort = 5173;
const String kDemoPreviewUrlString = 'http://localhost:5173';

/// Latest-wins frames the bridge would have replayed in its connect-time
/// snapshot. Order matters only for readability — every one is idempotent.
const List<Map<String, Object?>> kDemoDurableFrames = <Map<String, Object?>>[
  <String, Object?>{
    'type': 'agent:hello',
    'tool': kDemoAgentTool,
    'command': 'claude',
    'version': 'demo',
    'flags': <String>[],
  },
  <String, Object?>{
    'type': 'agent:status',
    'projectId': kDemoProjectId,
    'checkoutId': 'main',
    'agent': <String, Object?>{'name': kDemoDisplayName, 'version': 'demo'},
    'git': <String, Object?>{'branch': kDemoBranch},
    'terminals': <Map<String, Object?>>[
      <String, Object?>{
        'terminalId': kDemoTerminalId,
        'name': 'agent',
        'running': true,
        'shell': 'zsh',
        'cols': 96,
        'rows': 30,
        'type': 'agent',
      },
      <String, Object?>{
        'terminalId': kDemoServiceTerminalId,
        'name': 'dev',
        'running': true,
        'shell': 'bun',
        'cols': 96,
        'rows': 30,
        'type': 'service',
      },
    ],
    // Kept in step with [kDemoConfig]'s `services`, the same way `commands`
    // below is: the sample antgrid.yaml is served verbatim to Project Settings,
    // so an empty list here reads as "No services declared" one tab away from a
    // settings page listing `dev`, a terminal running `bun run dev`, a detected
    // vite port and a preview pointing at it.
    'services': <Map<String, Object?>>[
      <String, Object?>{
        'id': kDemoServiceTerminalId,
        'name': 'dev',
        'running': true,
        'command': 'bun run dev',
      },
    ],
    // What the command tray renders from. Kept in step with [kDemoConfig]'s
    // `commands`, which is the same list as the sample antgrid.yaml declares.
    'commands': <Map<String, Object?>>[
      <String, Object?>{'name': 'test', 'confirm': false},
      <String, Object?>{'name': 'lint', 'confirm': false},
    ],
  },
  <String, Object?>{
    'type': 'git:status',
    'projectId': kDemoProjectId,
    'checkoutId': 'main',
    'files': <Map<String, Object?>>[
      <String, Object?>{
        'path': 'src/checkout.ts',
        'status': 'M',
        'staged': false,
        'additions': 24,
        'deletions': 3,
      },
      <String, Object?>{
        'path': 'src/cart.ts',
        'status': 'M',
        'staged': true,
        'additions': 6,
        'deletions': 1,
      },
      <String, Object?>{
        'path': 'tests/checkout.test.ts',
        // 'U', not 'A': the bridge files untracked files as 'U' and reserves
        // 'A' for the STAGED set (`bridge/src/git.ts`), and the Git panel's
        // discard confirmation reads exactly that pairing to decide between
        // "Discard all changes to…" and "Permanently delete the new file…".
        'status': 'U',
        'staged': false,
        'additions': 41,
        'deletions': 0,
      },
    ],
  },
  <String, Object?>{
    'type': 'tree:full',
    'projectId': kDemoProjectId,
    'checkoutId': 'main',
    'seq': 1,
    'root': kDemoTreeRoot,
  },
];

/// The `antgrid.yaml` Project Settings shows for the sample project.
///
/// Answering `config:read` with no payload is NOT equivalent: `ConfigService`
/// reads a missing `config` on an `ok` reply as a valid EMPTY one, which showed
/// an unconfigured project beside a workspace the rest of the demo presents as
/// fully set up.
const Map<String, Object?> kDemoConfig = <String, Object?>{
  'name': kDemoDisplayName,
  'agent': <String, Object?>{'tool': kDemoAgentTool, 'command': 'claude'},
  'services': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'dev',
      'command': 'bun',
      'args': <String>['run', 'dev'],
      'autoStart': true,
    },
  ],
  'commands': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'test',
      'command': 'bun',
      'args': <String>['test'],
      'description': 'Run the test suite',
    },
    <String, Object?>{
      'name': 'lint',
      'command': 'bun',
      'args': <String>['run', 'lint'],
      'description': 'Lint the working tree',
    },
  ],
  'ports': <Map<String, Object?>>[
    <String, Object?>{
      'port': kDemoPreviewPort,
      'name': 'Preview',
      'onDetect': 'openPreview',
    },
  ],
};

const Map<String, Object?> kDemoTreeRoot = <String, Object?>{
  'name': 'demo-shop',
  'path': '',
  'type': 'directory',
  'children': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'src',
      'path': 'src',
      'type': 'directory',
      'children': <Map<String, Object?>>[
        <String, Object?>{
          'name': 'cart.ts',
          'path': 'src/cart.ts',
          'type': 'file',
          'size': 812,
          'extension': 'ts',
        },
        <String, Object?>{
          'name': 'checkout.ts',
          'path': 'src/checkout.ts',
          'type': 'file',
          'size': 1436,
          'extension': 'ts',
        },
        <String, Object?>{
          'name': 'index.ts',
          'path': 'src/index.ts',
          'type': 'file',
          'size': 344,
          'extension': 'ts',
        },
      ],
    },
    <String, Object?>{
      'name': 'tests',
      'path': 'tests',
      'type': 'directory',
      'children': <Map<String, Object?>>[
        <String, Object?>{
          'name': 'cart.test.ts',
          'path': 'tests/cart.test.ts',
          'type': 'file',
          'size': 640,
          'extension': 'ts',
        },
        <String, Object?>{
          'name': 'checkout.test.ts',
          'path': 'tests/checkout.test.ts',
          'type': 'file',
          'size': 1102,
          'extension': 'ts',
        },
      ],
    },
    <String, Object?>{
      'name': 'README.md',
      'path': 'README.md',
      'type': 'file',
      'size': 287,
      'extension': 'md',
    },
    <String, Object?>{
      'name': 'package.json',
      'path': 'package.json',
      'type': 'file',
      'size': 412,
      'extension': 'json',
    },
  ],
};

/// Bodies served for `file:read`. A path outside this map answers with an
/// `error`, which is what the bridge does for an unreadable file — the viewer
/// already renders that state.
const Map<String, String> kDemoFileContents = <String, String>{
  'src/checkout.ts': '''
import { Cart, cartTotal } from './cart';

export type CheckoutInput = {
  cart: Cart;
  email: string;
  couponCode?: string;
};

export class CheckoutError extends Error {
  constructor(readonly field: string, message: string) {
    super(message);
  }
}

export function validateCheckout(input: CheckoutInput): void {
  if (input.cart.lines.length === 0) {
    throw new CheckoutError('cart', 'Cart is empty');
  }
  if (!input.email.includes('@')) {
    throw new CheckoutError('email', 'Enter a valid email address');
  }
  if (cartTotal(input.cart) <= 0) {
    throw new CheckoutError('cart', 'Order total must be positive');
  }
}
''',
  'src/cart.ts': '''
export type CartLine = {
  sku: string;
  quantity: number;
  unitPriceCents: number;
};

export type Cart = {
  lines: CartLine[];
};

export function cartTotal(cart: Cart): number {
  return cart.lines.reduce(
    (sum, line) => sum + line.quantity * line.unitPriceCents,
    0,
  );
}
''',
  'src/index.ts': '''
import { validateCheckout } from './checkout';

export { validateCheckout };
export { cartTotal } from './cart';
''',
  'tests/checkout.test.ts': '''
import { expect, test } from 'bun:test';
import { validateCheckout } from '../src/checkout';

const cart = { lines: [{ sku: 'mug', quantity: 1, unitPriceCents: 1200 }] };

test('rejects an empty cart', () => {
  expect(() =>
    validateCheckout({ cart: { lines: [] }, email: 'a@example.com' }),
  ).toThrow('Cart is empty');
});

test('rejects a malformed email', () => {
  expect(() => validateCheckout({ cart, email: 'nope' })).toThrow(
    'Enter a valid email address',
  );
});
''',
  'tests/cart.test.ts': '''
import { expect, test } from 'bun:test';
import { cartTotal } from '../src/cart';

test('sums line totals', () => {
  const cart = {
    lines: [
      { sku: 'mug', quantity: 2, unitPriceCents: 1200 },
      { sku: 'tee', quantity: 1, unitPriceCents: 2400 },
    ],
  };
  expect(cartTotal(cart)).toBe(4800);
});
''',
  'README.md': '''
# demo-shop

Sample project bundled with Antgrid so the app has something to show before
you connect a machine. Nothing here runs — the files, git status and terminal
output are canned.
''',
  'package.json': '''
{
  "name": "demo-shop",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "test": "bun test"
  }
}
''',
};

/// Unified diffs served for `git:diff`, keyed by path.
const Map<String, String> kDemoGitDiffContent = <String, String>{
  'src/checkout.ts': '''
@@ -1,10 +1,24 @@
-import { Cart } from './cart';
+import { Cart, cartTotal } from './cart';
 
 export type CheckoutInput = {
   cart: Cart;
   email: string;
+  couponCode?: string;
 };
 
+export class CheckoutError extends Error {
+  constructor(readonly field: string, message: string) {
+    super(message);
+  }
+}
+
 export function validateCheckout(input: CheckoutInput): void {
-  return;
+  if (input.cart.lines.length === 0) {
+    throw new CheckoutError('cart', 'Cart is empty');
+  }
+  if (!input.email.includes('@')) {
+    throw new CheckoutError('email', 'Enter a valid email address');
+  }
 }
''',
  'src/cart.ts': '''
@@ -10,7 +10,12 @@
 export function cartTotal(cart: Cart): number {
-  return cart.lines.length;
+  return cart.lines.reduce(
+    (sum, line) => sum + line.quantity * line.unitPriceCents,
+    0,
+  );
 }
''',
  'tests/checkout.test.ts': '''
@@ -0,0 +1,20 @@
+import { expect, test } from 'bun:test';
+import { validateCheckout } from '../src/checkout';
+
+test('rejects an empty cart', () => {
+  expect(() =>
+    validateCheckout({ cart: { lines: [] }, email: 'a@example.com' }),
+  ).toThrow('Cart is empty');
+});
''',
};

const Map<String, Object?> kDemoGitBranches = <String, Object?>{
  'type': 'git:branches',
  'projectId': kDemoProjectId,
  'checkoutId': 'main',
  'current': kDemoBranch,
  'branches': kDemoBranches,
};

const Map<String, Object?> kDemoTerminalStarted = <String, Object?>{
  'type': 'terminal:started',
  'checkoutId': 'main',
  'terminalId': kDemoTerminalId,
  'shell': 'zsh',
  'cols': 96,
  'rows': 30,
  'terminalType': 'agent',
};

/// The sample shell's prompt. Shared with the transport's live echo, which
/// draws the prompt again after every Enter — two spellings made the terminal
/// look like it had swapped shells the moment the user typed into it.
const String kDemoShellPrompt = 'demo-shop \$ ';

const Map<String, Object?> kDemoTerminalSnapshot = <String, Object?>{
  'type': 'terminal:snapshot',
  'checkoutId': 'main',
  'terminalId': kDemoTerminalId,
  'seq': 1,
  // CRLF, not the bare LF a `'''` block carries: this goes straight into the
  // VTE, where LF without LNM is index-only — it drops a row without returning
  // the carriage, so the canned output rendered as a staircase. The live
  // script's `terminal:output` frames spell it out for the same reason.
  'scrollback':
      '${kDemoShellPrompt}bun test\r\n'
      'bun test v1.3.14\r\n'
      '\r\n'
      'tests/cart.test.ts:\r\n'
      '  (pass) sums line totals [1.20ms]\r\n'
      '\r\n'
      'tests/checkout.test.ts:\r\n'
      '  (pass) rejects an empty cart [0.84ms]\r\n'
      '  (pass) rejects a malformed email [0.61ms]\r\n'
      '\r\n'
      ' 3 pass\r\n'
      ' 0 fail\r\n'
      'Ran 3 tests across 2 files. [42.00ms]\r\n'
      '\r\n'
      '$kDemoShellPrompt',
};

/// Logs behind the `dev` service's "View logs". A service terminal has no
/// prompt — it is one long-running process — so this ends mid-stream rather
/// than on [kDemoShellPrompt]. CRLF for the reason [kDemoTerminalSnapshot]
/// gives.
const Map<String, Object?> kDemoServiceSnapshot = <String, Object?>{
  'type': 'terminal:snapshot',
  'checkoutId': 'main',
  'terminalId': kDemoServiceTerminalId,
  'seq': 1,
  'scrollback':
      '\$ bun run dev\r\n'
      '\r\n'
      '  VITE v5.4.8  ready in 412 ms\r\n'
      '\r\n'
      '  ➜  Local:   $kDemoPreviewUrlString/\r\n'
      '  ➜  press h + enter to show help\r\n'
      '\r\n'
      '  8:41:02 AM [vite] hmr update /src/cart.ts\r\n'
      '  8:41:19 AM [vite] hmr update /src/checkout.ts\r\n',
};

const Map<String, Object?> kDemoPortsUpdate = <String, Object?>{
  'type': 'ports:update',
  'projectId': kDemoProjectId,
  'checkoutId': 'main',
  'ports': <Map<String, Object?>>[
    <String, Object?>{
      'port': kDemoPreviewPort,
      'pid': 4211,
      'processName': 'vite',
      'label': 'demo-shop dev',
      'scheme': 'http',
    },
  ],
};

const Map<String, Object?> kDemoPreviewUrl = <String, Object?>{
  'type': 'preview:url',
  'projectId': kDemoProjectId,
  'checkoutId': 'main',
  'port': kDemoPreviewPort,
  'url': kDemoPreviewUrlString,
  'label': 'demo-shop dev',
  'scheme': 'http',
};

const Map<String, Object?> kDemoPreviewSnapshot = <String, Object?>{
  'type': 'preview:snapshot',
  'checkoutId': 'main',
  'urls': <Map<String, Object?>>[
    <String, Object?>{
      'port': kDemoPreviewPort,
      'url': kDemoPreviewUrlString,
      'label': 'demo-shop dev',
      'scheme': 'http',
    },
  ],
};
