import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../../core/graph/evidence_graph.dart';
import 'graph_layout.dart';

/// The evidence graph for one claim, rendered as a node-link diagram.
///
/// A second view over the same session data, not a replacement for
/// [ClaimAuditScreen] — a linear, time-ordered report is genuinely the right
/// view for a reviewer in a hurry. This one is for a reviewer investigating
/// something specific, or handling a dispute.
///
/// ## What is deliberately absent
///
/// There is no summary badge anywhere on this screen — no "claim strength",
/// no percentage, no coloured ring implying an aggregate. That is the first
/// thing that would get added for scanability, and it is exactly what the
/// graph design rules out: any single number over this graph is a hidden
/// weight, whether it comes from a model or from a centrality algorithm.
///
/// What a reviewer gets instead: every node, every typed relationship, and
/// the rationale behind each one, one tap away.
class EvidenceGraphScreen extends StatefulWidget {
  const EvidenceGraphScreen({
    super.key,
    required this.graph,
    this.claimText,
  });

  final EvidenceGraph graph;

  /// Shown in the app bar so the reviewer knows which claim they are looking
  /// at without having to find the claim node first.
  final String? claimText;

  @override
  State<EvidenceGraphScreen> createState() => _EvidenceGraphScreenState();
}

class _EvidenceGraphScreenState extends State<EvidenceGraphScreen> {
  late final GraphLayout _layout = layoutGraph(widget.graph);

  String? _selectedNodeId;

