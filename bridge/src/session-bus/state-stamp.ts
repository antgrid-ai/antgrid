/** What a frozen card cannot say for itself: its task moved while it waited.
 *
 *  A queued line is rendered once and can wait out the very state it describes,
 *  which is how a lead came to be asked to answer a peer whose task had already
 *  completed. Read again at delivery, the two states say so.
 *
 *  Annotates rather than filters, deliberately: the completion wake for a task
 *  that ended is correct as written and must still arrive, because a lead may
 *  never infer a peer's outcome from absence (D11). A task the store can no
 *  longer find is left alone for the same reason — an absent record is not
 *  evidence of a move.
 */
export function stampTaskState(
  text: string,
  task: { taskId: string; state: string },
  current: string | null | undefined,
): string {
  if (!current || current === task.state) return text;
  return `${text}\n\n[antgrid session bus] state now: task ${task.taskId} is ${current}; it was `
    + `${task.state} when the message above was written. Anything above that asks for a live task no `
    + `longer applies.`;
}
