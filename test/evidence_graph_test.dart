import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/graph/evidence_graph.dart';
import 'package:cognihire/core/graph/graph_codec.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

const _builder = EvidenceGraphBuilder();
final _at = DateTime.utc(2026, 7, 27, 9);

/// The worked example from the design doc: a distributed-cache claim with
/// supporting answers, an identity check, telemetry that triggered a
/// follow-up, and a reviewer note.
EvidenceGraph _graph() {
  const claim = Claim(
    id: 'c1',
    text: 'I designed a distributed cache',
    source: 'Resume, page 1',
    skill: 'Redis',
  );

  final n1 = _builder.claimNode(claim, at: _at);
  final n2 = _builder.answerNode(
    id: 'n2',
    claimId: 'c1',
    text: 'Used Redis Cluster with consistent hashing for shard placement.',
    at: _at.add(const Duration(minutes: 6)),
  );
  final n3 = _builder.codeEvidenceNode(
    id: 'n3',
    claimId: 'c1',
    quotedSpan: 'void invalidate(String key) { ... }',
    charStart: 120,
    charEnd: 155,
    at: _at.add(const Duration(minutes: 8)),
  );
  final n4 = _builder.telemetryNode(
    id: 'n4',
    claimId: 'c1',
    summary: '340 characters added in one step after a 35s pause',
    at: _at.add(const Duration(minutes: 8)),
  );
  final n5 = _builder.followUpNode(
    id: 'n5',
    claimId: 'c1',
    question: 'Walk me through the part you just added.',
    observation: '340 characters were added at once after a pause of 35s.',
    wasAnswered: true,
    at: _at.add(const Duration(minutes: 9)),
  );
  final n7 = _builder.identityNode(
    id: 'n7',
    claimId: 'c1',
    result: Verified(similarity: 96.4, at: _at.add(const Duration(minutes: 6))),
  );
  final n9 = _builder.reviewerCommentNode(
    id: 'n9',
    claimId: 'c1',
    reviewerName: 'D. Patel',
    text: 'Rebalancing explanation was genuinely specific.',
    at: _at.add(const Duration(minutes: 40)),
  );

  return EvidenceGraph(
    claimId: 'c1',
    nodes: [n1, n2, n3, n4, n5, n7, n9],
    edges: [
      _builder.edge(
        id: 'e1',
        from: 'n2',
        to: n1.id,
        type: EdgeType.supports,
        rationale: 'Names Redis Cluster and consistent hashing, addressing the '
            'Technology dimension.',
        basis: EdgeBasis.llmDimensionJudgment,
        at: _at,
        createdBy: 'model-v1',
      ),
      _builder.edge(
        id: 'e2',
        from: 'n7',
        to: 'n2',
        type: EdgeType.supports,
        rationale: 'Identity verified during the window this answer was '
            'written.',
        basis: EdgeBasis.identityCheckResult,
        at: _at,
        createdBy: 'system',
      ),
      _builder.edge(
        id: 'e3',
        from: 'n3',
        to: 'n4',
        type: EdgeType.derivedFrom,
        rationale: 'This span is the content the telemetry measurement '
            'describes.',
        basis: EdgeBasis.systemDerivation,
        at: _at,
        createdBy: 'system',
      ),
      _builder.edge(
        id: 'e4',
        from: 'n5',
        to: 'n3',
        type: EdgeType.probes,
        rationale: 'pauseThenBulk trigger fired on this span.',
        basis: EdgeBasis.telemetryRule,
        at: _at,
        createdBy: 'system',
      ),
      _builder.edge(
        id: 'e5',
        from: 'n9',
        to: 'n2',
        type: EdgeType.annotates,
        rationale: 'Reviewer note attached to this answer.',
        basis: EdgeBasis.reviewerAuthored,
        at: _at,
        createdBy: 'D. Patel',
      ),
    ],
  );
}