  static const double _layerHeight = 132;
  static const double _nodeWidth = 176;
  static const double _nodeHeight = 76;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canvasWidth = (_layout.positions.values
                .map((p) => p.slotsInLayer)
                .fold<int>(1, (a, b) => a > b ? a : b) *
            (_nodeWidth + 28))
        .toDouble();
    final canvasHeight = (_layout.layerCount * _layerHeight) + 60;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Evidence graph'),
        bottom: widget.claimText == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '"${widget.claimText}"',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontStyle: FontStyle.italic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          _legend(theme),
          const Divider(height: 1),
          Expanded(
            child: InteractiveViewer(
              minScale: 0.4,
              maxScale: 2.5,
              boundaryMargin: const EdgeInsets.all(120),
              child: SizedBox(
                width: canvasWidth,
                height: canvasHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _EdgePainter(
                          graph: widget.graph,
                          layout: _layout,
                          selectedNodeId: _selectedNodeId,
                          nodeHeight: _nodeHeight,
                          layerHeight: _layerHeight,
                          isDark: theme.brightness == Brightness.dark,
                        ),
                      ),
                    ),
                    for (final node in widget.graph.nodes)
                      _positionedNode(node, canvasWidth, theme),
                  ],
                ),
              ),
            ),
          ),
          if (widget.graph.danglingEdges.isNotEmpty) _faultNotice(theme),
          _detailPane(theme),
        ],
      ),
    );
  }

  Widget _positionedNode(GraphNode node, double canvasWidth, ThemeData theme) {
    final position = _layout.of(node.id);
    if (position == null) return const SizedBox.shrink();

    final selected = _selectedNodeId == node.id;
    final (colour, icon) = _nodeStyle(node.type, theme);

    return Positioned(
      left: (position.fractionalX * canvasWidth) - (_nodeWidth / 2),
      top: (position.layer * _layerHeight) + 24,
      width: _nodeWidth,
      height: _nodeHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(
            () => _selectedNodeId = selected ? null : node.id,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? colour.withValues(alpha: 0.20)
                  : theme.colorScheme.surface,
              border: Border.all(
                color: selected ? colour : colour.withValues(alpha: 0.55),
                width: selected ? 2.2 : 1.2,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 13, color: colour),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        _nodeTypeLabel(node.type),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colour,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: Text(
                    node.label,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The full legend. Every edge type appears — the closed enum is what makes
  /// a complete legend possible, so showing all of it is the point.
  Widget _legend(ThemeData theme) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              for (final type in EdgeType.values) ...[
                _legendSwatch(type, theme),
                const SizedBox(width: 16),
              ],
            ],
          ),
        ),
      );

  Widget _legendSwatch(EdgeType type, ThemeData theme) {
    final colour = _edgeColour(type, theme.brightness == Brightness.dark);
    return Row(
      children: [
        SizedBox(
          width: 22,
          height: 2,
          child: CustomPaint(
            painter: _LegendLinePainter(
              colour: colour,
              dashed: _isDashed(type),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(_edgeTypeLabel(type), style: theme.textTheme.labelSmall),
      ],
    );
  }

  Widget _faultNotice(ThemeData theme) => Container(
        width: double.infinity,
        color: theme.colorScheme.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.graph.danglingEdges.length} edge(s) point to a node '
                'that is not in this graph. Shown rather than hidden — this is '
                'a fault in the record, not a tidier graph.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );

  Widget _detailPane(ThemeData theme) {
    final nodeId = _selectedNodeId;

    if (nodeId == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Text(
          'Tap any node to see its full content and every relationship '
          'touching it, each with the reason it exists.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final node = widget.graph.nodeById(nodeId);
    if (node == null) return const SizedBox.shrink();
    final touching = widget.graph.edgesTouching(nodeId);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 260),
      color: theme.colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _nodeTypeLabel(node.type),
                  style: theme.textTheme.labelLarge,
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _selectedNodeId = null),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Full payload, not the truncated label — a reviewer inspecting a
            // node should see everything it holds.
            for (final entry in node.payload.entries)
              if (entry.value != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodySmall,
                      children: [
                        TextSpan(
                          text: '${entry.key}: ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: '${entry.value}'),
                      ],
                    ),
                  ),
                ),
            const Divider(height: 20),
            Text(
              touching.isEmpty
                  ? 'No relationships touch this node.'
                  : 'Relationships (${touching.length})',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            for (final edge in touching) _edgeRow(edge, nodeId, theme),
          ],
        ),
      ),
    );
  }

  Widget _edgeRow(GraphEdge edge, String fromPerspectiveOf, ThemeData theme) {
    final outgoing = edge.fromNodeId == fromPerspectiveOf;
    final otherId = outgoing ? edge.toNodeId : edge.fromNodeId;
    final other = widget.graph.nodeById(otherId);
    final colour = _edgeColour(edge.type, theme.brightness == Brightness.dark);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              outgoing ? Icons.north_east : Icons.south_west,
              size: 13,
              color: colour,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${outgoing ? '' : 'from '}'
                  '${_edgeTypeLabel(edge.type)}'
                  '${outgoing ? ' → ' : ' '}'
                  '${other?.label ?? otherId}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colour, fontWeight: FontWeight.w600),
                ),
                // The rationale is the whole point of the graph — always shown
                // in full, never truncated or hidden behind another tap.
                Text(edge.rationale, style: theme.textTheme.bodySmall),
                Text(
                  'basis: ${_edgeBasisLabel(edge.basis)} · ${edge.createdBy}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.graph,
    required this.layout,
    required this.selectedNodeId,
    required this.nodeHeight,
    required this.layerHeight,
    required this.isDark,
  });

  final EvidenceGraph graph;
  final GraphLayout layout;
  final String? selectedNodeId;
  final double nodeHeight;
  final double layerHeight;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in graph.edges) {
      final from = layout.of(edge.fromNodeId);
      final to = layout.of(edge.toNodeId);
      if (from == null || to == null) continue; // dangling — flagged in the UI

      final start = Offset(
        from.fractionalX * size.width,
        (from.layer * layerHeight) + 24,
      );
      final end = Offset(
        to.fractionalX * size.width,
        (to.layer * layerHeight) + 24 + nodeHeight,
      );

      final touchesSelection = selectedNodeId != null &&
          (edge.fromNodeId == selectedNodeId || edge.toNodeId == selectedNodeId);
      final dimmed = selectedNodeId != null && !touchesSelection;

      final colour = _edgeColour(edge.type, isDark)
          .withValues(alpha: dimmed ? 0.15 : (touchesSelection ? 1.0 : 0.65));

      final paint = Paint()
        ..color = colour
        ..strokeWidth = touchesSelection ? 2.4 : 1.4
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(
          start.dx,
          start.dy - (layerHeight * 0.35),
          end.dx,
          end.dy + (layerHeight * 0.35),
          end.dx,
          end.dy,
        );

      canvas.drawPath(
        _isDashed(edge.type) ? _dash(path) : path,
        paint,
      );
    }
  }

  /// Dashes a path by walking its metrics — used for `probes`, which is a
  /// pending question rather than a settled relationship.
  Path _dash(Path source) {
    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + 5).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + 4;
      }
    }
    return dashed;
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.selectedNodeId != selectedNodeId ||
      oldDelegate.graph != graph ||
      oldDelegate.isDark != isDark;
}

