import 'package:flutter/foundation.dart';

import '../../core/claims/claim.dart';
import '../../core/interview/live_turn_client.dart';

/// What the voice screen should be showing right now.
///
/// Four states, not more — each maps to one visible thing on screen (the
/// presence indicator's motion) and one thing the candidate should be doing.
/// A fifth "error" state was considered and rejected: a turn that fails
/// degrades to [degradedReason] set while state returns to [listening], so the
/// interview keeps moving instead of showing the candidate a dead screen.
enum VoicePresence {
  /// Waiting for the candidate to speak.
  listening,

  /// A candidate utterance was submitted; the model has not started replying.
  thinking,

  /// `say` is streaming out and being read aloud.
  speaking,

  /// [InterviewTurn.kind] was `close`, or [end] was called.
  ended,
}

/// Drives the live voice screen: turns candidate utterances into model turns
/// and exposes exactly what the UI needs to render, one field at a time.
///
/// Pure Dart plus [LiveTurnClient]'s network call — no camera, no audio
/// capture. Wiring an actual microphone/LiveKit transport means calling
/// [submitCandidateUtterance] with whatever text Whisper produced; this class
/// does not care where that text came from, which is what makes it testable
/// without a working mic (see `test/interview_voice_controller_test.dart`).
class InterviewVoiceController extends ChangeNotifier {
  InterviewVoiceController({
    required this.claims,
    required this.jobRequirements,
    LiveTurnClient? client,
    this.windowTurns = 6,
    this.totalSeconds = 1800,
    DateTime Function() now = DateTime.now,
  })  : _client = client ?? LiveTurnClient(),
        _now = now,
        _startedAt = now();

  final List<Claim> claims;
  final List<String> jobRequirements;
  final LiveTurnClient _client;
  final DateTime Function() _now;
  final DateTime _startedAt;

  /// How many prior turns ride along as context. Bounded deliberately — see
  /// `prompts/README.md`'s "Structural baseline" section: the fixed prompt
  /// prefix is cheap to repeat locally, but the transcript is the part that
  /// actually grows every turn, so it is capped rather than sent in full.
  final int windowTurns;

  final int totalSeconds;

  VoicePresence presence = VoicePresence.listening;

  /// The words currently being spoken, growing character by character as the
  /// model streams `say` — bind this straight to the caption/TTS feed.
  String currentSay = '';

  /// Set when a turn could not be produced live and the caller should reach
  /// for `QuestionBank`/`FollowUpGenerator` instead (see
  /// `lib/features/interview/interview_controller.dart`). Cleared on the next
  /// successful turn — a single dropped turn does not end the interview.
  String? degradedReason;

  final List<TranscriptTurn> _transcript = [];
  final List<String> _askedIds = [];
  final List<String> _coveredIds = [];
  int _level = 3;

  /// Stays at its initial value: `scoring_agent.txt` is not wired to this
  /// controller yet, so nothing ever updates it. Rule 2 ("never re-ask a
  /// claim scored below 2") is inert until a scoring call is added after
  /// each candidate turn and its result assigned here.
  final int _lastAnswerScore = 1;
  int _turnsSinceAck = 3;
  int _consecutiveShortAnswers = 0;

  List<TranscriptTurn> get transcript => List.unmodifiable(_transcript);

  /// Loads the model into memory. Call once when the interview screen opens,
  /// before the candidate can submit anything — see [LiveTurnClient.timeout]'s
  /// doc for why: the per-turn timeout is sized for a model that is already
  /// warm, and skipping this call risks the first real turn eating a cold
  /// load it has no budget for.
  Future<bool> warmUp() => _client.warmUp();

  /// Records the interviewer's opening line — the question asked before any
  /// candidate turn exists to respond to.
  ///
  /// This is not [_applyTurn]: there is no [InterviewTurn] behind an opening
  /// line (no model call produced it, nothing was covered, no difficulty was
  /// set), so it only does the transcript bookkeeping. Call it once, before
  /// the first [submitCandidateUtterance] — skipping it is a real bug, not a
  /// cosmetic one: the caption would show a question the model never actually
  /// asked, so the *next* call's transcript has no record of it either, and
  /// the very first follow-up is generated blind to what was supposedly asked.
  /// (This shipped once — a demo harness set [currentSay] directly instead of
  /// calling this, and the first real answer got a generic, unanchored
  /// follow-up because the model had no opening question to react to.)
  void openWithQuestion(String question) {
    currentSay = question;
    _transcript.add(TranscriptTurn(role: 'interviewer', text: question));
    notifyListeners();
  }

  int get _secondsRemaining {
    final elapsed = _now().difference(_startedAt).inSeconds;
    return (totalSeconds - elapsed).clamp(0, totalSeconds);
  }

  /// Feed one candidate utterance in and drive the next turn.
  ///
  /// Safe to call only from [VoicePresence.listening] — the screen is
  /// expected to disable input otherwise, same convention as
  /// [InterviewController] gating on session state rather than trusting the
  /// caller not to double-submit.
  Future<void> submitCandidateUtterance(String text) async {
    if (presence != VoicePresence.listening) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _transcript.add(TranscriptTurn(role: 'candidate', text: trimmed));
    _consecutiveShortAnswers =
        trimmed.split(RegExp(r'\s+')).length < 15 ? _consecutiveShortAnswers + 1 : 0;

    presence = VoicePresence.thinking;
    currentSay = '';
    notifyListeners();

    final state = InterviewTurnState(
      level: _level,
      askedIds: List.of(_askedIds),
      coveredIds: List.of(_coveredIds),
      lastAnswerWords: trimmed.split(RegExp(r'\s+')).length,
      lastAnswerScore: _lastAnswerScore,
      turnsSinceAck: _turnsSinceAck,
      secondsRemaining: _secondsRemaining,
      consecutiveShortAnswers: _consecutiveShortAnswers,
    );
    final window = _transcript.length > windowTurns
        ? _transcript.sublist(_transcript.length - windowTurns)
        : _transcript;

    InterviewTurn turn;
    try {
      turn = await _client.nextTurn(
        claims: claims,
        jobRequirements: jobRequirements,
        transcriptWindow: window,
        state: state,
        onPartialSay: (partial) {
          if (presence == VoicePresence.thinking) {
            presence = VoicePresence.speaking;
          }
          currentSay = partial;
          notifyListeners();
        },
      );
    } on TurnDegraded catch (e) {
      degradedReason = e.reason;
      presence = VoicePresence.listening;
      notifyListeners();
      return;
    }

    degradedReason = null;
    _applyTurn(turn);
  }

  void _applyTurn(InterviewTurn turn) {
    currentSay = turn.say;
    _transcript.add(TranscriptTurn(role: 'interviewer', text: turn.say));
    _askedIds.add('${_transcript.length}');
    _coveredIds.addAll(turn.covered);
    _level = (_level + turn.difficultyDelta).clamp(1, 5);
    _turnsSinceAck =
        turn.say.toLowerCase().startsWith(RegExp(r'i see|got it|interesting'))
            ? 0
            : _turnsSinceAck + 1;

    presence =
        turn.kind == TurnKind.close ? VoicePresence.ended : VoicePresence.listening;
    notifyListeners();
  }

  /// Ends the session without waiting for the model to emit `close` — the
  /// candidate or interviewer can always end it from the controls, same as a
  /// human interviewer ending a call.
  void end() {
    presence = VoicePresence.ended;
    notifyListeners();
  }
}
