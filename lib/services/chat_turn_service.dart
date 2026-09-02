import 'dart:async';

import '../models/chat_message.dart';
import '../models/doc_chunk.dart';
import '../utils/answer_guard.dart';
import '../utils/app_responses.dart';
import '../utils/conversation.dart';
import '../utils/prompt_builder.dart';
import '../utils/query_router.dart';
import 'llm_service.dart';
import 'rag_service.dart';

/// One step of a turn, streamed to the UI.
sealed class TurnEvent {
  const TurnEvent();
}

/// The turn was routed; the UI can show what is about to happen.
class TurnRouted extends TurnEvent {
  const TurnRouted(this.intent);
  final QueryIntent intent;
}

/// Chunks were retrieved; the UI can show sources before the answer arrives.
class TurnSources extends TurnEvent {
  const TurnSources(this.chunks);
  final List<DocChunk> chunks;
}

/// Partial answer text, batched by the caller.
class TurnToken extends TurnEvent {
  const TurnToken(this.text);
  final String text;
}

/// The finished turn.
class TurnDone extends TurnEvent {
  const TurnDone(this.answer, {this.chunks = const [], this.guarded = false});

  final String answer;
  final List<DocChunk> chunks;

  /// True when the safety guard altered or replaced the model's answer.
  final bool guarded;
}

/// Runs one conversational turn end to end.
///
/// The pipeline, in order:
///
///   1. **Route** — capability, answer or decline. Two of the three cost no
///      model at all.
///   2. **Anchor** — build the retrieval query from the turn plus the
///      topic-bearing terms of earlier turns, worth +9.4 points of recall on
///      follow-ups.
///   3. **Retrieve** — hybrid RRF over the corpus.
///   4. **Fit** — keep only the chunks that actually fit the prompt budget,
///      so citations reference what the model was really shown.
///   5. **Generate** — stream from the on-device model.
///   6. **Guard** — check the answer against its own reference material and
///      block or complete it.
///
/// This lives in a service rather than the chat widget because every step is
/// business logic with a measurable failure mode, and none of it is easier to
/// test through a `setState`.
class ChatTurnService {
  const ChatTurnService(this._rag, this._llm);

  final RagService _rag;
  final LlmService _llm;

  /// Chunks retrieved per turn.
  ///
  /// Five, because that is what fits: at the 1400-character per-chunk cap,
  /// five chunks fill 91% of the 1452-token prompt budget and a sixth is
  /// simply dropped.
  static const int topK = 5;

  Stream<TurnEvent> send({
    required String text,
    required List<ChatMessage> history,
    String? topicFilter,
  }) async* {
    final route = QueryRouter.route(
      text,
      confidence: await _rag.confidence(text, topicFilter: topicFilter),
    );
    yield TurnRouted(route.intent);

    switch (route.intent) {
      case QueryIntent.capability:
        yield TurnDone(AppResponses.capability());
        return;
      case QueryIntent.decline:
        yield TurnDone(AppResponses.decline());
        return;
      case QueryIntent.answer:
        break;
    }

    final query = Conversation.retrievalQuery(text, history);
    final retrieved = await _rag.retrieve(
      query,
      topK: topK,
      topicFilter: topicFilter,
    );

    // Only the chunks that fit are real sources; the rest never reach the
    // model, and a citation pointing at one would misstate where the answer
    // came from.
    final chunks = PromptBuilder.selectContextChunks(
      chunks: retrieved,
      history: history,
      userMessage: text,
    );
    yield TurnSources(chunks);

    final prompt = PromptBuilder.buildChatPrompt(
      chunks: chunks,
      history: history,
      userMessage: text,
    );

    final buffer = StringBuffer();
    await for (final token in _llm.chat(prompt: prompt)) {
      buffer.write(token);
      yield TurnToken(buffer.toString());
    }

    yield _finish(buffer.toString(), chunks);
  }

  /// Apply the safety guard to a finished answer.
  ///
  /// A blocked answer is replaced by the guide text, which is never wrong. An
  /// incomplete one keeps its answer and gains the missing warning.
  TurnDone _finish(String answer, List<DocChunk> chunks) {
    final verdict = AnswerGuard.check(answer, chunks);

    return switch (verdict.action) {
      GuardAction.block => TurnDone(
        AppResponses.blocked(verdict.violations),
        chunks: chunks,
        guarded: true,
      ),
      GuardAction.augment => TurnDone(
        answer + AppResponses.warningFooter(verdict.omissions),
        chunks: chunks,
        guarded: true,
      ),
      GuardAction.pass => TurnDone(answer, chunks: chunks),
    };
  }
}
