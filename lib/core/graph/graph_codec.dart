/// JSON encoding and decoding for the evidence graph.
///
/// Same discipline as `core/persistence/json_codec.dart`: decoding is strict
/// and throws on anything it does not recognise, and never substitutes a
/// default. An unknown [EdgeType] must not quietly reread as `supports`.
///
/// One rule specific to this codec: **an edge with a missing or empty
/// `rationale` is a corrupt record and throws.** It is not "an edge that
/// happens to be unannotated". A graph whose whole promise is that every
/// relationship is traceable cannot contain an edge that can't say why it
/// exists.
library;

import '../graph/evidence_graph.dart';

/// Bumped when the on-disk shape changes incompatibly.
const int graphSchemaVersion = 1;

// ---------------------------------------------------------------------------
// Strict readers (same shape as the persistence codec's)
// ---------------------------------------------------------------------------

Object? _require(Map<String, Object?> json, String key, String context) {
  if (!json.containsKey(key)) {
    throw FormatException('$context: missing required field "$key"');
  }
  return json[key];
}

String _readString(Map<String, Object?> json, String key, String context) {
  final value = _require(json, key, context);
  if (value is! String) {
    throw FormatException(
      '$context: field "$key" expected String, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Reads a field that must be a non-empty string after trimming.
String _readNonEmptyString(
  Map<String, Object?> json,
  String key,
  String context,
) {
  final value = _readString(json, key, context);
  if (value.trim().isEmpty) {
    throw FormatException('$context: field "$key" must not be empty');
  }
  return value;
}

int _readInt(Map<String, Object?> json, String key, String context) {
  final value = _require(json, key, context);
  if (value is int) return value;
  throw FormatException(
    '$context: field "$key" expected int, got ${value.runtimeType}',
  );
}

DateTime _readTime(Map<String, Object?> json, String key, String context) {
  final raw = _readString(json, key, context);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException(
      '$context: field "$key" is not an ISO-8601 time: "$raw"',
    );
  }
  return parsed;
}

List<Map<String, Object?>> _readObjectList(
  Map<String, Object?> json,
  String key,
  String context,
) {
  final value = _require(json, key, context);
  if (value is! List) {
    throw FormatException(
      '$context: field "$key" expected List, got ${value.runtimeType}',
    );
  }
  return value.map((element) {
    if (element is! Map) {
      throw FormatException(
        '$context: "$key" contains a ${element.runtimeType}, expected an object',
      );
    }
    return element.cast<String, Object?>();
  }).toList();
}

/// Resolves an enum by declared name. An unrecognised name throws rather than
/// falling back to the first value.
T _readEnum<T extends Enum>(
  List<T> values,
  Map<String, Object?> json,
  String key,
  String context,
) {
  final name = _readString(json, key, context);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException(
    '$context: field "$key" has unknown value "$name". '
    'Known values: ${values.map((v) => v.name).join(', ')}',
  );
}

// ---------------------------------------------------------------------------
// Node
// ---------------------------------------------------------------------------

Map<String, Object?> nodeToJson(GraphNode node) => {
      'id': node.id,
      'claimId': node.claimId,
      'type': node.type.name,
      'payload': node.payload,
      'createdAt': node.createdAt.toIso8601String(),
      'sourceRef': node.sourceRef,
    };

GraphNode nodeFromJson(Map<String, Object?> json) {
  const context = 'GraphNode';

  final payload = _require(json, 'payload', context);
  if (payload is! Map) {
    throw FormatException(
      '$context: field "payload" expected object, got ${payload.runtimeType}',
    );
  }

  final sourceRef = json['sourceRef'];
  if (sourceRef != null && sourceRef is! String) {
    throw FormatException(
      '$context: field "sourceRef" expected String or null, '
      'got ${sourceRef.runtimeType}',
    );
  }

  return GraphNode(
    id: _readNonEmptyString(json, 'id', context),
    claimId: _readNonEmptyString(json, 'claimId', context),
    type: _readEnum(NodeType.values, json, 'type', context),
    payload: Map.unmodifiable(payload.cast<String, Object?>()),
    createdAt: _readTime(json, 'createdAt', context),
    sourceRef: sourceRef as String?,
  );
}

// ---------------------------------------------------------------------------
// Edge
// ---------------------------------------------------------------------------

Map<String, Object?> edgeToJson(GraphEdge edge) => {
      'id': edge.id,
      'from': edge.fromNodeId,
      'to': edge.toNodeId,
      'type': edge.type.name,
      'rationale': edge.rationale,
      'basis': edge.basis.name,
      'createdAt': edge.createdAt.toIso8601String(),
      'createdBy': edge.createdBy,
    };

GraphEdge edgeFromJson(Map<String, Object?> json) {
  const context = 'GraphEdge';

  return GraphEdge(
    id: _readNonEmptyString(json, 'id', context),
    fromNodeId: _readNonEmptyString(json, 'from', context),
    toNodeId: _readNonEmptyString(json, 'to', context),
    type: _readEnum(EdgeType.values, json, 'type', context),
    // Non-empty is the load-bearing check here, not merely "is a String".
    rationale: _readNonEmptyString(json, 'rationale', context),
    basis: _readEnum(EdgeBasis.values, json, 'basis', context),
    createdAt: _readTime(json, 'createdAt', context),
    createdBy: _readNonEmptyString(json, 'createdBy', context),
  );
}

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

Map<String, Object?> graphToJson(EvidenceGraph graph) => {
      'schemaVersion': graphSchemaVersion,
      'claimId': graph.claimId,
      'nodes': graph.nodes.map(nodeToJson).toList(),
      'edges': graph.edges.map(edgeToJson).toList(),
    };

EvidenceGraph graphFromJson(Map<String, Object?> json) {
  const context = 'EvidenceGraph';

  final version = _readInt(json, 'schemaVersion', context);
  if (version != graphSchemaVersion) {
    throw FormatException(
      '$context: stored schema version $version cannot be read by this build '
      '(expects $graphSchemaVersion)',
    );
  }

  return EvidenceGraph(
    claimId: _readNonEmptyString(json, 'claimId', context),
    nodes: _readObjectList(json, 'nodes', context).map(nodeFromJson).toList(),
    edges: _readObjectList(json, 'edges', context).map(edgeFromJson).toList(),
  );
}

// ---------------------------------------------------------------------------
// GraphML export
// ---------------------------------------------------------------------------

String _escapeXml(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Renders the graph as GraphML — an existing open standard, so an auditor can
/// open the evidence in a third-party tool (Gephi, yEd) without having
/// CogniHire installed. Useful property for a system whose pitch is that the
/// evidence should survive scrutiny from someone other than its own vendor.
///
/// Secondary format on purpose: GraphML's attribute typing is more rigid than
/// the internal shape, so re-importing for further CogniHire use should go
/// through the JSON, not a GraphML round-trip.
String graphToGraphMl(EvidenceGraph graph) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<graphml xmlns="http://graphml.graphdrawing.org/xmlns">')
    ..writeln('  <key id="nodeType" for="node" attr.name="nodeType" '
        'attr.type="string"/>')
    ..writeln('  <key id="label" for="node" attr.name="label" '
        'attr.type="string"/>')
    ..writeln('  <key id="edgeType" for="edge" attr.name="edgeType" '
        'attr.type="string"/>')
    ..writeln('  <key id="rationale" for="edge" attr.name="rationale" '
        'attr.type="string"/>')
    ..writeln('  <key id="basis" for="edge" attr.name="basis" '
        'attr.type="string"/>')
    ..writeln('  <graph id="${_escapeXml(graph.claimId)}" '
        'edgedefault="directed">');

  for (final node in graph.nodes) {
    buffer
      ..writeln('    <node id="${_escapeXml(node.id)}">')
      ..writeln('      <data key="nodeType">${_escapeXml(node.type.name)}</data>')
      ..writeln('      <data key="label">${_escapeXml(node.label)}</data>')
      ..writeln('    </node>');
  }

  for (final edge in graph.edges) {
    buffer
      ..writeln('    <edge source="${_escapeXml(edge.fromNodeId)}" '
          'target="${_escapeXml(edge.toNodeId)}">')
      ..writeln('      <data key="edgeType">${_escapeXml(edge.type.name)}</data>')
      ..writeln('      <data key="rationale">'
          '${_escapeXml(edge.rationale)}</data>')
      ..writeln('      <data key="basis">${_escapeXml(edge.basis.name)}</data>')
      ..writeln('    </edge>');
  }

  buffer
    ..writeln('  </graph>')
    ..writeln('</graphml>');

  return buffer.toString();
}
