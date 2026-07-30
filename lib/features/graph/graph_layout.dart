/// Deterministic layered layout for an [EvidenceGraph].
///
/// Hand-rolled rather than force-directed, for two reasons that matter to this
/// project specifically:
///
/// 1. **Determinism.** A force simulation settles somewhere slightly different
///    every run. A reviewer who opens the same audit twice should see the same
///    picture — and a layout that is a pure function of the graph is testable
///    without a widget test or a golden image.
/// 2. **No weights.** Force layouts want a numeric spring strength per edge,
///    which is exactly the kind of number that gets quietly promoted into
///    "relationship strength" later. A layered layout needs none, so there is
///    nothing to promote.
///
/// The layout is by distance from the claim: the claim sits at layer 0, the
/// evidence pointing directly at it at layer 1, evidence supporting *that* at
/// layer 2, and so on. Reading down the screen is reading further from the
/// claim.
library;

import '../../core/graph/evidence_graph.dart';

/// Where one node sits. Grid coordinates, not pixels — the widget scales.
class NodePosition {
  const NodePosition({
    required this.layer,
    required this.slot,
    required this.slotsInLayer,
  });

  /// Distance from the claim node. 0 is the claim itself.
  final int layer;

  /// Index within the layer, left to right.
  final int slot;

  /// How many nodes share this layer, so the widget can space them evenly.
  final int slotsInLayer;

  /// Horizontal position as a fraction of the available width, centred within
  /// the node's own share of the row.
  double get fractionalX => (slot + 0.5) / slotsInLayer;
}

class GraphLayout {
  const GraphLayout({required this.positions, required this.layerCount});

  final Map<String, NodePosition> positions;
  final int layerCount;

  NodePosition? of(String nodeId) => positions[nodeId];
}

/// Computes the layout.
///
/// Nodes unreachable from the claim are not dropped — they are placed in a
/// final layer of their own. Silently hiding a node the graph contains would
/// make the picture tidier than the evidence actually is, which is the same
/// failure the session-history screen avoids by listing unreadable records.
GraphLayout layoutGraph(EvidenceGraph graph) {
  if (graph.nodes.isEmpty) {
    return const GraphLayout(positions: {}, layerCount: 0);
  }

  final depth = <String, int>{};
  final root = graph.claimNode;

  if (root != null) {
    depth[root.id] = 0;

    // Breadth-first outward from the claim. Edges point *toward* what they
    // relate to, so walking "away from the claim" means following edges
    // backwards — from an edge's target to its source.
    var frontier = <String>[root.id];
    var currentDepth = 0;

    while (frontier.isNotEmpty) {
      currentDepth++;
      final next = <String>[];

      for (final nodeId in frontier) {
        for (final edge in graph.edges) {
          if (edge.toNodeId != nodeId) continue;
          if (depth.containsKey(edge.fromNodeId)) continue;
          if (graph.nodeById(edge.fromNodeId) == null) continue; // dangling
          depth[edge.fromNodeId] = currentDepth;
          next.add(edge.fromNodeId);
        }
      }

      frontier = next;
    }
  }

  // Anything not reached — orphans, or everything when there is no claim node
  // — goes in a trailing layer rather than being dropped.
  final maxReached =
      depth.values.isEmpty ? -1 : depth.values.reduce((a, b) => a > b ? a : b);
  final unreachedLayer = maxReached + 1;
  for (final node in graph.nodes) {
    depth.putIfAbsent(node.id, () => unreachedLayer);
  }

  // Group by layer, ordering within a layer by creation time so the result is
  // stable across runs (ties broken by id, so it is fully determined).
  final byLayer = <int, List<GraphNode>>{};
  for (final node in graph.nodes) {
    byLayer.putIfAbsent(depth[node.id]!, () => []).add(node);
  }
  for (final layer in byLayer.values) {
    layer.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  final positions = <String, NodePosition>{};
  for (final entry in byLayer.entries) {
    for (var slot = 0; slot < entry.value.length; slot++) {
      positions[entry.value[slot].id] = NodePosition(
        layer: entry.key,
        slot: slot,
        slotsInLayer: entry.value.length,
      );
    }
  }

  final layerCount = byLayer.keys.isEmpty
      ? 0
      : byLayer.keys.reduce((a, b) => a > b ? a : b) + 1;

  return GraphLayout(positions: positions, layerCount: layerCount);
}
