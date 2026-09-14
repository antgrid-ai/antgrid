/**
 * The prompts an AGENT is displaying in its own terminal, per slot, keyed by the
 * id it gave that tool call and carrying the tool the prompt belongs to.
 *
 * It exists because one block is announced twice: the tool hook that names the
 * prompt fires first, and the CLI schedules a generic permission notification
 * seconds later that can only say "Permission needed". The api-server reads this
 * to drop the second — for an UNARMED session too, which is why the state lives
 * here rather than in the Handler engine.
 *
 * The tool is what makes it a prompt latch rather than a slot latch, and that is
 * the whole difference: an agent batches AskUserQuestion alongside a Bash call
 * that needs approval, and a predicate answering about the SLOT silences the
 * approval nobody has been told about.
 */
export class OpenAgentPrompts {
  /** terminalId → promptId → the tool whose prompt it is. */
  private byTerminal = new Map<string, Map<string, string | undefined>>();

  /** A prompt whose report carried no id of its own. Kept under one shared key
   *  rather than dropped: the report still proves a prompt is on screen, and its
   *  completion arrives spelled the same way, so open and close still pair.
   *  Nothing outside this class ever sees it — an uncorrelatable id must never
   *  reach the Handler engine, where "no id" means "every prompt is gone". */
  private static readonly UNIDENTIFIED = "";

  private static key(promptId: string | undefined): string {
    return promptId || OpenAgentPrompts.UNIDENTIFIED;
  }

  open(terminalId: string, promptId: string | undefined, tool: string | undefined): void {
    const open = this.byTerminal.get(terminalId) ?? new Map<string, string | undefined>();
    open.set(OpenAgentPrompts.key(promptId), tool);
    this.byTerminal.set(terminalId, open);
  }

  close(terminalId: string, promptId: string | undefined): void {
    const open = this.byTerminal.get(terminalId);
    if (!open) return;
    open.delete(OpenAgentPrompts.key(promptId));
    if (open.size === 0) this.byTerminal.delete(terminalId);
  }

  /**
   * Is [tool]'s own prompt on screen for [terminalId]? An unnamed tool answers
   * NO: the caller could not say which prompt it is asking about, and this
   * predicate can only ever silence — a wrong yes costs a block nobody hears
   * about, a wrong no costs one duplicate push.
   */
  has(terminalId: string, tool: string | undefined): boolean {
    if (tool === undefined) return false;
    const open = this.byTerminal.get(terminalId);
    if (!open) return false;
    for (const held of open.values()) if (held === tool) return true;
    return false;
  }

  /** Everything the slot was displaying is gone — its turn ended, or the
   *  terminal did. A prompt cannot outlive its turn, and a slot id is reused by
   *  a same-id restart, so a stale entry would silence the next run's blocks. */
  clear(terminalId: string): void {
    this.byTerminal.delete(terminalId);
  }
}
