/// The evidence graph: typed nodes and edges over what a session observed.
///
/// ## What this adds over the audit
///
/// `ClaimAudit` already records what happened. What it does NOT record is the
/// *relationship* between two pieces of evidence — whether an answer supports
/// a claim or contradicts it lives only inside the prose of
/// `ClaimEvidence.observation`, where a human infers it from English. The
/// graph makes that relationship a first-class, typed, cited fact.
///
/// This is additive. The audit stays the source of truth for what occurred;
/// the graph indexes it and adds the previously-implicit edges.
///
/// ## Explainability constraints, enforced structurally
///
/// 1. Edge types are a closed enum — a legend can always be complete.
/// 2. Every edge carries a non-empty `rationale`. Enforced at decode time:
///    an edge without one is a corrupt record, not an unannotated one.
/// 3. Every edge carries an [EdgeBasis] — what *kind* of thing produced it.
///    Never a vague "the system decided".
/// 4. **No numeric weight is stored on an edge, ever.** A rendering layer that
///    needs a number for force-layout computes it at draw time from a visible
///    lookup table and throws it away.
/// 5. **No aggregate score is computed from the graph.** Specifically: do not
///    add PageRank, betweenness centrality, or any node-ranking algorithm and
///    present the result as "claim strength". That is a hidden weight with
///    extra steps, and it violates this design as surely as a bare model-
///    reported float would. There is deliberately no `strength()` method on
///    [EvidenceGraph] — if you are about to add one, re-read this.
/// 6. Traversal returns evidence with its rationale intact, never a count.
library;

import '../claims/claim.dart';
import '../verification/verification_result.dart';

/// What a node represents. Five of seven wrap a type that already exists.
enum NodeType {
  /// A `Claim` from the resume.
  resumeClaim,

  /// One submitted answer.
  interviewAnswer,

  /// One `VerificationResult`.
  identityCheck,

  /// A specific cited span of code — not the whole answer.
  codeEvidence,

  /// A `ProcessSignals` snapshot.
  telemetry,

  /// An `AskedFollowUp`.
  followUpQuestion,

  /// A human reviewer's note.
  reviewerComment,
}

/// What a relationship means.
///
/// `derivedFrom` is deliberately separate from the evidentiary types: it
/// answers "why does this node exist" (mechanics — a follow-up exists because
/// telemetry triggered it), while the others answer "what does this evidence
/// mean" (which a human reasons with). Both are "traceable", in two different
/// senses of the word.
enum EdgeType {
  supports,
  partiallySupports,
  contradicts,

  /// Two evidence nodes reinforce each other. Not a claim edge.
  corroborates,

  /// A question targets a piece of evidence; not yet resolved.
  probes,

  /// A reviewer comment attaches to a node. Observational, not a verdict.
  annotates,

  /// Mechanical provenance: why this node exists at all.
  derivedFrom,
}

/// What kind of thing produced an edge. Closed set, always stated.
enum EdgeBasis {
  /// The bounded adequacy judge (addressed/partial/notAddressed).
  llmDimensionJudgment,

  /// The bounded contradiction check (consistent/contradicts/unclear).
  llmContradictionCheck,

  /// A deterministic `FollowUpGenerator` trigger.
  telemetryRule,

  /// A `VerificationResult` itself. No model involved.
  identityCheckResult,

  /// A human typed this.
  reviewerAuthored,

  /// Mechanical fact, no judgment.
  systemDerivation,
}

/// One node. `payload` is discriminated by [type].
class GraphNode {
  const GraphNode({
    required this.id,
    required this.claimId,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.sourceRef,
  });

  final String id;

  /// Every node belongs to one claim's examination, matching `ClaimAudit`'s
  /// existing per-claim organisation.
  final String claimId;

  final NodeType type;
  final Map<String, Object?> payload;
  final DateTime createdAt;

  /// Pointer back into existing data — the specific `VerificationResult` or
  /// `AskedFollowUp` this wraps. The graph indexes evidence; it does not
  /// duplicate its meaning.
  final String? sourceRef;

  /// Short human-facing label for rendering. Derived from the payload rather
  /// than stored, so a node can never carry a label that disagrees with its
  /// own content.
  String get label => switch (type) {
        NodeType.resumeClaim => payload['text'] as String? ?? claimId,
        NodeType.interviewAnswer => _truncate(payload['text'] as String? ?? ''),
        NodeType.identityCheck => payload['outcome'] as String? ?? 'Check',
        NodeType.codeEvidence => _truncate(payload['quotedSpan'] as String? ?? ''),
        NodeType.telemetry => payload['summary'] as String? ?? 'Telemetry',
        NodeType.followUpQuestion =>
          _truncate(payload['question'] as String? ?? ''),
        NodeType.reviewerComment => _truncate(payload['text'] as String? ?? ''),
      };

