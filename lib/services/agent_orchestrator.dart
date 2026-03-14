/// Intent types the orchestrator can classify a user turn into.
enum AgentIntent { chat, assess, guide }

/// Parses the LLM's single-word intent classification response.
///
/// The LLM is prompted to reply with exactly one word: CHAT, ASSESS, or GUIDE.
/// This function is lenient — any response containing the keyword maps to
/// the corresponding intent, defaulting to [AgentIntent.chat] on ambiguity.
AgentIntent parseIntent(String llmResponse) {
  final upper = llmResponse.trim().toUpperCase();
  if (upper.contains('ASSESS')) return AgentIntent.assess;
  if (upper.contains('GUIDE')) return AgentIntent.guide;
  return AgentIntent.chat;
}

/// Tracks the current state of the agentic session.
///
/// The UI reads [state] to decide which screen to show:
/// - [AgentState.idle] → Home
/// - [AgentState.chat] → ChatScreen
/// - [AgentState.assessing] → SituationScreen
/// - [AgentState.actionPlan] → ActionPlanScreen
/// - [AgentState.guiding] → StepGuideScreen
enum AgentState { idle, chat, assessing, actionPlan, guiding }
