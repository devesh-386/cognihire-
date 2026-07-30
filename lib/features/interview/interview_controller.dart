import '../../core/claims/claim.dart';
import '../../core/claims/claim_audit.dart';
import '../../core/interview/followup.dart';
import '../../core/interview/question_bank.dart';
import '../../core/session/session_event_log.dart';
import '../../core/telemetry/process_telemetry.dart';
import '../../core/verification/verification_result.dart';

/// A follow-up that was asked, plus the candidate's answer if they gave one.
class AskedFollowUp {
  AskedFollowUp({required this.followUp, required this.askedAt});

  final FollowUp followUp;
  final DateTime askedAt;

  String? response;
  DateTime? respondedAt;

  bool get wasAnswered => (response ?? '').trim().isNotEmpty;
}

/// Drives one interview: a sequence of claims, each with a task, live process
/// telemetry, and follow-ups triggered by how the answer is produced.
///
/// Holds every observation needed to assemble the audit at the end, so the
/// audit is built from what actually happened rather than reconstructed.
///
/// Pure Dart — no Flutter, no camera, no network — so the whole flow is
/// testable end to end.
class InterviewController {
  InterviewController({
    required this.claims,
    FollowUpGenerator generator = const FollowUpGenerator(),
    this._questionBank = const QuestionBank(),
    DateTime? startedAt,

    /// The candidate's research-release choice, made *before* this
    /// constructor runs (a consent UI upstream). `null` means the choice was
    /// never asked or not yet recorded — distinct from an explicit `false`,
    /// and logged as neither: silence about consent must not be read as
    /// either a grant or a refusal.
    bool? researchConsentGranted,
  })  : _generator = generator, // ignore: prefer_initializing_formals
        sessionStart = startedAt ?? DateTime.now() {
    _eventLog.append(
      SessionEventKind.sessionStarted,
      at: sessionStart,
      payload: {'claimCount': claims.length},
    );
    // Logged immediately after sessionStarted and before any claim opens, so
    // the choice is always on record before any candidate data is collected.
    if (researchConsentGranted != null) {
      _eventLog.append(
        SessionEventKind.researchConsentSet,
        at: sessionStart,
        payload: {'granted': researchConsentGranted},
      );
    }
    if (claims.isNotEmpty) _beginClaim(0, at: sessionStart);
  }

  final List<Claim> claims;
  final FollowUpGenerator _generator;
  final QuestionBank _questionBank;
  final DateTime sessionStart;

  /// The scripted question ladder per claim, built once when the claim opens.
  final Map<String, List<Question>> _questionsByClaim = {};

  /// What each claim was classified as — **including the nulls**. A claim the
  /// bank could not type gets no ladder, and that gap is recorded rather than
  /// papered over with a generic question, because a generic question asked as
  /// if it were targeted is worse than an honest "ask your own here".
  final Map<String, ClaimType?> _typeByClaim = {};

  final Map<String, ProcessTelemetry> _telemetryByClaim = {};
  final Map<String, List<AskedFollowUp>> _followUpsByClaim = {};
  final Map<String, String> _answersByClaim = {};
  final List<VerificationResult> _identityAttempts = [];

  /// Tamper-evident record of what happened, in order. Written alongside the
  /// audit; the audit is the conclusion, this is the provenance behind it.
  final SessionEventLog _eventLog = SessionEventLog();
  SessionEventLog get eventLog => _eventLog;

  int _currentIndex = 0;
  DateTime? _endedAt;

  int get currentIndex => _currentIndex;
  bool get isComplete => _endedAt != null;
  Claim? get currentClaim =>
      _currentIndex < claims.length ? claims[_currentIndex] : null;

  List<VerificationResult> get identityAttempts =>
      List.unmodifiable(_identityAttempts);

  ProcessTelemetry? telemetryFor(String claimId) => _telemetryByClaim[claimId];

  List<AskedFollowUp> followUpsFor(String claimId) =>
      List.unmodifiable(_followUpsByClaim[claimId] ?? const []);

  String answerFor(String claimId) => _answersByClaim[claimId] ?? '';

