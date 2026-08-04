/** Release gate for isolated (managed-worktree) sessions.
 *
 * On since the checkout-scoped workspace routing and its gates landed: every
 * filesystem-variable surface (files, tree, search, Git, commands, preview,
 * terminals, the handler's judge and destructive floor) resolves per checkout,
 * and an app without the `checkoutRouting` capability is refused a project that
 * holds a managed session rather than shown main's workspace beside an isolated
 * agent. Turning this back off is the kill switch if that ever regresses. */
export const WORKTREE_SESSIONS_SUPPORTED = true;