  static String _truncate(String raw, [int max = 60]) =>
      raw.length <= max ? raw : '${raw.substring(0, max - 1)}…';
}

/// One typed, cited relationship.
///
/// Note what is absent: any numeric weight. See constraint 4 in the library
/// doc above.
class GraphEdge {
  const GraphEdge({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    required this.type,
    required this.rationale,
    required this.basis,
    required this.createdAt,
    required this.createdBy,
  });

  final String id;
  final String fromNodeId;
  final String toNodeId;
  final EdgeType type;

  /// Why this edge exists, in a human sentence. Required and non-empty —
  /// an edge that cannot say why it exists is not traceable, which is the
  /// one property this whole design is for.
  final String rationale;

  final EdgeBasis basis;
  final DateTime createdAt;

  /// A model-version string, or a reviewer's name.
  final String createdBy;

  /// True for edges that carry evidentiary meaning, as opposed to mechanical
  /// provenance (`derivedFrom`) or reviewer annotation.
  bool get isEvidentiary => switch (type) {
        EdgeType.supports ||
        EdgeType.partiallySupports ||
        EdgeType.contradicts ||
        EdgeType.corroborates =>
          true,
        EdgeType.probes || EdgeType.annotates || EdgeType.derivedFrom => false,
      };
}

/// The graph for one claim's examination.
class EvidenceGraph {
  EvidenceGraph({
    required this.claimId,
    required List<GraphNode> nodes,
    required List<GraphEdge> edges,
  })  : nodes = List.unmodifiable(nodes),
        edges = List.unmodifiable(edges);

  final String claimId;
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  GraphNode? nodeById(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  List<GraphEdge> edgesInto(String nodeId) =>
      edges.where((e) => e.toNodeId == nodeId).toList(growable: false);

  List<GraphEdge> edgesOutOf(String nodeId) =>
      edges.where((e) => e.fromNodeId == nodeId).toList(growable: false);

  /// Every edge touching this node, in either direction.
  List<GraphEdge> edgesTouching(String nodeId) => edges
      .where((e) => e.fromNodeId == nodeId || e.toNodeId == nodeId)
      .toList(growable: false);

  List<GraphNode> nodesOfType(NodeType type) =>
      nodes.where((n) => n.type == type).toList(growable: false);

  List<GraphEdge> edgesOfType(EdgeType type) =>
      edges.where((e) => e.type == type).toList(growable: false);

  /// The claim node, if one exists. A well-formed graph has exactly one.
  GraphNode? get claimNode {
    for (final node in nodes) {
      if (node.type == NodeType.resumeClaim) return node;
    }
    return null;
  }

  /// Everything that contradicts the given node, returned **in full** with
  /// each edge's rationale — never a count, never a weighted summary. A
  /// reviewer asking "what argues against this?" gets the actual evidence.
  List<({GraphNode node, GraphEdge edge})> contradicting(String nodeId) {
    final out = <({GraphNode node, GraphEdge edge})>[];
    for (final edge in edges) {
      if (edge.type != EdgeType.contradicts || edge.toNodeId != nodeId) {
        continue;
      }
      final from = nodeById(edge.fromNodeId);
      if (from != null) out.add((node: from, edge: edge));
    }
    return out;
  }

  /// Same shape as [contradicting], for supporting evidence. Counts
  /// `partiallySupports` separately rather than folding it in — the
  /// distinction is exactly the information a reviewer needs.
  List<({GraphNode node, GraphEdge edge})> supporting(
    String nodeId, {
    bool includePartial = true,
  }) {
    final out = <({GraphNode node, GraphEdge edge})>[];
    for (final edge in edges) {
      final matches = edge.type == EdgeType.supports ||
          (includePartial && edge.type == EdgeType.partiallySupports);
      if (!matches || edge.toNodeId != nodeId) continue;
      final from = nodeById(edge.fromNodeId);
      if (from != null) out.add((node: from, edge: edge));
    }
    return out;
  }

  /// Nodes with no edge at all. Surfaced rather than hidden: an orphan is
  /// usually a bug in graph construction, and silently dropping it would make
  /// the graph look tidier than the session actually was.
  List<GraphNode> get orphanNodes {
    final touched = <String>{};
    for (final edge in edges) {
      touched.add(edge.fromNodeId);
      touched.add(edge.toNodeId);
    }
    return nodes
        .where((n) => !touched.contains(n.id))
        .toList(growable: false);
  }

  /// Edges pointing at a node that does not exist in this graph. Same
  /// reasoning as [orphanNodes] — a dangling edge is a fault, and it is
  /// reported rather than filtered out at render time.
  List<GraphEdge> get danglingEdges => edges
      .where((e) => nodeById(e.fromNodeId) == null || nodeById(e.toNodeId) == null)
      .toList(growable: false);

  bool get isWellFormed => danglingEdges.isEmpty && claimNode != null;

  // Deliberately NOT provided: strength(), centrality(), score(), rank().
  // See constraint 5 in the library documentation above.
}

/// Builds nodes from the types this project already has, so the graph is a
/// view over real session data rather than a parallel hand-maintained record.
class EvidenceGraphBuilder {
  const EvidenceGraphBuilder();