  void _beginClaim(int index, {DateTime? at}) {
    final claim = claims[index];
    final now = at ?? DateTime.now();
    _telemetryByClaim.putIfAbsent(
      claim.id,
      () => ProcessTelemetry(taskStartedAt: now),
    );
    _followUpsByClaim.putIfAbsent(claim.id, () => []);

    // Build the scripted ladder once, at open. Doing it here rather than on
    // demand keeps the questions stable for the whole claim — a ladder that
    // silently changed between glances would make the session unreproducible.
    if (!_typeByClaim.containsKey(claim.id)) {
      final type = QuestionBank.classify(claim);
      _typeByClaim[claim.id] = type;
      _questionsByClaim[claim.id] = type == null
          ? const []
          : _questionBank.ladderFor(claim, type, seed: _seedFor(claim.id));
    }

    _eventLog.append(
      SessionEventKind.claimOpened,
      at: now,
      payload: {
        'claimId': claim.id,
        'index': index,
        // Recorded so the audit can show which ladder was asked, and so an
        // unclassified claim is visible in the log rather than looking like a
        // claim nobody bothered to probe.
        'claimType': _typeByClaim[claim.id]?.name,
        'scriptedQuestions': _questionsByClaim[claim.id]?.length ?? 0,
      },
    );
  }

