// Shared shapes for the per-tool structured-driver mappers. The mapping *logic*
// is deliberately tool-specific (each agent's wire vocabulary differs), but the
// normalized output shapes are contracts every driver must produce identically —
// pinning them here stops the codex and opencode mappers from drifting apart.

/** Normalized token-usage breakdown produced by every driver's usage mapper
 *  (codex `mapTokenBreakdown`, opencode `mapTokens`). */
export interface AgentUsageBreakdown {
  totalTokens?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  reasoningTokens?: number;
}
