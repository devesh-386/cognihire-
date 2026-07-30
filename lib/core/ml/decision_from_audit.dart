import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import '../graph/evidence_graph.dart';
import '../verification/verification_result.dart';
import 'decision_guards.dart';
import 'explanation_templater.dart';
import 'sufficiency_model.dart';

/// Maps a real session's audit onto the feature map the sufficiency model
/// understands, so the mechanism can be demonstrated on real observations.
///
/// ## Read this before showing the result to anyone
///
/// The features here are genuinely measured from the session. The **model** they
/// are fed to is not: it has only ever been fit on synthetic data. So the output
/// is "what this mechanism would say", never "what is true about this person",
/// and [buildDecisionFromAudit] therefore always constructs its
/// [DecisionUnderReview] with `presentedAsAboutRealPerson: false`. That is not a
/// default a caller can flip — there is no parameter for it — because the only
/// thing that could honestly flip it is a model validated on real data, which
/// does not exist yet.
///
/// ## Absent means absent
///
/// A feature the session did not measure is **omitted**, never filled with a
/// zero. The model treats an omitted feature as its midpoint (no information),
/// and [DecisionGuards] reports the case where nothing at all was measurable.
/// Substituting 0 for "we didn't look" would turn a gap in observation into a
/// confident negative observation — the exact error the whole feature layer is
/// built to avoid.
class AuditDecisionInputs {
  const AuditDecisionInputs({
    required this.features,
    required this.unmeasured,
  });

  /// Raw feature values the session actually produced.
  final Map<String, double> features;

  /// Model features this session could not measure, kept so a UI can say what
  /// was missing rather than leaving the reader to assume full coverage.
  final List<String> unmeasured;
}

/// Extract the model's features from [audit] and [graphs] (one graph per claim).
///
/// Only the features this session can honestly answer are returned. The typing
/// and editing features are absent by design: they live in per-claim process
/// telemetry that the audit summarises as prose rather than carrying as numbers,
/// so deriving them here would mean re-parsing a sentence — a guess dressed as a
/// measurement.
AuditDecisionInputs auditDecisionInputs(
  ClaimAudit audit, {
  required List<EvidenceGraph> graphs,
  required SufficiencyModel model,
}) {
  final features = <String, double>{};

  // --- graph: how much of the evidence supports vs contradicts ---
  var supports = 0;
  var contradicts = 0;
  for (final graph in graphs) {
    for (final edge in graph.edges) {
      if (edge.type == EdgeType.supports) supports++;
      if (edge.type == EdgeType.contradicts) contradicts++;
    }
  }
  if (graphs.isNotEmpty) {
    features['graph.supportsEdgeCount'] = supports.toDouble();
    features['graph.contradictsEdgeCount'] = contradicts.toDouble();
  }

  // --- identity: verified share of what was actually measurable ---
  final attempts = audit.identityAttempts;
  final measured = audit.identityChecksPerformed;
  if (measured > 0) {
    features['identity.verifiedShareOfMeasured'] =
        audit.identityChecksVerified / measured;
  }
  if (attempts.isNotEmpty) {
    features['identity.maxConsecutiveMismatches'] =
        _maxConsecutiveMismatches(attempts).toDouble();
  }

  // --- session: how much of what was opened was actually answered ---
  final examinable = audit.findings.length;
  if (examinable > 0) {
    final answered = audit.findings
        .where((f) => f.status != ClaimStatus.notExamined)
        .length;
    features['session.answeredToOpenedRatio'] = answered / examinable;
  }

  final unmeasured = [
    for (final name in model.featureNames)
      if (!features.containsKey(name)) name,
  ];

  return AuditDecisionInputs(features: features, unmeasured: unmeasured);
}

/// The longest unbroken run of identity mismatches, in attempt order.
///
/// A run is what matters rather than a total: one failed frame is a camera
/// blinking, while eight in a row is a different person or a person who left.
int _maxConsecutiveMismatches(List<VerificationResult> attempts) {
  var longest = 0;
  var current = 0;
  for (final a in attempts) {
    if (a is Mismatch) {
      current++;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return longest;
}

/// Assemble a reviewable decision from a real session.
///
/// Always `presentedAsAboutRealPerson: false` and always
/// `committedLabelShown: false` — see the class doc. The guards still run on the
/// result, so an empty session is refused rather than rendered as a confident
/// number derived from nothing.
DecisionUnderReview buildDecisionFromAudit(
  ClaimAudit audit, {
  required List<EvidenceGraph> graphs,
  required SufficiencyModel model,
  ExplanationTemplater templater = const ExplanationTemplater(),
}) {
  final inputs = auditDecisionInputs(audit, graphs: graphs, model: model);
  return DecisionUnderReview(
    model: model,
    rawFeatures: inputs.features,
    explanation:
        templater.render(model: model, rawFeatures: inputs.features),
    presentedAsAboutRealPerson: false,
    committedLabelShown: false,
  );
}
