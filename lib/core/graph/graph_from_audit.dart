/// Derives an [EvidenceGraph] from a [ClaimAudit] that already exists.
///
/// Fully deterministic — no model call, no judgment introduced here. Every
/// edge this produces has basis [EdgeBasis.systemDerivation] or
/// [EdgeBasis.identityCheckResult], because that is all the audit actually
/// supports: it records *what happened*, and the relationships derivable from
/// it are the mechanical ones.
///
/// The richer edges — `llmDimensionJudgment`, `llmContradictionCheck` — come
/// from the Adaptive Interview Engine's bounded calls once those exist. This
/// builder deliberately does not invent them from the audit's status field,
/// because the audit's status is already a *conclusion*; re-deriving edges
/// from it and presenting them as independent evidence would be circular.
///
/// So what a reviewer sees today is honest and slightly sparse: the evidence
/// that was recorded, attached to the claim it was recorded against, with each
/// edge saying plainly where it came from.
library;

import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import '../verification/verification_result.dart';
import 'evidence_graph.dart';

const _builder = EvidenceGraphBuilder();

/// Builds one graph per claim in the audit.
///
/// Identity attempts are attached to every claim's graph, because the audit
/// does not record which answer was being written during which check — the
/// session-wide attempt log is genuinely all the information there is. Each
/// identity edge's rationale says so, rather than implying a precision the
/// data does not have.
List<EvidenceGraph> graphsFromAudit(ClaimAudit audit) =>
    audit.findings.map((f) => _graphForFinding(f, audit)).toList();

/// Convenience for the single-claim case.
EvidenceGraph? graphForClaim(ClaimAudit audit, String claimId) {
  for (final finding in audit.findings) {
    if (finding.claim.id == claimId) return _graphForFinding(finding, audit);
  }
  return null;
}

EvidenceGraph _graphForFinding(ClaimFinding finding, ClaimAudit audit) {
  final claim = finding.claim;
  final nodes = <GraphNode>[];
  final edges = <GraphEdge>[];

  final claimNode = _builder.claimNode(claim, at: audit.sessionStart);
  nodes.add(claimNode);

  // --- Recorded evidence -----------------------------------------------
  for (var i = 0; i < finding.evidence.length; i++) {
    final evidence = finding.evidence[i];
    final nodeId = 'n-${claim.id}-ev$i';

    final node = switch (evidence.kind) {
      EvidenceKind.probeResponse => _builder.answerNode(
          id: nodeId,
          claimId: claim.id,
          text: evidence.observation,
          at: evidence.at,
        ),
      EvidenceKind.processSignal => _builder.telemetryNode(
          id: nodeId,
          claimId: claim.id,
          summary: evidence.observation,
          at: evidence.at,
        ),
      EvidenceKind.identityCheck => _builder.identityNode(
          id: nodeId,
          claimId: claim.id,
          // An identity-kind ClaimEvidence carries prose, not a result
          // object, so it is recorded as an unmeasured note rather than
          // reconstructing a similarity that was never stored.
          result: Unchecked(
            reason: UncheckedReason.noEnrolledProfile,
            at: evidence.at,
          ),
        ),
    };
    nodes.add(node);

    edges.add(_builder.edge(
      id: 'e-${claim.id}-ev$i',
      from: nodeId,
      to: claimNode.id,
      type: EdgeType.derivedFrom,
      rationale: 'Recorded against this claim during the session '
          '(${_evidenceKindLabel(evidence.kind)}). Whether it supports or '
          'undercuts the claim is the reviewer\'s reading — the system does '
          'not assert one here.',
      basis: EdgeBasis.systemDerivation,
      at: evidence.at,
      createdBy: 'system',
    ));
  }

  // --- Identity attempts -------------------------------------------------
  for (var i = 0; i < audit.identityAttempts.length; i++) {
    final attempt = audit.identityAttempts[i];
    final nodeId = 'n-${claim.id}-id$i';

    nodes.add(_builder.identityNode(
      id: nodeId,
      claimId: claim.id,
      result: attempt,
    ));

    // The variant determines the relationship, and Unchecked deliberately
    // gets provenance rather than an evidentiary edge: an attempt that could
    // not be performed neither supports nor contradicts anything, and saying
    // otherwise in either direction would be inventing a measurement.
    final (type, rationale) = switch (attempt) {
      Verified(:final similarity) => (
          EdgeType.supports,
          'Identity matched the enrolled reference '
              '(${similarity.toStringAsFixed(1)}) during this session. The '
              'audit does not record which specific answer was being written '
              'at this moment.',
        ),
      Mismatch(:final similarity, :final strike, :final strikesAllowed) => (
          EdgeType.contradicts,
          'Identity did not match the enrolled reference '
              '(${similarity.toStringAsFixed(1)}, strike $strike of '
              '$strikesAllowed) during this session.',
        ),
      Unchecked(:final reason) => (
          EdgeType.derivedFrom,
          'Attempt could not be performed (${reason.message}). Recorded so '
              'the gap is visible; it is not evidence for or against the '
              'claim.',
        ),
    };

    edges.add(_builder.edge(
      id: 'e-${claim.id}-id$i',
      from: nodeId,
      to: claimNode.id,
      type: type,
      rationale: rationale,
      basis: EdgeBasis.identityCheckResult,
      at: attempt.at,
      createdBy: 'system',
    ));
  }

  return EvidenceGraph(claimId: claim.id, nodes: nodes, edges: edges);
}

String _evidenceKindLabel(EvidenceKind kind) => switch (kind) {
      EvidenceKind.probeResponse => 'probe response',
      EvidenceKind.processSignal => 'process signal',
      EvidenceKind.identityCheck => 'identity check',
    };
