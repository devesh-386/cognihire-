import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/features/feature_vector.dart';
import 'package:cognihire/core/graph/evidence_graph.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 8, 2, 9, 0, 0);
  const empty = FeatureAssembler();
  const builder = EvidenceGraphBuilder();

  const claim = Claim(id: 'c1', text: 'Built a thing', source: 'resume');

  FeatureVector assembleWith(EvidenceGraph? graph) => empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
        graph: graph,
      );

  group('graph feature specs are declared', () {
    test('every graph.* feature name is registered', () {
      for (final name in [
        'graph.nodeCount',
        'graph.edgeCount',
        'graph.edgesPerNode',
        'graph.supportsEdgeCount',
        'graph.contradictsEdgeCount',
        'graph.provisionalEdgeShare',
        'graph.claimNodeDegree',
        'graph.provenanceDistanceToIdentityCheck',
        'graph.orphanEvidenceCount',
        'graph.evidenceKindDiversity',
        'graph.reviewerCommentNodeCount',
        'graph.ruleBasisEdgeShare',
        'graph.modelBasisEdgeShare',
        'graph.humanBasisEdgeShare',
        'graph.density',
        'graph.largestComponentShare',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('when no graph is supplied, every graph.* feature is null', () {
    test('the whole group is null, not zero — no graph means no measurement',
        () {
      final v = assembleWith(null);
      for (final spec in FeatureRegistry.instance.specs) {
        if (spec.group != 'graph') continue;
        expect(v.value(spec.name), isNull, reason: spec.name);
      }
    });
  });

  group('an empty graph (just the claim node, nothing else)', () {
    late EvidenceGraph graph;
    setUp(() {
      graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [builder.claimNode(claim, at: t0)],
        edges: const [],
      );
    });

    test('counts are zero/one as appropriate — not null, since a graph was '
        'actually supplied', () {
      final v = assembleWith(graph);
      expect(v.value('graph.nodeCount'), 1.0);
      expect(v.value('graph.edgeCount'), 0.0);
      expect(v.value('graph.supportsEdgeCount'), 0.0);
      expect(v.value('graph.contradictsEdgeCount'), 0.0);
      expect(v.value('graph.orphanEvidenceCount'), 0.0);
      expect(v.value('graph.reviewerCommentNodeCount'), 0.0);
    });

    test('edgesPerNode, density, provisionalEdgeShare, evidenceKindDiversity, '
        'basis shares, and provenance distance are null with no edges or no '
        'evidence nodes to compute from', () {
      final v = assembleWith(graph);
      expect(v.value('graph.density'), isNull); // needs >= 2 nodes
      expect(v.value('graph.provisionalEdgeShare'), isNull); // no evidentiary edges
      expect(v.value('graph.evidenceKindDiversity'), isNull); // no non-claim nodes
      expect(v.value('graph.ruleBasisEdgeShare'), isNull); // no edges at all
      expect(v.value('graph.provenanceDistanceToIdentityCheck'), isNull);
    });

    test('claimNodeDegree and largestComponentShare are computable from a '
        'single node', () {
      final v = assembleWith(graph);
      expect(v.value('graph.claimNodeDegree'), 0.0);
      expect(v.value('graph.largestComponentShare'), 1.0);
    });
  });

  group('a richer graph', () {
    late EvidenceGraph graph;

    setUp(() {
      final claimNode = builder.claimNode(claim, at: t0);
      final answer = builder.answerNode(
          id: 'n-ans', claimId: 'c1', text: 'I did it with React', at: t0);
      final idCheck = builder.identityNode(
        id: 'n-id',
        claimId: 'c1',
        result: Verified(similarity: 90, at: t0),
      );
      final comment = builder.reviewerCommentNode(
        id: 'n-cmt',
        claimId: 'c1',
        reviewerName: 'Alice',
        text: 'Looks solid',
        at: t0,
      );
      // An orphan: telemetry node with no edge touching it.
      final orphanTelemetry = builder.telemetryNode(
        id: 'n-tel',
        claimId: 'c1',
        summary: 'Answer produced: began after 2s.',
        at: t0,
      );

      graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [claimNode, answer, idCheck, comment, orphanTelemetry],
        edges: [
          builder.edge(
            id: 'e1',
            from: answer.id,
            to: claimNode.id,
            type: EdgeType.supports,
            rationale: 'Answer describes doing the work',
            basis: EdgeBasis.llmDimensionJudgment,
            at: t0,
            createdBy: 'judge-v1',
          ),
          builder.edge(
            id: 'e2',
            from: idCheck.id,
            to: answer.id,
            type: EdgeType.derivedFrom,
            rationale: 'Identity check ran during this answer',
            basis: EdgeBasis.systemDerivation,
            at: t0,
            createdBy: 'system',
          ),
          builder.edge(
            id: 'e3',
            from: comment.id,
            to: claimNode.id,
            type: EdgeType.annotates,
            rationale: 'Reviewer note',
            basis: EdgeBasis.reviewerAuthored,
            at: t0,
            createdBy: 'Alice',
          ),
        ],
      );
    });

    test('node and edge counts', () {
      final v = assembleWith(graph);
      expect(v.value('graph.nodeCount'), 5.0);
      expect(v.value('graph.edgeCount'), 3.0);
      expect(v.value('graph.edgesPerNode'), closeTo(3 / 5, 1e-9));
      expect(v.value('graph.supportsEdgeCount'), 1.0);
      expect(v.value('graph.contradictsEdgeCount'), 0.0);
    });

    test('claim node degree counts edges touching it in either direction', () {
      final v = assembleWith(graph);
      // e1 (answer->claim) and e3 (comment->claim) touch the claim node.
      expect(v.value('graph.claimNodeDegree'), 2.0);
    });

    test('provenance distance is the shortest hop count from the claim node '
        'to an identityCheck node, treating edges as undirected', () {
      final v = assembleWith(graph);
      // claim -e1- answer -e2- idCheck : 2 hops.
      expect(v.value('graph.provenanceDistanceToIdentityCheck'), 2.0);
    });

    test('orphanEvidenceCount excludes the claim node itself from the count',
        () {
      final v = assembleWith(graph);
      // Only n-tel is untouched by any edge.
      expect(v.value('graph.orphanEvidenceCount'), 1.0);
    });

    test('reviewerCommentNodeCount', () {
      expect(assembleWith(graph).value('graph.reviewerCommentNodeCount'), 1.0);
    });

    test('basis shares sum to 1.0 and bucket correctly', () {
      final v = assembleWith(graph);
      // e1: llmDimensionJudgment -> model. e2: systemDerivation -> rule.
      // e3: reviewerAuthored -> human.
      expect(v.value('graph.ruleBasisEdgeShare'), closeTo(1 / 3, 1e-9));
      expect(v.value('graph.modelBasisEdgeShare'), closeTo(1 / 3, 1e-9));
      expect(v.value('graph.humanBasisEdgeShare'), closeTo(1 / 3, 1e-9));
    });

    test('provisionalEdgeShare is model-produced share of evidentiary edges '
        'only — derivedFrom/annotates are not evidentiary and are excluded',
        () {
      final v = assembleWith(graph);
      // Evidentiary edges: only e1 (supports). e1's basis is model-produced.
      expect(v.value('graph.provisionalEdgeShare'), closeTo(1.0, 1e-9));
    });

    test('evidenceKindDiversity is positive when non-claim nodes span more '
        'than one type', () {
      final v = assembleWith(graph);
      // 4 non-claim nodes across 4 distinct types -> maximum diversity for n=4.
      expect(v.value('graph.evidenceKindDiversity'), greaterThan(0));
    });

    test('density is edgeCount / (n*(n-1)) for n >= 2 nodes', () {
      final v = assembleWith(graph);
      expect(v.value('graph.density'), closeTo(3 / (5 * 4), 1e-9));
    });

    test('largestComponentShare counts the biggest connected cluster', () {
      final v = assembleWith(graph);
      // Connected: {claim, answer, idCheck, comment} = 4 nodes via e1,e2,e3.
      // Isolated: {n-tel} = 1 node. Largest share = 4/5.
      expect(v.value('graph.largestComponentShare'), closeTo(4 / 5, 1e-9));
    });
  });

  group('full coverage check', () {
    test('every emitted value is registered and non-nullable specs are never '
        'null, with and without a graph', () {
      for (final graph in [
        null,
        EvidenceGraph(
          claimId: 'c1',
          nodes: [builder.claimNode(claim, at: t0)],
          edges: const [],
        ),
      ]) {
        final v = assembleWith(graph);
        for (final entry in v.values.entries) {
          final spec = FeatureRegistry.instance.spec(entry.key);
          if (!spec.nullable) {
            expect(entry.value, isNotNull,
                reason: '${entry.key} must not be null (graph=$graph)');
          }
        }
      }
    });
  });
}
