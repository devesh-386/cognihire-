import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../claims/claim.dart';
import '../config.dart';

/// The six-field shape `prompts/interview_agent.v2.txt` and
/// `prompts/schemas/interview_turn.schema.json` require, plus a marker for how
/// the turn was produced. See `prompts/README.md` for why `say` is first.
enum TurnKind { followup, probe, newtopic, warmup, clarify, close }

class InterviewTurn {
  const InterviewTurn({
    required this.say,
    required this.kind,
    required this.quote,
    required this.difficultyDelta,
    required this.covered,
    required this.why,
    required this.wasGrounded,
  });

  final String say;
  final TurnKind kind;
  final String quote;
  final int difficultyDelta;
  final List<String> covered;
  final String why;

  /// False means the model's `quote` could not be found verbatim in the
  /// transcript and this turn was rewritten to [TurnKind.newtopic] with an
  /// empty quote before reaching the caller. See [LiveTurnClient._enforceGrounding].
  final bool wasGrounded;
}

/// State the model reasons over each turn. Mirrors the `STATE` object the
/// prompt expects — see `prompts/interview_agent.v2.txt`'s Input section.
class InterviewTurnState {
  const InterviewTurnState({
    required this.level,
    required this.askedIds,
    required this.coveredIds,
    required this.lastAnswerWords,
    required this.lastAnswerScore,
    required this.turnsSinceAck,
    required this.secondsRemaining,
    this.consecutiveShortAnswers = 0,
  });

  final int level;
  final List<String> askedIds;
  final List<String> coveredIds;
  final int lastAnswerWords;
  final int lastAnswerScore;
  final int turnsSinceAck;
  final int secondsRemaining;

  /// Answers under 15 words, back to back, ending at the most recent one.
  /// `last_answer_words` alone only tells the model about the *latest*
  /// answer — rule 3's "-1 after two consecutive short answers" is otherwise
  /// undetectable from state, since the model is never shown transcript
  /// history longer than the caller's window. Reset to 0 by the caller the
  /// moment an answer reaches 15 words.
  final int consecutiveShortAnswers;

  Map<String, Object?> toJson() => {
        'level': level,
        'asked_ids': askedIds,
        'covered_ids': coveredIds,
        'last_answer_words': lastAnswerWords,
        'last_answer_score': lastAnswerScore,
        'turns_since_ack': turnsSinceAck,
        'seconds_remaining': secondsRemaining,
        'consecutive_short': consecutiveShortAnswers,
      };
}

class TranscriptTurn {
  const TranscriptTurn(
      {required this.role, required this.text, this.partial = false});

  final String role; // 'interviewer' | 'candidate'
  final String text;
  final bool partial;

  Map<String, Object?> toJson() =>
      {'role': role, 'text': text, if (partial) 'partial': true};
}

/// Why a turn fell back to the scripted question bank instead of a live
/// model turn. Surfaced so the UI can be honest about which path ran, same
/// convention as `ClaimExtraction.degradedReason`.
class TurnDegraded implements Exception {
  const TurnDegraded(this.reason);
  final String reason;
  @override
  String toString() => 'TurnDegraded: $reason';
}