  /// A per-claim seed that is stable across runs and machines.
  ///
  /// Deliberately not `claimId.hashCode`: Dart makes no promise that String
  /// hashes are stable between processes, so the same session could produce
  /// different questions on a re-run and nobody would know why.
  static int _seedFor(String claimId) =>
      claimId.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x3FFFFFFF);

  /// The scripted ladder for [claimId] — empty when the claim could not be
  /// classified. Empty means "we have nothing targeted to ask", not "this claim
  /// needs no probing".
  List<Question> questionsFor(String claimId) =>
      List.unmodifiable(_questionsByClaim[claimId] ?? const []);

  /// What [claimId] was classified as, or null when the bank declined to guess.
  ClaimType? claimTypeFor(String claimId) => _typeByClaim[claimId];

  /// Record every identity verification attempt, including unmeasured ones.
  /// The audit reports coverage, so the gaps matter as much as the successes.
  void recordIdentityAttempt(VerificationResult result) {
    _identityAttempts.add(result);
    // Log the outcome only — never the embedding, never a face. The switch is
    // exhaustive so a new result variant is a compile error, not a silent gap.
    final (outcome, at) = switch (result) {
      Verified(:final at) => ('verified', at),
      Mismatch(:final at) => ('mismatch', at),
      Unchecked(:final at) => ('unchecked', at),
    };
    _eventLog.append(
      SessionEventKind.identityChecked,
      at: at,
      payload: {'outcome': outcome},
    );
  }

  /// Record the candidate's answer buffer changing.
  ///
  /// Returns any follow-ups newly triggered by this edit, so the UI can present
  /// them the moment they arise rather than at submission.
  List<AskedFollowUp> recordEdit(String text, {DateTime? at}) {
    final claim = currentClaim;
    if (claim == null || isComplete) return const [];

    final now = at ?? DateTime.now();
    _answersByClaim[claim.id] = text;

    final telemetry = _telemetryByClaim[claim.id]!;
    telemetry.record(text.length, at: now);

    final existing = _followUpsByClaim[claim.id]!;
    final generated = _generator.generate(telemetry);

    // Match on the observation string: it encodes the span size and trigger,
    // so an unchanged observation is the same question, not a new one.
    final known = existing.map((a) => a.followUp.observation).toSet();
    final fresh = generated
        .where((f) => !known.contains(f.observation))
        .map((f) => AskedFollowUp(followUp: f, askedAt: now))
        .toList();

    existing.addAll(fresh);

    // Log each newly-raised follow-up. The observation string describes the
    // trigger (span size, timing) and carries no answer text — the typed
    // characters never enter the log.
    for (final asked in fresh) {
      _eventLog.append(
        SessionEventKind.followUpAsked,
        at: now,
        payload: {
          'claimId': claim.id,
          'observation': asked.followUp.observation,
        },
      );
    }

    return List.unmodifiable(fresh);
  }

  /// Attach the candidate's response to a follow-up.
  void answerFollowUp(String claimId, AskedFollowUp asked, String response,
      {DateTime? at}) {
    asked.response = response;
    asked.respondedAt = at ?? DateTime.now();
  }

  /// Move to the next claim. Returns false when there are none left.
  bool advance({DateTime? at}) {
    if (_currentIndex + 1 >= claims.length) return false;
    _currentIndex++;
    _beginClaim(_currentIndex, at: at);
    return true;
  }

  void end({DateTime? at}) {
    if (_endedAt != null) return; // Ending twice records one end, not two.
    _endedAt = at ?? DateTime.now();
    _eventLog.append(SessionEventKind.sessionEnded, at: _endedAt!);
  }

  /// Assemble the audit from the session's own record.
  ///
  /// Status rules, in full — this is the entire decision layer:
  ///
  /// * no telemetry and no answer      → notExamined
  /// * follow-ups asked but unanswered → notDemonstrated
  /// * answered, with a response to every follow-up raised → substantiated
  ///
  /// Note what is absent: nothing here weighs how *good* an answer was. This
  /// system records that a question was put and a response was given; judging
  /// the substance of that response is the reviewer's job, and pretending
  /// otherwise would be the composite-score trap in disguise.
  ClaimAudit buildAudit({DateTime? at}) {
    final end = _endedAt ?? at ?? DateTime.now();
    final evidence = <String, List<ClaimEvidence>>{};
    final assessments = <String, ClaimStatus>{};

    for (final claim in claims) {
      final telemetry = _telemetryByClaim[claim.id];
      final asked = _followUpsByClaim[claim.id] ?? const <AskedFollowUp>[];
      final answer = _answersByClaim[claim.id] ?? '';
      final entries = <ClaimEvidence>[];

      if (telemetry != null && telemetry.events.isNotEmpty) {
        final s = telemetry.signals();
        entries.add(ClaimEvidence(
          kind: EvidenceKind.processSignal,
          at: telemetry.events.first.at,
          observation: _describeProcess(s),
        ));
      }

      for (final a in asked) {
        entries.add(ClaimEvidence(
          kind: EvidenceKind.probeResponse,
          at: a.askedAt,
          observation: a.wasAnswered
              ? 'Asked: "${a.followUp.question}" — ${a.followUp.observation} '
                  'Candidate responded.'
              : 'Asked: "${a.followUp.question}" — ${a.followUp.observation} '
                  'No response recorded.',
        ));
      }

      if (entries.isNotEmpty) {
        evidence[claim.id] = entries;

        final answered = answer.trim().isNotEmpty;
        final allProbesAnswered = asked.every((a) => a.wasAnswered);
        assessments[claim.id] = answered && allProbesAnswered
            ? ClaimStatus.substantiated
            : ClaimStatus.notDemonstrated;
      }
    }

    return const ClaimAuditBuilder().build(
      claims: claims,
      evidenceByClaimId: evidence,
      reviewerAssessments: assessments,
      identityAttempts: _identityAttempts,
      sessionStart: sessionStart,
      sessionEnd: end,
      sessionEventsJsonl: _eventLog.toJsonl(),
    );
  }

  static String _describeProcess(ProcessSignals s) {
    final bits = <String>[
      if (s.timeToFirstKeystroke != null)
        'began after ${s.timeToFirstKeystroke!.inSeconds}s',
      '${s.totalInserted} characters written',
      if (s.revisionRatio != null)
        'revision ratio ${(s.revisionRatio! * 100).toStringAsFixed(0)}%',
      if (s.bulkInsertCount > 0)
        '${s.bulkInsertCount} bulk insertion(s), largest '
            '${s.largestBulkInsert} characters',
      if (s.pauseCount > 0) '${s.pauseCount} pause(s)',
    ];
    return 'Answer produced: ${bits.join(', ')}.';
  }
}
