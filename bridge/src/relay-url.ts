/**
 * Normalize a user/app-supplied relay base into a `ws(s)://…/ws` URL.
 *
 * Tolerates bases that end in `/` or `/ws[/]` — naïve concat would produce
 * `…//ws` or `…/ws/ws` and the relay would 404. Also upgrades an http(s) base
 * to ws(s): the WebSocket client requires a ws scheme, but dev setups (e.g. the
 * Aspire-allocated relay endpoint) hand us an http URL. This mirrors the Dart
 * relay client's normalization.
 *
 * Lives in its own module (rather than `index.ts`) so both `index.ts` and the
 * promotion controller can import it without a module-init cycle.
 */
export function joinRelayWsPath(base: string): string {
  const ws = base.replace(/^http(s?):\/\//i, "ws$1://");
  return `${ws.replace(/\/+(?:ws\/*)?$/, "")}/ws`;
}