class _LegendLinePainter extends CustomPainter {
  const _LegendLinePainter({required this.colour, required this.dashed});

  final Color colour;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 2;

    if (!dashed) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }

    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset((x + 4).clamp(0.0, size.width), size.height / 2),
        paint,
      );
      x += 7;
    }
  }

  @override
  bool shouldRepaint(_LegendLinePainter oldDelegate) =>
      oldDelegate.colour != colour || oldDelegate.dashed != dashed;
}

// ---------------------------------------------------------------------------
// Visual vocabulary
//
// Reuses the palette already used for ClaimStatus and ProvenanceQuality
// elsewhere in the app rather than inventing a second colour language.
// ---------------------------------------------------------------------------

Color _edgeColour(EdgeType type, bool isDark) {
  // Same semantic tokens the audit and history screens use, so "supports"
  // is the same green a reviewer already learned on the report.
  final evidence = isDark ? EvidenceColors.dark : EvidenceColors.light;

  return switch (type) {
    EdgeType.supports => evidence.verified,
    EdgeType.partiallySupports => evidence.unmeasured,
    EdgeType.contradicts => evidence.disputed,
    EdgeType.corroborates =>
      isDark ? const Color(0xFF5EEAD4) : const Color(0xFF0F766E),
    EdgeType.probes => isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1),
    EdgeType.annotates =>
      isDark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
    // Provenance, visually de-emphasised: it answers a different question
    // than the evidentiary edges do.
    EdgeType.derivedFrom => evidence.notExamined,
  };
}

bool _isDashed(EdgeType type) => type == EdgeType.probes;

String _edgeTypeLabel(EdgeType type) => switch (type) {
      EdgeType.supports => 'supports',
      EdgeType.partiallySupports => 'partially supports',
      EdgeType.contradicts => 'contradicts',
      EdgeType.corroborates => 'corroborates',
      EdgeType.probes => 'probes (pending)',
      EdgeType.annotates => 'annotates',
      EdgeType.derivedFrom => 'derived from',
    };

String _edgeBasisLabel(EdgeBasis basis) => switch (basis) {
      EdgeBasis.llmDimensionJudgment => 'model dimension judgment',
      EdgeBasis.llmContradictionCheck => 'model contradiction check',
      EdgeBasis.telemetryRule => 'telemetry rule',
      EdgeBasis.identityCheckResult => 'identity check result',
      EdgeBasis.reviewerAuthored => 'reviewer',
      EdgeBasis.systemDerivation => 'system derivation',
    };

String _nodeTypeLabel(NodeType type) => switch (type) {
      NodeType.resumeClaim => 'CLAIM',
      NodeType.interviewAnswer => 'ANSWER',
      NodeType.identityCheck => 'IDENTITY',
      NodeType.codeEvidence => 'CODE',
      NodeType.telemetry => 'TELEMETRY',
      NodeType.followUpQuestion => 'FOLLOW-UP',
      NodeType.reviewerComment => 'REVIEWER',
    };

(Color, IconData) _nodeStyle(NodeType type, ThemeData theme) => switch (type) {
      NodeType.resumeClaim => (theme.colorScheme.primary, Icons.description_outlined),
      NodeType.interviewAnswer => (Colors.blueGrey, Icons.forum_outlined),
      NodeType.identityCheck => (Colors.indigo, Icons.face_outlined),
      NodeType.codeEvidence => (Colors.deepPurple, Icons.code),
      NodeType.telemetry => (Colors.teal, Icons.timeline),
      NodeType.followUpQuestion => (Colors.blue, Icons.help_outline),
      NodeType.reviewerComment => (Colors.brown, Icons.sticky_note_2_outlined),
    };
