/** Release gate for isolated (managed-worktree) sessions.
 *
 * On since the checkout-scoped workspace routing and its gates landed: every
 * filesystem-variable surface (files, tree, search, Git, commands, preview,
 * terminals, the handler's judge and destructive floor) resolves per checkout.
 * Turning this back off is the kill switch if that ever regresses. */
export const WORKTREE_SESSIONS_SUPPORTED = true;