void main() {
  group('graph structure', () {
    test('exposes the claim node', () {
      expect(_graph().claimNode!.type, NodeType.resumeClaim);
      expect(_graph().claimNode!.label, 'I designed a distributed cache');
    });

    test('is well formed with no dangling edges or orphans', () {
      final graph = _graph();
      expect(graph.danglingEdges, isEmpty);
      expect(graph.orphanNodes, isEmpty);
      expect(graph.isWellFormed, isTrue);
    });

    test('reports a dangling edge rather than ignoring it', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [_builder.claimNode(
          const Claim(id: 'c1', text: 'x', source: 'Resume'),
          at: _at,
        )],
        edges: [
          _builder.edge(
            id: 'e1',
            from: 'nowhere',
            to: 'n-claim-c1',
            type: EdgeType.supports,
            rationale: 'points at a node that does not exist',
            basis: EdgeBasis.systemDerivation,
            at: _at,
            createdBy: 'system',
          ),
        ],
      );

      expect(graph.danglingEdges, hasLength(1));
      expect(graph.isWellFormed, isFalse);
    });

    test('reports an orphan node rather than hiding it', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(id: 'c1', text: 'x', source: 'Resume'),
            at: _at,
          ),
          _builder.answerNode(
            id: 'lonely',
            claimId: 'c1',
            text: 'unconnected',
            at: _at,
          ),
        ],
        edges: const [],
      );

      expect(graph.orphanNodes.map((n) => n.id), ['n-claim-c1', 'lonely']);
    });

    test('edgesTouching finds edges in both directions', () {
      expect(_graph().edgesTouching('n2').map((e) => e.id),
          containsAll(['e1', 'e2', 'e5']));
    });
  });

  group('traversal returns evidence, never a count', () {
    test('supporting returns the nodes and their rationale in full', () {
      final graph = _graph();
      final support = graph.supporting(graph.claimNode!.id);

      expect(support, hasLength(1));
      expect(support.single.node.id, 'n2');
      expect(support.single.edge.rationale, contains('consistent hashing'));
    });

    test('contradicting returns empty when nothing argues against', () {
      final graph = _graph();
      expect(graph.contradicting(graph.claimNode!.id), isEmpty);
    });

    test('a contradicting identity check is returned with its reason', () {
      final base = _graph();
      final mismatch = _builder.identityNode(
        id: 'n8',
        claimId: 'c1',
        result: Mismatch(
          similarity: 41.2,
          strike: 2,
          strikesAllowed: 3,
          at: _at.add(const Duration(minutes: 20)),
        ),
      );

      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [...base.nodes, mismatch],
        edges: [
          ...base.edges,
          _builder.edge(
            id: 'e6',
            from: 'n8',
            to: 'n2',
            type: EdgeType.contradicts,
            rationale: 'Identity did not match during the window this answer '
                'was written.',
            basis: EdgeBasis.identityCheckResult,
            at: _at,
            createdBy: 'system',
          ),
        ],
      );

      final against = graph.contradicting('n2');
      expect(against, hasLength(1));
      expect(against.single.node.payload['outcome'], 'Mismatch');
      expect(against.single.edge.basis, EdgeBasis.identityCheckResult);
    });

    test('partiallySupports can be separated from full support', () {
      final base = _graph();
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: base.nodes,
        edges: [
          ...base.edges,
          _builder.edge(
            id: 'e7',
            from: 'n3',
            to: base.claimNode!.id,
            type: EdgeType.partiallySupports,
            rationale: 'Touches the Architecture dimension but stays generic.',
            basis: EdgeBasis.llmDimensionJudgment,
            at: _at,
            createdBy: 'model-v1',
          ),
        ],
      );

      final claimId = graph.claimNode!.id;
      expect(graph.supporting(claimId), hasLength(2));
      expect(graph.supporting(claimId, includePartial: false), hasLength(1));
    });
  });

  group('no hidden weights', () {
    test('an edge carries no numeric weight field once serialised', () {
      final json = edgeToJson(_graph().edges.first);

      expect(json.containsKey('weight'), isFalse);
      expect(json.containsKey('strength'), isFalse);
      expect(json.containsKey('score'), isFalse);
      expect(json.containsKey('confidence'), isFalse);
      // Only the documented, explainable fields.
      expect(
        json.keys.toSet(),
        {'id', 'from', 'to', 'type', 'rationale', 'basis', 'createdAt',
            'createdBy'},
      );
    });

    test('every edge type is evidentiary or explicitly not, with no scale', () {
      expect(
        EdgeType.values.where((t) => t != EdgeType.derivedFrom).length,
        6,
        reason: 'edge types are a small closed set a legend can enumerate',
      );
    });
  });

  group('an edge must say why it exists', () {
    test('building one with an empty rationale throws', () {
      expect(
        () => _builder.edge(
          id: 'e',
          from: 'a',
          to: 'b',
          type: EdgeType.supports,
          rationale: '',
          basis: EdgeBasis.systemDerivation,
          at: _at,
          createdBy: 'system',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a whitespace-only rationale throws too', () {
      expect(
        () => _builder.edge(
          id: 'e',
          from: 'a',
          to: 'b',
          type: EdgeType.supports,
          rationale: '   ',
          basis: EdgeBasis.systemDerivation,
          at: _at,
          createdBy: 'system',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('decoding an edge with an empty rationale throws', () {
      final json = edgeToJson(_graph().edges.first);
      json['rationale'] = '';

      expect(() => edgeFromJson(json), throwsA(isA<FormatException>()));
    });

    test('decoding an edge with no rationale field at all throws', () {
      final json = edgeToJson(_graph().edges.first);
      json.remove('rationale');

      expect(() => edgeFromJson(json), throwsA(isA<FormatException>()));
    });
  });

  group('identity nodes never fabricate a number', () {
    test('an Unchecked node carries a reason and no similarity', () {
      final node = _builder.identityNode(
        id: 'n',
        claimId: 'c1',
        result: Unchecked(reason: UncheckedReason.noFaceInFrame, at: _at),
      );

      expect(node.payload.containsKey('similarity'), isFalse);
      expect(node.payload['reason'], 'No face detected in frame');
      expect(node.label, 'Not checked');
    });

    test('a Verified node keeps its measured similarity', () {
      final node = _builder.identityNode(
        id: 'n',
        claimId: 'c1',
        result: Verified(similarity: 96.4, at: _at),
      );

      expect(node.payload['similarity'], 96.4);
    });

    test('a Mismatch node keeps its strike count', () {
      final node = _builder.identityNode(
        id: 'n',
        claimId: 'c1',
        result: Mismatch(
          similarity: 41.2,
          strike: 2,
          strikesAllowed: 3,
          at: _at,
        ),
      );

      expect(node.payload['strike'], 2);
      expect(node.payload['strikesAllowed'], 3);
    });
  });

  group('JSON round trip', () {
    test('preserves every node and edge', () {
      final restored = graphFromJson(graphToJson(_graph()));

      expect(restored.claimId, 'c1');
      expect(restored.nodes, hasLength(7));
      expect(restored.edges, hasLength(5));
      expect(restored.isWellFormed, isTrue);
    });

    test('preserves rationale and basis on every edge', () {
      final original = _graph();
      final restored = graphFromJson(graphToJson(original));

      for (var i = 0; i < original.edges.length; i++) {
        expect(restored.edges[i].rationale, original.edges[i].rationale);
        expect(restored.edges[i].basis, original.edges[i].basis);
        expect(restored.edges[i].type, original.edges[i].type);
      }
    });

    test('preserves an Unchecked node with no similarity appearing', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.identityNode(
            id: 'n',
            claimId: 'c1',
            result: Unchecked(reason: UncheckedReason.noCamera, at: _at),
          ),
        ],
        edges: const [],
      );

      final restored = graphFromJson(graphToJson(graph));
      expect(restored.nodes.single.payload.containsKey('similarity'), isFalse);
    });

    test('a null sourceRef stays null', () {
      final restored = graphFromJson(graphToJson(_graph()));
      final answer = restored.nodes.firstWhere((n) => n.id == 'n2');
      expect(answer.sourceRef, isNull);
    });
  });

  group('decoding is strict', () {
    test('an unknown edge type throws instead of defaulting', () {
      final json = graphToJson(_graph());
      final firstEdge = (json['edges']! as List).first as Map<String, Object?>;
      firstEdge['type'] = 'stronglyImplies';

      expect(() => graphFromJson(json), throwsA(isA<FormatException>()));
    });

    test('an unknown node type throws', () {
      final json = graphToJson(_graph());
      final firstNode = (json['nodes']! as List).first as Map<String, Object?>;
      firstNode['type'] = 'vibeCheck';

      expect(() => graphFromJson(json), throwsA(isA<FormatException>()));
    });

    test('an unknown edge basis throws', () {
      final json = graphToJson(_graph());
      final firstEdge = (json['edges']! as List).first as Map<String, Object?>;
      firstEdge['basis'] = 'intuition';

      expect(() => graphFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a future schema version is refused rather than guessed at', () {
      final json = graphToJson(_graph());
      json['schemaVersion'] = graphSchemaVersion + 1;

      expect(() => graphFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a malformed timestamp throws', () {
      final json = graphToJson(_graph());
      final firstNode = (json['nodes']! as List).first as Map<String, Object?>;
      firstNode['createdAt'] = 'sometime last week';

      expect(() => graphFromJson(json), throwsA(isA<FormatException>()));
    });
  });

  group('GraphML export', () {
    test('is a complete document with every node and edge', () {
      final xml = graphToGraphMl(_graph());

      expect(xml, startsWith('<?xml version="1.0"'));
      expect(xml.trimRight(), endsWith('</graphml>'));
      expect('<node id='.allMatches(xml), hasLength(7));
      expect('<edge source='.allMatches(xml), hasLength(5));
    });

    test('carries rationale and basis on every edge', () {
      final xml = graphToGraphMl(_graph());

      expect(xml, contains('consistent hashing'));
      expect(xml, contains('llmDimensionJudgment'));
      expect(xml, contains('identityCheckResult'));
    });

    test('escapes markup in untrusted claim text', () {
      final graph = EvidenceGraph(
        claimId: 'c1',
        nodes: [
          _builder.claimNode(
            const Claim(
              id: 'c1',
              text: 'Wrote a <parser> & tuned it',
              source: 'Resume',
            ),
            at: _at,
          ),
        ],
        edges: const [],
      );

      final xml = graphToGraphMl(graph);
      expect(xml, isNot(contains('<parser>')));
      expect(xml, contains('&lt;parser&gt; &amp; tuned it'));
    });
  });
}
