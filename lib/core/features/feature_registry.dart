/// The feature registry: every ML feature this project computes, declared in
/// one place before any model reads one.
///
/// ## Why a registry rather than ad-hoc doubles floating around the codebase
///
/// `ML_REDESIGN.md` calls for 158 features across 10 groups (typing, editing,
/// temporal, identity, interview, claim, semantic, session, graph, cross-modal).
/// A feature that exists only as a field on some class has no name a model
/// card can cite, no version a stored vector can be checked against, and no
/// single place to see what "null" means for it. The registry fixes all three:
/// every feature is declared with a group-qualified name, a description, and
/// whether it is allowed to be null.
///
/// ## The null-semantics rule
///
/// A feature is null when it genuinely could not be measured — fewer than two
/// keystrokes to compute an interval from, no identity check attempted, no
/// claim yet opened. It is never coerced to 0 to keep a model happy. Silently
/// turning "not measured" into "measured as zero" is how a candidate who typed
/// nothing looks identical, to a downstream model, to one who typed calmly and
/// evenly — the two are not the same fact and must not collapse into one
/// number. [FeatureSpec.nullable] documents, per feature, whether null is even
/// a possible value; a feature that is always computable (a count) being
/// non-nullable is itself a check the assembler must satisfy.
library;

/// One declared feature.
class FeatureSpec {
  const FeatureSpec({
    required this.name,
    required this.group,
    required this.description,
    this.nullable = true,
  });

  /// Group-qualified, e.g. `typing.meanInterKeyIntervalMs`. The prefix before
  /// the first `.` must match [group].
  final String name;

  /// One of the ten feature groups from the ML redesign (typing, editing,
  /// temporal, identity, interview, claim, semantic, session, graph,
  /// crossModal). Free text here rather than an enum deliberately — new groups
  /// arrive across Phase 1–6 and the registry should not need a schema change
  /// to add one; [FeatureRegistry] validates the name/group prefix agreement,
  /// which is the check that actually matters.
  final String group;

  final String description;

  /// Whether this feature may legitimately be null. A feature declared
  /// non-nullable that the assembler emits as null (or vice versa) is a bug in
  /// the assembler, not a fact about the session.
  final bool nullable;
}

/// Bumped whenever a feature is added, removed, renamed, or its definition
/// changes in a way that would make old and new values not comparable. A
/// stored [FeatureVector] records the version it was computed under so a
/// consumer can refuse to compare vectors across a definition change.
const int featureRegistryVersion = 1;

/// The registry of every declared feature.
///
/// Deliberately a hand-maintained, explicit list rather than reflection over
/// some annotated class — the list of 158 features from the ML redesign is
/// meant to be reviewable in one file, the way the reference architecture's
/// hardcoded weight table was reviewable (and wrong). A feature that exists in
/// code but not here is a feature no model card can cite.
class FeatureRegistry {
  FeatureRegistry._(this.specs) {
    final seen = <String>{};
    for (final spec in specs) {
      if (!seen.add(spec.name)) {
        throw StateError('duplicate feature name in registry: ${spec.name}');
      }
      final prefix = spec.name.split('.').first;
      if (prefix != spec.group) {
        throw StateError(
          'feature "${spec.name}" is declared in group "${spec.group}" but '
          'its name prefix is "$prefix"',
        );
      }
    }
  }

  static final FeatureRegistry instance = FeatureRegistry._(_specs);

  final List<FeatureSpec> specs;

  Map<String, FeatureSpec>? _byName;

  /// Look up a feature by name. Throws [ArgumentError] for an unknown name —
  /// there is no default spec, because there is no such thing as an
  /// unregistered feature that is still valid to compute.
  FeatureSpec spec(String name) {
    final index = _byName ??= {for (final s in specs) s.name: s};
    final found = index[name];
    if (found == null) {
      throw ArgumentError('no such feature "$name" in registry '
          'v$featureRegistryVersion');
    }
    return found;
  }

  bool contains(String name) =>
      (_byName ??= {for (final s in specs) s.name: s}).containsKey(name);
}

