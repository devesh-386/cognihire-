import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/graph/evidence_graph.dart';
import 'package:cognihire/core/graph/graph_from_audit.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/features/graph/graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

const _builder = EvidenceGraphBuilder();
final _at = DateTime.utc(2026, 7, 27, 9);

GraphEdge _edge(String id, String from, String to, EdgeType type) =>
    _builder.edge(
      id: id,
      from: from,
      to: to,
      type: type,
      rationale: 'test edge',
      basis: EdgeBasis.systemDerivation,
      at: _at,
      createdBy: 'test',
    );

void main() {
  group('layout', () {
    test('places the claim at layer 0', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
        ],
        edges: const [],
      );

      expect(layoutGraph(graph).of('n-claim-c1')!.layer, 0);
      expect(layoutGraph(graph).layerCount, 1);
    });

    test('evidence pointing at the claim sits one layer below', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(id: 'a', claimId: 'c1', text: 'ans', at: _at),
        ],
        edges: [_edge('e', 'a', 'n-claim-c1', EdgeType.supports)],
      );

      final layout = layoutGraph(graph);
      expect(layout.of('n-claim-c1')!.layer, 0);
      expect(layout.of('a')!.layer, 1);
      expect(layout.layerCount, 2);
    });

    test('supports chains further out to deeper layers', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(id: 'a', claimId: 'c1', text: 'ans', at: _at),
          _builder.identityNode(
            id: 'i',
            claimId: 'c1',
            result: Verified(similarity: 96, at: _at),
          ),
        ],
        edges: [
          _edge('e1', 'a', 'n-claim-c1', EdgeType.supports),
          _edge('e2', 'i', 'a', EdgeType.supports),
        ],
      );

      final layout = layoutGraph(graph);
      expect(layout.of('a')!.layer, 1);
      expect(layout.of('i')!.layer, 2);
      expect(layout.layerCount, 3);
    });

    test('nodes sharing a layer get distinct evenly-spread slots', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(
            id: 'a',
            claimId: 'c1',
            text: 'first',
            at: _at.add(const Duration(minutes: 1)),
          ),
          _builder.answerNode(
            id: 'b',
            claimId: 'c1',
            text: 'second',
            at: _at.add(const Duration(minutes: 2)),
          ),
        ],
        edges: [
          _edge('e1', 'a', 'n-claim-c1', EdgeType.supports),
          _edge('e2', 'b', 'n-claim-c1', EdgeType.supports),
        ],
      );

      final layout = layoutGraph(graph);
      expect(layout.of('a')!.slot, 0);
      expect(layout.of('b')!.slot, 1);
      expect(layout.of('a')!.slotsInLayer, 2);
      expect(layout.of('a')!.fractionalX, 0.25);
      expect(layout.of('b')!.fractionalX, 0.75);
    });

    test('ordering within a layer follows creation time, not insertion', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          // Deliberately inserted newest-first.
          _builder.answerNode(
            id: 'later',
            claimId: 'c1',
            text: 'b',
            at: _at.add(const Duration(minutes: 9)),
          ),
          _builder.answerNode(
            id: 'earlier',
            claimId: 'c1',
            text: 'a',
            at: _at.add(const Duration(minutes: 2)),
          ),
        ],
        edges: [
          _edge('e1', 'later', 'n-claim-c1', EdgeType.supports),
          _edge('e2', 'earlier', 'n-claim-c1', EdgeType.supports),
        ],
      );

      final layout = layoutGraph(graph);
      expect(layout.of('earlier')!.slot, 0);
      expect(layout.of('later')!.slot, 1);
    });

    test('is deterministic — same graph in, same layout out', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(id: 'a', claimId: 'c1', text: 'x', at: _at),
          _builder.answerNode(id: 'b', claimId: 'c1', text: 'y', at: _at),
        ],
        edges: [
          _edge('e1', 'a', 'n-claim-c1', EdgeType.supports),
          _edge('e2', 'b', 'n-claim-c1', EdgeType.supports),
        ],
      );

      final first = layoutGraph(graph);
      final second = layoutGraph(graph);

      for (final id in ['n-claim-c1', 'a', 'b']) {
        expect(first.of(id)!.layer, second.of(id)!.layer);
        expect(first.of(id)!.slot, second.of(id)!.slot);
      }
    });

    test('an unreachable node still gets a position, in a trailing layer', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(id: 'orphan', claimId: 'c1', text: 'x', at: _at),
        ],
        edges: const [],
      );

      final layout = layoutGraph(graph);
      expect(layout.of('orphan'), isNotNull);
      expect(layout.of('orphan')!.layer, 1);
    });

    test('an empty graph lays out without throwing', () {
      const graph = EvidenceGraph.new;
      final empty = graph(claimId: 'c1', nodes: const [], edges: const []);

      expect(layoutGraph(empty).positions, isEmpty);
      expect(layoutGraph(empty).layerCount, 0);
    });

    test('a graph with no claim node still positions every node', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.answerNode(id: 'a', claimId: 'c1', text: 'x', at: _at),
          _builder.answerNode(id: 'b', claimId: 'c1', text: 'y', at: _at),
        ],
        edges: const [],
      );

      final layout = layoutGraph(graph);
      expect(layout.positions, hasLength(2));
    });
  });

  group('derived from a real ClaimAudit', () {
    ClaimAudit audit() {
      final start = DateTime.utc(2026, 7, 27, 9);
      return const ClaimAuditBuilder().build(
        claims: const [
          Claim(id: 'c1', text: 'Built a cache', source: 'Resume', skill: 'Redis'),
          Claim(id: 'c2', text: 'Led a migration', source: 'Cover letter'),
        ],
        evidenceByClaimId: {
          'c1': [
            ClaimEvidence(
              observation: 'Described consistent hashing when asked.',
              kind: EvidenceKind.probeResponse,
              at: start.add(const Duration(minutes: 6)),
            ),
            ClaimEvidence(
              observation: '340 characters added in one step.',
              kind: EvidenceKind.processSignal,
              at: start.add(const Duration(minutes: 8)),
            ),
          ],
        },
        reviewerAssessments: const {'c1': ClaimStatus.substantiated},
        identityAttempts: [
          Verified(similarity: 96.4, at: start.add(const Duration(minutes: 1))),
          Mismatch(
            similarity: 41.2,
            strike: 1,
            strikesAllowed: 3,
            at: start.add(const Duration(minutes: 12)),
          ),
          Unchecked(
            reason: UncheckedReason.noFaceInFrame,
            at: start.add(const Duration(minutes: 15)),
          ),
        ],
        sessionStart: start,
        sessionEnd: start.add(const Duration(minutes: 30)),
      );
    }

    test('produces one graph per claim', () {
      expect(graphsFromAudit(audit()), hasLength(2));
    });

    test('every derived graph is well formed', () {
      for (final graph in graphsFromAudit(audit())) {
        expect(graph.danglingEdges, isEmpty);
        expect(graph.orphanNodes, isEmpty);
        expect(graph.isWellFormed, isTrue);
      }
    });

    test('a verified attempt supports, a mismatch contradicts', () {
      final graph = graphForClaim(audit(), 'c1')!;
      final claimId = graph.claimNode!.id;

      expect(graph.supporting(claimId), hasLength(1));
      expect(graph.contradicting(claimId), hasLength(1));
      expect(
        graph.contradicting(claimId).single.node.payload['outcome'],
        'Mismatch',
      );
    });

    test('an unchecked attempt is present but is NOT evidentiary', () {
      final graph = graphForClaim(audit(), 'c1')!;

      final unchecked = graph.nodes.firstWhere(
        (n) =>
            n.type == NodeType.identityCheck &&
            n.payload['outcome'] == 'Not checked' &&
            n.payload['reason'] == 'No face detected in frame',
      );

      final itsEdges = graph.edgesOutOf(unchecked.id);
      expect(itsEdges, hasLength(1));
      expect(itsEdges.single.type, EdgeType.derivedFrom);
      expect(itsEdges.single.isEvidentiary, isFalse);
      expect(itsEdges.single.rationale, contains('not evidence'));
    });

    test('a claim with no recorded evidence still yields a usable graph', () {
      final graph = graphForClaim(audit(), 'c2')!;

      expect(graph.claimNode, isNotNull);
      // Identity attempts are session-wide, so they attach here too.
      expect(graph.nodesOfType(NodeType.identityCheck), hasLength(3));
      expect(graph.nodesOfType(NodeType.interviewAnswer), isEmpty);
      expect(graph.isWellFormed, isTrue);
    });

    test('derived graphs lay out cleanly', () {
      for (final graph in graphsFromAudit(audit())) {
        final layout = layoutGraph(graph);
        expect(layout.positions, hasLength(graph.nodes.length));
        expect(layout.of(graph.claimNode!.id)!.layer, 0);
      }
    });

    test('no derived edge claims a model judgment it did not make', () {
      for (final graph in graphsFromAudit(audit())) {
        for (final edge in graph.edges) {
          expect(
            edge.basis,
            anyOf(EdgeBasis.systemDerivation, EdgeBasis.identityCheckResult),
            reason: 'the audit alone cannot support a model-judgment basis',
          );
        }
      }
    });
  });
}