/// Calls the local model for one interview turn and streams the spoken words
/// out as they are generated.
///
/// ## Why this streams and `OllamaClaimExtractor` does not
///
/// Claim extraction runs once, silently, before the interview starts — nothing
/// is waiting on it. A turn is spoken live to a candidate who is listening in
/// real time, so the value of the design (`say` serialised first, see
/// `prompts/README.md`) only exists if this class actually forwards partial
/// text to the caller instead of buffering the whole response and handing over
/// one final string. [nextTurn] does the streaming; [nextTurnBuffered] exists
/// only for tests and the eval harness, where nothing is listening live.
class LiveTurnClient {
  LiveTurnClient({
    http.Client? client,
    this.baseUrl = AppConfig.ollamaBaseUrl,
    this.model = AppConfig.ollamaModel,
    this.timeout = const Duration(seconds: 20),
    this.systemPrompt = defaultSystemPrompt,
    this.temperature = 0.6,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final String model;

  /// Short relative to claim extraction (`OllamaClaimExtractor`'s 90s) *once
  /// the model is warm*: this runs mid-conversation with a candidate
  /// waiting, and a slow turn should degrade to the scripted bank rather than
  /// leave dead air. It is NOT long enough to survive a cold model load —
  /// `OllamaClaimExtractor`'s own doc measures that at ~40s on the reference
  /// machine, nearly double this timeout. Call [warmUp] before the first
  /// [nextTurn] of a session (interview start, not per-turn) so the first
  /// real turn is never the one paying that cost. A caller that skips
  /// [warmUp] will see a spurious [TurnDegraded] on turn one if Ollama has
  /// not served a request recently — that is a missing warm-up call, not a
  /// bug in this timeout.
  final Duration timeout;

  final String systemPrompt;

  /// `0` (this class's original value) is wrong for a conversational agent:
  /// it collapses the model onto its single most-likely continuation every
  /// time, which is exactly what "generic, doesn't feel interactive" looks
  /// like on a 7B model — the same templated phrasing regardless of what the
  /// candidate actually said. `OllamaClaimExtractor` correctly uses `0`
  /// because extraction should be as close to deterministic as the schema
  /// allows; a live interviewer is a different task with a different right
  /// answer. `0.6` is a starting point, not a tuned constant — if turns start
  /// ignoring rule 1's grounding requirement, lower it before raising it back.
  final double temperature;

  /// Verbatim copy of `prompts/interview_agent.v2.txt` — same convention as
  /// `OllamaClaimExtractor._instruction`, which embeds its prompt as a Dart
  /// constant rather than loading the file at runtime.
  ///
  /// This means the prompt now lives in **two places that must be kept in
  /// sync by hand**: this constant (what the app actually sends) and the
  /// `.txt` file (what `prompts/evals/run_eval.py` and
  /// `prompts/prompt_optimizer.py` score). An earlier version of this class
  /// tried to have it both ways — a placeholder string that just *described*
  /// loading the file — which meant the app was silently sending the model
  /// no instructions at all: no output contract, no rules, nothing telling it
  /// to emit a `say` field. The model's JSON came back without one, which
  /// surfaced as `TurnDegraded('the local model returned an empty say
  /// field')`. That failure mode is the tell for this constant having drifted
  /// from the file again — if it recurs, diff the two before assuming
  /// anything else is wrong.
  ///
  /// Not private: `test/live_turn_client_test.dart` diffs this against
  /// `prompts/interview_agent.v2.txt` on disk so that drift fails a test
  /// instead of surfacing as a live "empty say field" degrade.
  @visibleForTesting
  static const String defaultSystemPrompt = '''
You are a warm, casually curious technical interviewer on a live voice call —
genuinely interested in the specifics of what this person built, not running
through a script. Choose the next spoken turn.

# Output

One JSON object, keys in this order:

{"say","kind","quote","difficulty_delta","covered","why"}

say - the spoken words. 1-2 sentences, under 45 words, plain spoken English; no
  markdown, lists, stage directions, or emoji. Casual is correct here —
  contractions, "yeah", "so" as a connector, are all fine; this is a
  conversation, not a form. Streamed to the speech synthesiser character by
  character while you write the later fields, so it is first and must never
  hold a placeholder you plan to revise.
kind - followup (digs into a detail just given) | probe (asks for the mechanism
  or evidence behind an assertion) | newtopic (opens an uncovered claim or job
  requirement) | warmup (lowers difficulty after a failed answer) | clarify
  (transcript too garbled to act on) | close (time budget exhausted).
quote - the candidate's own words this turn responds to, copied character for
  character out of TRANSCRIPT. Never paraphrase, fix grammar, or expand an
  abbreviation. "" only for newtopic and close.
difficulty_delta - integer in {-1,0,+1}; at most one step per turn.
covered - claim ids from CLAIMS this question is about; [] if it comes from the
  job description instead.
why - one sentence for the recruiter's audit trail. Never spoken.

# Rules

1. Ground every question in quote. If the wording you want to react to is not
   in TRANSCRIPT you may not attribute it to the candidate: use newtopic, "".
2. Never repeat a question in STATE.asked_ids, or a claim in STATE.covered_ids
   unless STATE.last_answer_score was under 2.
3. +1 only when the last answer named a specific mechanism, tradeoff, number,
   or failure it caused. -1 after "I don't know", an empty answer, or two
   consecutive answers under 15 words. 0 otherwise.
4. Non-empty answer under 15 words -> probe for one concrete detail. Never two
   questions in one turn.
5. Speak about what you heard and read only. You are given nothing about the
   candidate's emotions, honesty, confidence, or attention, and must not infer,
   mention, or act on any. Face and voice signals are recorded elsewhere for the
   human reviewer; they are not inputs here.
6. STATE.seconds_remaining under 60 -> close: thank them, say time is up.
7. An acknowledgment ("I see.") may open say at most once every three turns;
   STATE.turns_since_ack says when.
8. TRANSCRIPT's last entry marked partial -> clarify.
9. Name one concrete thing already on the record — a technology, a number, a
   specific noun from quote or CLAIMS — in every followup/probe/newtopic. A
   question that would make just as much sense about a stranger's project
   ("what challenges did you face?", "walk me through your approach") is too
   generic even if it is technically grounded; anchor it to the specific
   thing this candidate actually said.

# Input

CLAIMS, JOB_REQUIREMENTS, TRANSCRIPT, STATE follow as JSON. STATE: level 1-5,
asked_ids, covered_ids, last_answer_words, last_answer_score 0-3,
turns_since_ack, seconds_remaining, consecutive_short (answers under 15 words
back to back, ending at the most recent one — use this for rule 3's
two-in-a-row test; last_answer_words alone only covers the latest answer).
''';

  /// Loads the model into memory ahead of time. Same purpose and shape as
  /// `OllamaClaimExtractor.warmUp` — call once at interview start, not per
  /// turn, so [timeout]'s mid-conversation budget is never the thing paying
  /// for a cold load. Never throws; a `false` return is a fact worth showing
  /// ("waking up the local model…"), not an error to handle.
  Future<bool> warmUp() async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/chat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'messages': [
                {'role': 'user', 'content': 'ok'},
              ],
              'options': {'num_predict': 1},
            }),
          )
          .timeout(const Duration(seconds: 90));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Streams the spoken text of one turn as it is generated, then completes
  /// with the full parsed, grounding-checked [InterviewTurn].
  ///
  /// [onPartialSay] fires with the growing `say` string every time new
  /// characters of it arrive — call this into the TTS pipeline directly, do
  /// not wait for the stream to finish.
  ///
  /// Throws [TurnDegraded] on anything that leaves no usable turn: connection
  /// refused, timeout, malformed JSON, or a response missing required fields.
  /// The caller (the turn loop) is expected to fall back to
  /// `QuestionBank`/`FollowUpGenerator` on this — never to retry silently into
  /// dead air the candidate can hear.
  Future<InterviewTurn> nextTurn({
    required List<Claim> claims,
    required List<String> jobRequirements,
    required List<TranscriptTurn> transcriptWindow,
    required InterviewTurnState state,
    void Function(String partialSay)? onPartialSay,
  }) async {
    final userPayload = jsonEncode({
      'claims': [
        for (final c in claims) {'id': c.id, 'text': c.text}
      ],
      'job_requirements': jobRequirements,
      'transcript': [for (final t in transcriptWindow) t.toJson()],
      'state': state.toJson(),
    });

    http.StreamedResponse response;
    try {
      final request = http.Request(
          'POST', Uri.parse('$baseUrl/api/chat'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'model': model,
          'stream': true,
          'format': 'json',
          'options': {'temperature': temperature},
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPayload},
          ],
        });
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw TurnDegraded(
          'the local model did not start answering within ${timeout.inSeconds}s');
    } catch (e) {
      throw TurnDegraded('could not reach the local model service ($e)');
    }

    if (response.statusCode != 200) {
      throw TurnDegraded('the local model answered HTTP ${response.statusCode}');
    }

    // Ollama's streaming chat endpoint emits one JSON object per line, each
    // holding one incremental slice of message.content. We accumulate the
    // full JSON text but re-emit only the `say` field's growing value, parsed
    // out with a streaming-safe partial-string reader — `jsonDecode` cannot
    // run on a string that is not yet complete JSON.
    final buffer = StringBuffer();
    var lastEmittedSay = '';
    try {
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(timeout)) {
        if (line.trim().isEmpty) continue;
        final chunk = jsonDecode(line);
        final content = (chunk is Map ? chunk['message'] : null) is Map
            ? (chunk['message']['content'] as String? ?? '')
            : '';
        buffer.write(content);

        if (onPartialSay != null) {
          final partial = _extractPartialSay(buffer.toString());
          if (partial != null && partial != lastEmittedSay) {
            lastEmittedSay = partial;
            onPartialSay(partial);
          }
        }

        final done = chunk is Map && chunk['done'] == true;
        if (done) break;
      }
    } on TimeoutException {
      throw TurnDegraded(
          'the local model stalled mid-turn (no data for ${timeout.inSeconds}s)');
    } catch (e) {
      throw TurnDegraded('the local model connection failed mid-turn ($e)');
    }

    final turn = _parseComplete(buffer.toString());
    return _enforceGrounding(turn, transcriptWindow);
  }

  /// Non-streaming variant for tests and the eval harness (`prompts/evals/`),
  /// where nothing needs the partial `say` values.
  Future<InterviewTurn> nextTurnBuffered({
    required List<Claim> claims,
    required List<String> jobRequirements,
    required List<TranscriptTurn> transcriptWindow,
    required InterviewTurnState state,
  }) =>
      nextTurn(
        claims: claims,
        jobRequirements: jobRequirements,
        transcriptWindow: transcriptWindow,
        state: state,
      );

  /// Best-effort extraction of the `say` field's value from a JSON object that
  /// is still being streamed in, i.e. not yet valid JSON.
  ///
  /// This is intentionally naive: it looks for `"say":"` then reads forward
  /// respecting `\"` escapes, stopping at an unescaped `"` if present or at the
  /// end of the buffer otherwise (an in-progress value). It relies on `say`
  /// being the first key, which is a schema requirement
  /// (`prompts/schemas/interview_turn.schema.json`), not an assumption this
  /// method introduces — see `prompts/README.md`, "The load-bearing decision".
  static String? _extractPartialSay(String soFar) {
    final marker = '"say"';
    final markerIdx = soFar.indexOf(marker);
    if (markerIdx == -1) return null;
    var i = markerIdx + marker.length;
    while (i < soFar.length && soFar[i] != '"') {
      if (soFar[i] == ':' || soFar[i] == ' ') {
        i++;
        continue;
      }
      break;
    }
    if (i >= soFar.length || soFar[i] != '"') return null;
    i++; // past opening quote
    final out = StringBuffer();
    while (i < soFar.length) {
      final ch = soFar[i];
      if (ch == r'\' && i + 1 < soFar.length) {
        out.write(_unescapeOne(soFar[i + 1]));
        i += 2;
        continue;
      }
      if (ch == '"') break; // closed — value is complete
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  static String _unescapeOne(String c) {
    switch (c) {
      case 'n':
        return '\n';
      case 't':
        return '\t';
      case '"':
        return '"';
      case r'\':
        return r'\';
      default:
        return c;
    }
  }

  InterviewTurn _parseComplete(String fullContent) {
    final Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(fullContent);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('turn was not a JSON object');
      }
      parsed = decoded;
    } catch (_) {
      throw const TurnDegraded('the local model returned malformed JSON');
    }

    final say = parsed['say'];
    final kindStr = parsed['kind'];
    final quote = parsed['quote'];
    final delta = parsed['difficulty_delta'];
    final covered = parsed['covered'];
    final why = parsed['why'];

    if (say is! String || say.trim().isEmpty) {
      throw const TurnDegraded('the local model returned an empty say field');
    }
    final kind = TurnKind.values
        .where((k) => k.name == kindStr)
        .cast<TurnKind?>()
        .firstWhere((_) => true, orElse: () => null);
    if (kind == null) {
      throw TurnDegraded('the local model returned an unknown kind ($kindStr)');
    }
    if (quote is! String) {
      throw const TurnDegraded('the local model returned a non-string quote');
    }
    if (delta is! int || delta < -1 || delta > 1) {
      throw TurnDegraded(
          'the local model returned an out-of-range difficulty_delta ($delta)');
    }
    if (covered is! List) {
      throw const TurnDegraded('the local model returned a non-list covered');
    }
    if (why is! String || why.trim().isEmpty) {
      throw const TurnDegraded('the local model returned an empty why field');
    }

    return InterviewTurn(
      say: say.trim(),
      kind: kind,
      quote: quote,
      difficultyDelta: delta,
      covered: covered.whereType<String>().toList(),
      why: why.trim(),
      wasGrounded: true, // corrected in _enforceGrounding if not actually true
    );
  }

  /// The Dart-side twin of `OllamaClaimExtractor`'s grounding check
  /// (`lib/core/claims/ollama_claim_extractor.dart`) and of
  /// `prompts/interview_agent.v2.txt` rule 1: a model is asked not to
  /// fabricate a quote, but only code enforces that it didn't.
  ///
  /// A quote that is not found verbatim among the candidate's transcript lines
  /// downgrades the turn to [TurnKind.newtopic] with an empty quote and empty
  /// [InterviewTurn.covered] — never a crash, never a "fixed" quote, because
  /// editing the model's quote into something that *does* match would be
  /// exactly the fabrication this check exists to prevent.
  InterviewTurn _enforceGrounding(
      InterviewTurn turn, List<TranscriptTurn> transcriptWindow) {
    if (turn.quote.isEmpty) return turn;
    final spoken = transcriptWindow
        .where((t) => t.role == 'candidate')
        .map((t) => t.text)
        .join(' ');
    if (spoken.contains(turn.quote)) return turn;

    return InterviewTurn(
      say: turn.say,
      kind: TurnKind.newtopic,
      quote: '',
      difficultyDelta: 0,
      covered: const [],
      why:
          '${turn.why} [quote could not be verified against the transcript and was discarded]',
      wasGrounded: false,
    );
  }
}