/// Phase 0 seed set. This is a working slice, not the full 158 — Phase 1.3
/// (feature groups A–C) and Phase 3.1 (D–J) add the rest to this same list as
/// they are implemented, per `ML_REDESIGN.md` §7. Every feature added there
/// must follow the same discipline: group-qualified name, description, and an
/// honest [FeatureSpec.nullable].
const List<FeatureSpec> _specs = [
  // --- Group A: typing dynamics -------------------------------------------
  FeatureSpec(
    name: 'typing.meanInterKeyIntervalMs',
    group: 'typing',
    description:
        'Mean gap between consecutive keystrokes, in milliseconds. Null with '
        'fewer than two keystrokes — an interval needs two points.',
  ),
  FeatureSpec(
    name: 'typing.backspaceRate',
    group: 'typing',
    description:
        'Delete-action keystrokes divided by all keystrokes. 0.0 (not null) '
        'when there were keystrokes and none were deletes.',
  ),
  FeatureSpec(
    name: 'typing.keystrokeCount',
    group: 'typing',
    description: 'Total keystrokes observed. Never null — an empty log is a '
        'genuine count of zero, not an unmeasured quantity.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'typing.stdInterKeyIntervalMs',
    group: 'typing',
    description: 'Population standard deviation of the inter-key gaps, in '
        'milliseconds. Null with fewer than two gaps (fewer than three '
        'keystrokes) — a spread needs at least two data points.',
  ),
  FeatureSpec(
    name: 'typing.maxInterKeyIntervalMs',
    group: 'typing',
    description: 'The single largest gap between consecutive keystrokes, in '
        'milliseconds. Null with fewer than two keystrokes.',
  ),
  FeatureSpec(
    name: 'typing.insertRate',
    group: 'typing',
    description: 'Fraction of keystrokes that were insert actions. Null when '
        'the log is empty — a rate needs a denominator.',
  ),
  FeatureSpec(
    name: 'typing.navRate',
    group: 'typing',
    description: 'Fraction of keystrokes that were cursor-navigation '
        'actions. Null when the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.alphaRate',
    group: 'typing',
    description: 'Fraction of keystrokes classified as alphabetic. Null when '
        'the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.minInterKeyIntervalMs',
    group: 'typing',
    description: 'The single smallest gap between consecutive keystrokes, in '
        'milliseconds. Null with fewer than two keystrokes.',
  ),
  FeatureSpec(
    name: 'typing.medianInterKeyIntervalMs',
    group: 'typing',
    description: 'Median of the inter-key gaps, in milliseconds — more '
        'robust to a single outlier pause than the mean. Null with fewer '
        'than two keystrokes.',
  ),
  FeatureSpec(
    name: 'typing.digitRate',
    group: 'typing',
    description: 'Fraction of keystrokes classified as digits. Null when the '
        'log is empty.',
  ),
  FeatureSpec(
    name: 'typing.symbolRate',
    group: 'typing',
    description: 'Fraction of keystrokes classified as symbols. Null when '
        'the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.whitespaceRate',
    group: 'typing',
    description: 'Fraction of keystrokes classified as whitespace. Null when '
        'the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.selectionRate',
    group: 'typing',
    description: 'Fraction of keystrokes that changed the text selection '
        '(not the buffer). Null when the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.modifierRate',
    group: 'typing',
    description: 'Fraction of keystrokes classified as modifier (Shift, '
        'Ctrl, Alt, Meta). Null when the log is empty.',
  ),
  FeatureSpec(
    name: 'typing.cursorTravelTotal',
    group: 'typing',
    description: 'Sum of absolute cursor-position movement between '
        'consecutive keystrokes. Never null — zero for an empty or '
        'single-event log.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'typing.meanSelectionLength',
    group: 'typing',
    description: 'Mean selection length across all keystrokes (including '
        'the many with no active selection, i.e. 0). Null when the log is '
        'empty.',
  ),
  FeatureSpec(
    name: 'typing.p90InterKeyIntervalMs',
    group: 'typing',
    description: '90th-percentile inter-key gap (nearest-rank), in '
        'milliseconds — the tail of the gap distribution, more robust to a '
        'single extreme outlier than the max. Null with fewer than two '
        'keystrokes.',
  ),
  FeatureSpec(
    name: 'typing.interKeyIntervalCV',
    group: 'typing',
    description: 'Coefficient of variation (std / mean) of the inter-key '
        'gaps — a scale-free measure of rhythm irregularity. Null with '
        'fewer than two gaps, or when the mean is zero.',
  ),
  FeatureSpec(
    name: 'typing.veryFastKeystrokeRate',
    group: 'typing',
    description: 'Fraction of inter-key gaps under 30ms — near the lower '
        'bound of unassisted human typing, reported as a measurement for a '
        'follow-up question, not a conclusion. Null with fewer than two '
        'keystrokes.',
  ),
  FeatureSpec(
    name: 'typing.burstCount',
    group: 'typing',
    description: 'Count of maximal runs of keystrokes with no gap larger '
        'than the burst threshold (500ms) between consecutive strokes. Never '
        'null — an empty log has zero bursts.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'typing.longestBurstLength',
    group: 'typing',
    description: 'Keystroke count of the longest burst. Never null — zero '
        'for an empty log.',
    nullable: false,
  ),

  // --- Group C: temporal behaviour -----------------------------------------
  FeatureSpec(
    name: 'temporal.timeToFirstKeystrokeMs',
    group: 'temporal',
    description: 'Milliseconds from task start to the first recorded edit. '
        'Null if nothing was typed.',
  ),
  FeatureSpec(
    name: 'temporal.pauseCount',
    group: 'temporal',
    description: 'Count of gaps between edits at or above the idle threshold. '
        'Never null — zero pauses is a fact, not a gap in measurement.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'temporal.pauseRatio',
    group: 'temporal',
    description: 'Pause count divided by edit count. Null when there were no '
        'edits — a ratio with an empty denominator is not measurable.',
  ),
  FeatureSpec(
    name: 'temporal.hasLongPauseFlag',
    group: 'temporal',
    description: '1.0 if at least one pause reached the idle threshold, '
        'else 0.0. Never null: unlike hasEarlyStartFlag, the underlying '
        'longestPause being null here is itself an unambiguous measurement '
        '("no such pause occurred"), not a gap in what could be measured.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'temporal.hasEarlyStartFlag',
    group: 'temporal',
    description: '1.0 if the first keystroke landed under a 3s threshold '
        'from task start, 0.0 otherwise. Null when nothing was typed — there '
        'is no time-to-first-keystroke to threshold, so the flag is '
        'genuinely inapplicable, not false.',
  ),

  // --- Group B: editing behaviour -------------------------------------------
  FeatureSpec(
    name: 'editing.revisionRatio',
    group: 'editing',
    description: 'Characters deleted over characters inserted. Null when '
        'nothing was inserted — a ratio with an empty denominator is not '
        'measurable, not zero.',
  ),
  FeatureSpec(
    name: 'editing.bulkInsertCount',
    group: 'editing',
    description: 'Count of insertions classified as bulk (paste-sized). Never '
        'null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.bulkDeleteCount',
    group: 'editing',
    description: 'Count of deletions classified as bulk (rewrite-sized). '
        'Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.editCount',
    group: 'editing',
    description: 'Total edit events recorded for the answer. Never null — '
        'zero edits is a genuine count.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.totalInsertedChars',
    group: 'editing',
    description: 'Total characters inserted across the answer. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.totalDeletedChars',
    group: 'editing',
    description: 'Total characters deleted across the answer. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.largestBulkInsertChars',
    group: 'editing',
    description: 'Size in characters of the largest single bulk insertion. '
        'Never null — zero when there were none.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.longestPauseMs',
    group: 'editing',
    description: 'Longest gap between edits at or above the idle threshold, '
        'in milliseconds. Null when no such pause occurred.',
  ),
  FeatureSpec(
    name: 'editing.finalAnswerLengthChars',
    group: 'editing',
    description: "The answer buffer's length at the last recorded edit. "
        'Never null — an untouched buffer has a real length of zero.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.hasBulkInsertFlag',
    group: 'editing',
    description: '1.0 if at least one bulk insertion occurred, else 0.0. '
        'Never null — the absence of a bulk insertion is itself a fact, not '
        'an unmeasured quantity.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.netCharacterChange',
    group: 'editing',
    description: 'Total inserted characters minus total deleted characters. '
        'Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.bulkSpanShareOfTotal',
    group: 'editing',
    description: "The largest bulk insertion's share of all inserted "
        'characters. Null when nothing was inserted — a share of zero has no '
        'denominator to be a share of.',
  ),
  FeatureSpec(
    name: 'editing.averageEditSizeChars',
    group: 'editing',
    description: 'Total characters changed (inserted + deleted) divided by '
        'edit count — the average magnitude of one edit event. Null when '
        'there were no edits.',
  ),
  FeatureSpec(
    name: 'editing.hasBulkDeleteFlag',
    group: 'editing',
    description: '1.0 if at least one bulk deletion occurred, else 0.0. '
        'Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'editing.netToGrossRatio',
    group: 'editing',
    description: 'Net character change divided by gross character churn '
        '(inserted + deleted) — how much of the editing was directly '
        'productive versus back-and-forth. Null when nothing was inserted '
        'or deleted.',
  ),

  // --- Group H: session-level ------------------------------------------------
  //
  // Mirrors ML_REDESIGN.md §7 Group H. Descriptive statistics over the
  // tamper-evident session event log — how the session unfolded in time and
  // by event kind. The log is always supplied to the assembler, so plain
  // counts are always computable (non-nullable, zero-for-empty); only
  // quantities that need a denominator or two time points to exist are
  // nullable. No verdict is synthesised here — these are the shape of the
  // session, not a judgment of it.
  FeatureSpec(
    name: 'session.eventCount',
    group: 'session',
    description: 'Total entries in the session event log. Never null — an '
        'empty log is a real count of zero.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.distinctEventKinds',
    group: 'session',
    description: 'Number of distinct event kinds that appeared. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.claimOpenedCount',
    group: 'session',
    description: 'Count of claimOpened events. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.claimAnsweredCount',
    group: 'session',
    description: 'Count of claimAnswered events. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.followUpCount',
    group: 'session',
    description: 'Count of followUpAsked events. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.identityCheckedCount',
    group: 'session',
    description: 'Count of identityChecked events logged. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.integrityObservedCount',
    group: 'session',
    description: 'Count of integrityObserved events. Never null.',
    nullable: false,
  ),
  FeatureSpec(
    name: 'session.spanMs',
    group: 'session',
    description: 'Milliseconds from the first to the last logged event. Null '
        'with fewer than two events — a span needs two points.',
  ),
  FeatureSpec(
    name: 'session.meanInterEventMs',
    group: 'session',
    description: 'Mean gap between consecutive events, in milliseconds. Null '
        'with fewer than two events.',
  ),
  FeatureSpec(
    name: 'session.eventsPerMinute',
    group: 'session',
    description: 'Event count divided by the session span in minutes. Null '
        'with fewer than two events, or a zero span (all events at one '
        'instant) — a rate with no elapsed time is not measurable.',
  ),
  FeatureSpec(
    name: 'session.answeredToOpenedRatio',
    group: 'session',
    description: 'claimAnswered events over claimOpened events. Null when no '
        'claim was opened — a completion ratio with no opens has no '
        'denominator.',
  ),
  FeatureSpec(
    name: 'session.followUpsPerAnswer',
    group: 'session',
    description: 'followUpAsked events over claimAnswered events. Null when '
        'nothing was answered.',
  ),
  FeatureSpec(
    name: 'session.completedFlag',
    group: 'session',
    description: '1.0 if a sessionEnded event was logged, else 0.0. Never '
        'null — the absence of a clean end is itself a fact.',
    nullable: false,
  ),

  // --- Group D: identity / verification (per session) ----------------------
  //
  // Mirrors ML_REDESIGN.md §7 Group D. Descriptive statistics over the
  // sequence of identity re-verification attempts recorded by
  // `VerificationSession` — how often the system checked, how often it could
  // measure at all, and how the measured similarities were distributed. These
  // describe the *verification process*, never the person: there is no score,
  // ranking, or pass/fail verdict synthesised here.
  //
  // Every feature is nullable for the same reason as Group I: a session may
  // have no verification history supplied at the point a vector is assembled
  // (e.g. a claim examined outside a live proctoring session). "No history
  // supplied" and "an empty history" are different facts — the first is
  // unmeasured (all null), the second a measured run of zero attempts.
  FeatureSpec(
    name: 'identity.checkCount',
    group: 'identity',
    description: 'Total verification attempts, including ones that could not '
        'measure anything (Unchecked).',
  ),
  FeatureSpec(
    name: 'identity.verifiedCount',
    group: 'identity',
    description: 'Attempts that cleared the match threshold.',
  ),
  FeatureSpec(
    name: 'identity.mismatchCount',
    group: 'identity',
    description: 'Attempts that measured a similarity below the threshold.',
  ),
  FeatureSpec(
    name: 'identity.uncheckedCount',
    group: 'identity',
    description: 'Attempts that could not measure anything (no camera, no '
        'face, engine unavailable). Counted, never silently treated as a '
        'pass or a failure.',
  ),
  FeatureSpec(
    name: 'identity.measuredCount',
    group: 'identity',
    description: 'Attempts that produced a real similarity (verified + '
        'mismatch). The honest denominator for similarity statistics.',
  ),
  FeatureSpec(
    name: 'identity.verifiedShareOfMeasured',
    group: 'identity',
    description: 'Verified attempts over measured attempts. Null when nothing '
        'was measured — a share with no denominator is not zero.',
  ),
  FeatureSpec(
    name: 'identity.uncheckedShareOfChecks',
    group: 'identity',
    description: 'Unchecked attempts over all attempts — how much of the '
        'session went unmeasured. Null when there were no attempts.',
  ),
  FeatureSpec(
    name: 'identity.meanSimilarity',
    group: 'identity',
    description: 'Mean rescaled (0–100) similarity over measured attempts. '
        'Null when nothing was measured.',
  ),
  FeatureSpec(
    name: 'identity.minSimilarity',
    group: 'identity',
    description: 'Smallest measured similarity. Null when nothing was '
        'measured.',
  ),
  FeatureSpec(
    name: 'identity.maxSimilarity',
    group: 'identity',
    description: 'Largest measured similarity. Null when nothing was '
        'measured.',
  ),
  FeatureSpec(
    name: 'identity.stdSimilarity',
    group: 'identity',
    description: 'Population standard deviation of measured similarities. '
        'Null with fewer than two measured attempts — a spread needs two '
        'points.',
  ),
  FeatureSpec(
    name: 'identity.similarityRange',
    group: 'identity',
    description: 'Max minus min measured similarity. Null when nothing was '
        'measured.',
  ),
  FeatureSpec(
    name: 'identity.maxConsecutiveMismatches',
    group: 'identity',
    description: 'Longest run of consecutive mismatch attempts in sequence '
        '(a verified or unchecked attempt breaks the run). A sustained run is '
        'a different signal than scattered single misses.',
  ),
  FeatureSpec(
    name: 'identity.hadCriticalMismatchFlag',
    group: 'identity',
    description: '1.0 if any mismatch reached its strikes-allowed limit, else '
        '0.0. Never null once a history is supplied — absence of a critical '
        'mismatch is itself a measurement.',
  ),
  FeatureSpec(
    name: 'identity.firstCheckVerifiedFlag',
    group: 'identity',
    description: '1.0 if the first attempt that measured anything was '
        'verified, else 0.0. Null when no attempt ever measured.',
  ),
  FeatureSpec(
    name: 'identity.longestUncheckedRun',
    group: 'identity',
    description: 'Longest run of consecutive attempts that could not measure '
        '— the longest stretch the session was effectively blind.',
  ),

  // --- Group I: graph / structural (evidence graph, per claim) -------------
  //
  // Mirrors ML_REDESIGN.md §7 Group I. Deliberately structural descriptions
  // only — node/edge counts, connectivity, distance — never a ranking or
  // strength score. `EvidenceGraph` itself refuses to expose
  // strength()/centrality()/rank() for exactly this reason (see its own doc
  // comment, constraint 5); these features stay on the same side of that
  // line.
  //
  // Every one of these is nullable, including plain counts that would
  // otherwise be "always computable": unlike keystrokes or the session log, a
  // graph is not always available at the point a vector is assembled — a
  // claim examined before any evidence exists has no graph yet. "No graph
  // supplied" and "an empty graph" are different facts (unmeasured vs.
  // measured-as-zero), so every feature in this group must be able to say
  // which one happened.
  FeatureSpec(
    name: 'graph.nodeCount',
    group: 'graph',
    description: 'Total nodes in this claim\'s evidence graph.',
  ),
  FeatureSpec(
    name: 'graph.edgeCount',
    group: 'graph',
    description: 'Total edges in this claim\'s evidence graph.',
  ),
  FeatureSpec(
    name: 'graph.edgesPerNode',
    group: 'graph',
    description: 'Edge count divided by node count — a density proxy. Null '
        'when there are no nodes.',
  ),
  FeatureSpec(
    name: 'graph.supportsEdgeCount',
    group: 'graph',
    description: 'Count of edges typed supports.',
  ),
  FeatureSpec(
    name: 'graph.contradictsEdgeCount',
    group: 'graph',
    description: 'Count of edges typed contradicts.',
  ),
  FeatureSpec(
    name: 'graph.provisionalEdgeShare',
    group: 'graph',
    description: 'Share of evidentiary edges (supports/partiallySupports/'
        'contradicts/corroborates) produced by a model judge rather than a '
        'human — "provisional" meaning not yet reviewer-confirmed, never a '
        'judgment on correctness. Null when there are no evidentiary edges.',
  ),
  FeatureSpec(
    name: 'graph.claimNodeDegree',
    group: 'graph',
    description: 'Edges touching the claim node, either direction. Null when '
        'the graph has no claim node (malformed).',
  ),
  FeatureSpec(
    name: 'graph.provenanceDistanceToIdentityCheck',
    group: 'graph',
    description: 'Shortest hop count (edges treated as undirected) from the '
        'claim node to the nearest identity-check node — is this evidence '
        'connected to a verified identity at all? Null when no identity-'
        'check node exists or none is reachable.',
  ),
  FeatureSpec(
    name: 'graph.orphanEvidenceCount',
    group: 'graph',
    description: 'Evidence nodes (excluding the claim node itself) touched '
        'by no edge at all.',
  ),
  FeatureSpec(
    name: 'graph.evidenceKindDiversity',
    group: 'graph',
    description: 'Shannon entropy (base 2) of the node-type distribution '
        'among non-claim nodes — how varied the evidence kinds are. Null '
        'when there are no non-claim nodes.',
  ),
  FeatureSpec(
    name: 'graph.reviewerCommentNodeCount',
    group: 'graph',
    description: 'Count of reviewer-comment nodes.',
  ),
  FeatureSpec(
    name: 'graph.ruleBasisEdgeShare',
    group: 'graph',
    description: 'Share of all edges whose basis is a deterministic rule or '
        'mechanical derivation (telemetryRule / identityCheckResult / '
        'systemDerivation). Null when there are no edges.',
  ),
  FeatureSpec(
    name: 'graph.modelBasisEdgeShare',
    group: 'graph',
    description: 'Share of all edges whose basis is a bounded model judgment '
        '(llmDimensionJudgment / llmContradictionCheck). Null when there are '
        'no edges.',
  ),
  FeatureSpec(
    name: 'graph.humanBasisEdgeShare',
    group: 'graph',
    description: 'Share of all edges authored directly by a reviewer. Null '
        'when there are no edges.',
  ),
  FeatureSpec(
    name: 'graph.density',
    group: 'graph',
    description: 'Edge count over the maximum possible directed edges '
        '(n*(n-1)) — a structural description, not a per-node ranking. Null '
        'with fewer than two nodes.',
  ),
  FeatureSpec(
    name: 'graph.largestComponentShare',
    group: 'graph',
    description: "The largest connected component's share of all nodes "
        '(edges treated as undirected). Null when there are no nodes.',
  ),
];