  GraphNode claimNode(Claim claim, {required DateTime at}) => GraphNode(
        id: 'n-claim-${claim.id}',
        claimId: claim.id,
        type: NodeType.resumeClaim,
        createdAt: at,
        sourceRef: claim.id,
        payload: {
          'text': claim.text,
          'source': claim.source,
          'skill': claim.skill,
        },
      );

  GraphNode answerNode({
    required String id,
    required String claimId,
    required String text,
    required DateTime at,
  }) =>
      GraphNode(
        id: id,
        claimId: claimId,
        type: NodeType.interviewAnswer,
        createdAt: at,
        payload: {'text': text},
      );

  /// Wraps a [VerificationResult] without flattening its variant.
  ///
  /// `Unchecked` carries a reason and **no similarity key at all** — the same
  /// discipline as the persistence codec. A reviewer reading the graph must
  /// not find a number where no measurement happened.
  GraphNode identityNode({
    required String id,
    required String claimId,
    required VerificationResult result,
  }) {
    final payload = switch (result) {
      Verified(:final similarity) => {
          'outcome': 'Verified',
          'similarity': similarity,
        },
      Mismatch(:final similarity, :final strike, :final strikesAllowed) => {
          'outcome': 'Mismatch',
          'similarity': similarity,
          'strike': strike,
          'strikesAllowed': strikesAllowed,
        },
      Unchecked(:final reason) => {
          'outcome': 'Not checked',
          'reason': reason.message,
        },
    };

    return GraphNode(
      id: id,
      claimId: claimId,
      type: NodeType.identityCheck,
      createdAt: result.at,
      payload: payload,
    );
  }

  GraphNode codeEvidenceNode({
    required String id,
    required String claimId,
    required String quotedSpan,
    required int charStart,
    required int charEnd,
    required DateTime at,
  }) =>
      GraphNode(
        id: id,
        claimId: claimId,
        type: NodeType.codeEvidence,
        createdAt: at,
        payload: {
          'quotedSpan': quotedSpan,
          'charStart': charStart,
          'charEnd': charEnd,
        },
      );

  GraphNode telemetryNode({
    required String id,
    required String claimId,
    required String summary,
    required DateTime at,
  }) =>
      GraphNode(
        id: id,
        claimId: claimId,
        type: NodeType.telemetry,
        createdAt: at,
        payload: {'summary': summary},
      );

  GraphNode followUpNode({
    required String id,
    required String claimId,
    required String question,
    required String observation,
    required bool wasAnswered,
    required DateTime at,
  }) =>
      GraphNode(
        id: id,
        claimId: claimId,
        type: NodeType.followUpQuestion,
        createdAt: at,
        payload: {
          'question': question,
          'observation': observation,
          'wasAnswered': wasAnswered,
        },
      );

  GraphNode reviewerCommentNode({
    required String id,
    required String claimId,
    required String reviewerName,
    required String text,
    required DateTime at,
  }) =>
      GraphNode(
        id: id,
        claimId: claimId,
        type: NodeType.reviewerComment,
        createdAt: at,
        payload: {'reviewerName': reviewerName, 'text': text},
      );

  /// Builds an edge, refusing an empty rationale at construction time rather
  /// than waiting for the codec to catch it on save.
  GraphEdge edge({
    required String id,
    required String from,
    required String to,
    required EdgeType type,
    required String rationale,
    required EdgeBasis basis,
    required DateTime at,
    required String createdBy,
  }) {
    if (rationale.trim().isEmpty) {
      throw ArgumentError.value(
        rationale,
        'rationale',
        'Every edge must say why it exists — an edge without a rationale is '
            'not traceable, which is the property this graph exists to provide',
      );
    }
    return GraphEdge(
      id: id,
      fromNodeId: from,
      toNodeId: to,
      type: type,
      rationale: rationale,
      basis: basis,
      createdAt: at,
      createdBy: createdBy,
    );
  }
}
