import 'demo_workspace_fixtures.dart' show kDemoSessionCartId;

/// One sample memory, aged relative to when the sample opens so its "3h ago"
/// stays true however long ago the build was made.
typedef DemoMemorySeed = ({
  String id,
  String content,
  String memoryType,
  String scope,
  String applicability,
  List<String> evidence,

  /// Null is a memory the user wrote in the app.
  String? agentId,
  Duration age,

  /// The id of the version this one replaced.
  String? supersedes,
  String? taskId,
});

const String kDemoMemoryOwnerId = 'demo-owner';

/// The sample project's memories, newest first. Covers every kind, one memory
/// written by the user, one correction with an earlier version, and one
/// session's progress, so each part of the Memory screen has something to show.
/// Content follows the sample project's own files (`kDemoFileContents`).
const List<DemoMemorySeed> kDemoMemorySeeds = [
  (
    id: 'mem_demo_cart_progress',
    content:
        'Rounding fix in cartTotal is done. Still to do: a test for a line with quantity above 1.',
    memoryType: 'task_state',
    scope: 'task',
    applicability: 'The fix/cart-totals session',
    evidence: ['src/cart.ts', 'tests/cart.test.ts'],
    agentId: 'claude-code',
    age: Duration(minutes: 25),
    supersedes: null,
    taskId: kDemoSessionCartId,
  ),
  (
    id: 'mem_demo_checkout_errors',
    content:
        'validateCheckout throws CheckoutError with the name of the field at fault. The checkout form highlights the input with that name, so a new check needs a field the form already has.',
    memoryType: 'observation',
    scope: 'project',
    applicability: 'Adding a check to src/checkout.ts',
    evidence: ['src/checkout.ts', 'tests/checkout.test.ts'],
    agentId: 'claude-code',
    age: Duration(hours: 3),
    supersedes: null,
    taskId: null,
  ),
  (
    id: 'mem_demo_coupon_case_v2',
    content:
        'Coupon codes are case-insensitive. Upper-case couponCode before looking it up.',
    memoryType: 'observation',
    scope: 'project',
    applicability: 'Checkout with a coupon code',
    evidence: ['src/checkout.ts'],
    agentId: 'codex',
    age: Duration(hours: 7),
    supersedes: 'mem_demo_coupon_case_v1',
    taskId: null,
  ),
  (
    id: 'mem_demo_test_command',
    content:
        'Run the tests with bun test from the project root. There is no npm test script.',
    memoryType: 'note',
    scope: 'project',
    applicability: '',
    evidence: ['tests/checkout.test.ts'],
    agentId: 'codex',
    age: Duration(days: 1, hours: 2),
    supersedes: null,
    taskId: null,
  ),
  (
    id: 'mem_demo_cents',
    content:
        'Keep money in integer cents, as unitPriceCents does. Never use floating-point prices.',
    memoryType: 'preference',
    scope: 'project',
    applicability: '',
    evidence: ['src/cart.ts'],
    agentId: null,
    age: Duration(days: 2),
    supersedes: null,
    taskId: null,
  ),
  (
    id: 'mem_demo_coupon_case_v1',
    content: 'Coupon codes are case-sensitive.',
    memoryType: 'observation',
    scope: 'project',
    applicability: 'Checkout with a coupon code',
    evidence: [],
    agentId: 'codex',
    age: Duration(days: 4),
    supersedes: null,
    taskId: null,
  ),
];
