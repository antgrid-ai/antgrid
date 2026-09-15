import '../models/agent_event.dart';

String agentErrorCategoryLabel(String category) => switch (category) {
  'rate_limited' => 'Rate limit reached',
  'quota_exceeded' => 'Usage limit reached',
  'auth' => 'Sign-in required',
  'network' => 'Connection interrupted',
  'context_overflow' => 'Conversation too long',
  'server_error' => 'Agent service error',
  'aborted' => 'Request stopped',
  _ => 'Agent error',
};

String? agentErrorRetryCopy(AgentError error) {
  if (!error.retryable) return null;
  final retryAfterMs = error.retryAfterMs;
  if (retryAfterMs == null) return 'You can try again.';
  final seconds = (retryAfterMs / 1000).ceil();
  return 'Try again in $seconds seconds.';
}
