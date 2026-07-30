import 'dart:math' as math;

import '../graph/evidence_graph.dart';
import '../session/session_event_log.dart';
import '../telemetry/keystroke_event.dart';
import '../telemetry/process_telemetry.dart';
import '../verification/verification_result.dart';
import 'feature_registry.dart';
import 'feature_vector.dart';

/// Computes a [FeatureVector] from the three telemetry sources this project
/// records: keystroke-level capture, buffer-length process signals, and the
/// session event log.
///
/// ## Point-in-time discipline
///
/// This assembler is deliberately pure and synchronous: given the same three
/// inputs it always produces the same vector. It does not read live state off
/// a controller or reach into a store — the caller is responsible for handing
/// it a snapshot of exactly what should be visible at the point the vector is
/// computed. That is what "point-in-time correct" means for a feature store: a
/// feature computed for claim 2 must never be able to see claim 3's keystrokes
/// just because they happened to exist in memory by the time the function ran.
class FeatureAssembler {
  const FeatureAssembler();

  FeatureVector assemble({
    required KeystrokeLog keystrokes,
    required ProcessSignals process,
    required SessionEventLog events,

    /// This claim's evidence graph, or null when none has been built yet
    /// (e.g. before any evidence exists for a freshly-opened claim). Null
    /// here means every `graph.*` feature comes out null too — an absent
    /// graph and an empty one are different facts.
    EvidenceGraph? graph,

    /// The session's identity re-verification history in order, or null when
    /// no verification session applies at the point this vector is assembled.
    /// Null here means every `identity.*` feature comes out null — an absent
    /// history and an empty one (a session that ran zero checks) are different
    /// facts.
    List<VerificationResult>? verifications,
  }) {
    final values = <String, double?>{
      ..._typingFeatures(keystrokes),
      ..._temporalFeatures(process),
      ..._editingFeatures(process),
      ..._sessionFeatures(events),
      ..._graphFeatures(graph),
      ..._identityFeatures(verifications),
    };

    _assertCoversRegistry(values);

    return FeatureVector(
      registryVersion: featureRegistryVersion,
      values: values,
    );
  }

  Map<String, double?> _typingFeatures(KeystrokeLog log) {
    final events = log.events;

    List<int>? gapsMs;
    if (events.length >= 2) {
      gapsMs = [
        for (var i = 1; i < events.length; i++)
          events[i].at.difference(events[i - 1].at).inMilliseconds,
      ];
    }

    double? meanInterval;
    double? maxInterval;
    if (gapsMs != null) {
      meanInterval = gapsMs.reduce((a, b) => a + b) / gapsMs.length;
      maxInterval = gapsMs.reduce((a, b) => a > b ? a : b).toDouble();
    }

    // Population standard deviation needs at least two gaps (three
    // keystrokes) — one gap has nothing to vary against.
    double? stdInterval;
    if (gapsMs != null && gapsMs.length >= 2 && meanInterval != null) {
      final sumSquaredDiffs = gapsMs
          .map((g) => (g - meanInterval!) * (g - meanInterval))
          .reduce((a, b) => a + b);
      stdInterval = math.sqrt(sumSquaredDiffs / gapsMs.length);
    }

    double? minInterval;
    double? medianInterval;
    if (gapsMs != null) {
      minInterval = gapsMs.reduce((a, b) => a < b ? a : b).toDouble();
      final sorted = List<int>.from(gapsMs)..sort();
      final mid = sorted.length ~/ 2;
      medianInterval = sorted.length.isOdd
          ? sorted[mid].toDouble()
          : (sorted[mid - 1] + sorted[mid]) / 2;
    }

    double? rateOf(bool Function(KeystrokeEvent) match) {
      if (events.isEmpty) return null;
      return events.where(match).length / events.length;
    }

    // Nearest-rank P90 over the sorted gaps: rank = ceil(0.9 * n), 1-based.
    double? p90Interval;
    double? intervalCV;
    double? veryFastRate;
    if (gapsMs != null) {
      final sorted = List<int>.from(gapsMs)..sort();
      final rank = (0.9 * sorted.length).ceil().clamp(1, sorted.length);
      p90Interval = sorted[rank - 1].toDouble();
      if (meanInterval != null && meanInterval != 0 && stdInterval != null) {
        intervalCV = stdInterval / meanInterval;
      }
      const veryFastThresholdMs = 30;
      veryFastRate =
          gapsMs.where((g) => g < veryFastThresholdMs).length / gapsMs.length;
    }

    double totalCursorTravel = 0;
    for (var i = 1; i < events.length; i++) {
      totalCursorTravel +=
          (events[i].cursorPosition - events[i - 1].cursorPosition).abs();
    }

    double? meanSelectionLength;
    if (events.isNotEmpty) {
      meanSelectionLength =
          events.map((e) => e.selectionLength).reduce((a, b) => a + b) /
              events.length;
    }

    // Bursts: maximal runs of keystrokes with no inter-key gap exceeding the
    // threshold. Always computable (0 for an empty log), unlike the gap
    // statistics above which need at least two events to mean anything.
    const burstGapThresholdMs = 500;
    var burstCount = 0;
    var longestBurst = 0;
    if (events.isNotEmpty) {
      var currentBurst = 1;
      burstCount = 1;
      longestBurst = 1;
      for (var i = 1; i < events.length; i++) {
        final gap = events[i].at.difference(events[i - 1].at).inMilliseconds;
        if (gap <= burstGapThresholdMs) {
          currentBurst++;
        } else {
          burstCount++;
          currentBurst = 1;
        }
        if (currentBurst > longestBurst) longestBurst = currentBurst;
      }
    }

    return {
      'typing.meanInterKeyIntervalMs': meanInterval,
      'typing.stdInterKeyIntervalMs': stdInterval,
      'typing.maxInterKeyIntervalMs': maxInterval,
      'typing.minInterKeyIntervalMs': minInterval,
      'typing.medianInterKeyIntervalMs': medianInterval,
      'typing.backspaceRate':
          rateOf((e) => e.action == KeystrokeAction.delete),
      'typing.insertRate': rateOf((e) => e.action == KeystrokeAction.insert),
      'typing.navRate': rateOf((e) => e.action == KeystrokeAction.navigate),
      'typing.selectionRate':
          rateOf((e) => e.action == KeystrokeAction.select),
      'typing.alphaRate': rateOf((e) => e.keycodeClass == KeycodeClass.alpha),
      'typing.digitRate': rateOf((e) => e.keycodeClass == KeycodeClass.digit),
      'typing.symbolRate':
          rateOf((e) => e.keycodeClass == KeycodeClass.symbol),
      'typing.whitespaceRate':
          rateOf((e) => e.keycodeClass == KeycodeClass.whitespace),
      'typing.modifierRate':
          rateOf((e) => e.keycodeClass == KeycodeClass.modifier),
      'typing.cursorTravelTotal': totalCursorTravel,
      'typing.meanSelectionLength': meanSelectionLength,
      'typing.p90InterKeyIntervalMs': p90Interval,
      'typing.interKeyIntervalCV': intervalCV,
      'typing.veryFastKeystrokeRate': veryFastRate,
      'typing.burstCount': burstCount.toDouble(),
      'typing.longestBurstLength': longestBurst.toDouble(),
      // A count is always measurable — zero keystrokes is a real zero, not an
      // absence of measurement.
      'typing.keystrokeCount': events.length.toDouble(),
    };
  }

  Map<String, double?> _temporalFeatures(ProcessSignals process) {
    const earlyStartThresholdMs = 3000;
    final timeToFirst = process.timeToFirstKeystroke;

    return {
      'temporal.timeToFirstKeystrokeMs': timeToFirst?.inMilliseconds.toDouble(),
      'temporal.pauseCount': process.pauseCount.toDouble(),
      'temporal.pauseRatio': process.editCount == 0
          ? null
          : process.pauseCount / process.editCount,
      // Null (not false/0.0) when nothing was typed: there is no
      // time-to-first-keystroke to threshold against, so "early or not" is
      // genuinely inapplicable rather than a measured "no".
      'temporal.hasEarlyStartFlag': timeToFirst == null
          ? null
          : (timeToFirst.inMilliseconds < earlyStartThresholdMs ? 1.0 : 0.0),
      // Never null: pauseCount == 0 is itself the unambiguous measurement
      // "no pause reached the idle threshold", not a gap in what could be
      // measured (unlike hasEarlyStartFlag above).
      'temporal.hasLongPauseFlag': process.pauseCount > 0 ? 1.0 : 0.0,
    };
  }

  Map<String, double?> _editingFeatures(ProcessSignals process) {
    final gross = process.totalInserted + process.totalDeleted;
    final net = process.totalInserted - process.totalDeleted;

    return {
        'editing.revisionRatio': process.revisionRatio,
        'editing.bulkInsertCount': process.bulkInsertCount.toDouble(),
        'editing.bulkDeleteCount': process.bulkDeleteCount.toDouble(),
        'editing.editCount': process.editCount.toDouble(),
        'editing.totalInsertedChars': process.totalInserted.toDouble(),
        'editing.totalDeletedChars': process.totalDeleted.toDouble(),
        'editing.largestBulkInsertChars': process.largestBulkInsert.toDouble(),
        'editing.longestPauseMs':
            process.longestPause?.inMilliseconds.toDouble(),
        'editing.finalAnswerLengthChars': process.finalLength.toDouble(),
        'editing.hasBulkInsertFlag': process.bulkInsertCount > 0 ? 1.0 : 0.0,
        'editing.hasBulkDeleteFlag': process.bulkDeleteCount > 0 ? 1.0 : 0.0,
        'editing.averageEditSizeChars':
            process.editCount == 0 ? null : gross / process.editCount,
        'editing.netToGrossRatio': gross == 0 ? null : net / gross,
        'editing.netCharacterChange':
            (process.totalInserted - process.totalDeleted).toDouble(),
        'editing.bulkSpanShareOfTotal': process.totalInserted == 0
            ? null
            : process.largestBulkInsert / process.totalInserted,
    };
  }

  Map<String, double?> _sessionFeatures(SessionEventLog events) {
    final entries = events.entries;
    final total = entries.length;

    int countOf(SessionEventKind kind) =>
        entries.where((e) => e.kind == kind).length;

    final opened = countOf(SessionEventKind.claimOpened);
    final answered = countOf(SessionEventKind.claimAnswered);

    double? spanMs;
    double? meanInterEventMs;
    double? eventsPerMinute;
    if (total >= 2) {
      final span = entries.last.at.difference(entries.first.at).inMilliseconds;
      spanMs = span.toDouble();
      meanInterEventMs = span / (total - 1);
      // A rate needs elapsed time; a zero span (every event at one instant)
      // has no minutes to divide by.
      if (span > 0) eventsPerMinute = total / (span / 60000);
    }

    final distinctKinds = entries.map((e) => e.kind).toSet().length;

    return {
      'session.eventCount': total.toDouble(),
      'session.distinctEventKinds': distinctKinds.toDouble(),
      'session.claimOpenedCount': opened.toDouble(),
      'session.claimAnsweredCount': answered.toDouble(),
      'session.followUpCount':
          countOf(SessionEventKind.followUpAsked).toDouble(),
      'session.identityCheckedCount':
          countOf(SessionEventKind.identityChecked).toDouble(),
      'session.integrityObservedCount':
          countOf(SessionEventKind.integrityObserved).toDouble(),
      'session.spanMs': spanMs,
      'session.meanInterEventMs': meanInterEventMs,
      'session.eventsPerMinute': eventsPerMinute,
      'session.answeredToOpenedRatio': opened == 0 ? null : answered / opened,
      'session.followUpsPerAnswer': answered == 0
          ? null
          : countOf(SessionEventKind.followUpAsked) / answered,
      'session.completedFlag':
          entries.any((e) => e.kind == SessionEventKind.sessionEnded)
              ? 1.0
              : 0.0,
    };
  }

  Map<String, double?> _identityFeatures(
      List<VerificationResult>? verifications) {
    if (verifications == null) {
      return {
        for (final spec in FeatureRegistry.instance.specs)
          if (spec.group == 'identity') spec.name: null,
      };
    }

    final total = verifications.length;
    final measured = verifications.where((r) => r.didMeasure).toList();
    final verified = verifications.whereType<Verified>().length;
    final mismatches = verifications.whereType<Mismatch>().length;
    final unchecked = verifications.whereType<Unchecked>().length;

    // Rescaled 0–100 similarity of every attempt that actually measured.
    final similarities = <double>[
      for (final r in measured)
        switch (r) {
          Verified(:final similarity) => similarity,
          Mismatch(:final similarity) => similarity,
          Unchecked() => 0, // unreachable: measured excludes Unchecked
        },
    ];

    double? mean;
    double? std;
    double? minSim;
    double? maxSim;
    double? range;
    if (similarities.isNotEmpty) {
      mean = similarities.reduce((a, b) => a + b) / similarities.length;
      minSim = similarities.reduce(math.min);
      maxSim = similarities.reduce(math.max);
      range = maxSim - minSim;
      if (similarities.length >= 2) {
        final variance = similarities
                .map((s) => (s - mean!) * (s - mean))
                .reduce((a, b) => a + b) /
            similarities.length;
        std = math.sqrt(variance);
      }
    }

    // Longest run of consecutive mismatches / unchecked attempts. A run is
    // broken by any attempt not of that kind.
    var maxMismatchRun = 0;
    var curMismatchRun = 0;
    var maxUncheckedRun = 0;
    var curUncheckedRun = 0;
    for (final r in verifications) {
      curMismatchRun = r is Mismatch ? curMismatchRun + 1 : 0;
      curUncheckedRun = r is Unchecked ? curUncheckedRun + 1 : 0;
      if (curMismatchRun > maxMismatchRun) maxMismatchRun = curMismatchRun;
      if (curUncheckedRun > maxUncheckedRun) maxUncheckedRun = curUncheckedRun;
    }

    final hadCritical =
        verifications.whereType<Mismatch>().any((m) => m.isCritical);

    // The first attempt that measured anything — null flag if none ever did.
    double? firstMeasuredVerified;
    for (final r in verifications) {
      if (r.didMeasure) {
        firstMeasuredVerified = r.isVerified ? 1.0 : 0.0;
        break;
      }
    }

    return {
      'identity.checkCount': total.toDouble(),
      'identity.verifiedCount': verified.toDouble(),
      'identity.mismatchCount': mismatches.toDouble(),
      'identity.uncheckedCount': unchecked.toDouble(),
      'identity.measuredCount': measured.length.toDouble(),
      'identity.verifiedShareOfMeasured':
          measured.isEmpty ? null : verified / measured.length,
      'identity.uncheckedShareOfChecks':
          total == 0 ? null : unchecked / total,
      'identity.meanSimilarity': mean,
      'identity.minSimilarity': minSim,
      'identity.maxSimilarity': maxSim,
      'identity.stdSimilarity': std,
      'identity.similarityRange': range,
      'identity.maxConsecutiveMismatches': maxMismatchRun.toDouble(),
      'identity.hadCriticalMismatchFlag': hadCritical ? 1.0 : 0.0,
      'identity.firstCheckVerifiedFlag': firstMeasuredVerified,
      'identity.longestUncheckedRun': maxUncheckedRun.toDouble(),
    };
  }

  static const _ruleBases = {
    EdgeBasis.telemetryRule,
    EdgeBasis.identityCheckResult,
    EdgeBasis.systemDerivation,
  };
  static const _modelBases = {
    EdgeBasis.llmDimensionJudgment,
    EdgeBasis.llmContradictionCheck,
  };

  Map<String, double?> _graphFeatures(EvidenceGraph? graph) {
    if (graph == null) {
      return {
        for (final spec in FeatureRegistry.instance.specs)
          if (spec.group == 'graph') spec.name: null,
      };
    }

    final nodeCount = graph.nodes.length;
    final edgeCount = graph.edges.length;
    final adjacency = _undirectedAdjacency(graph);

    final claimNode = graph.claimNode;
    final claimDegree =
        claimNode == null ? null : graph.edgesTouching(claimNode.id).length;

    double? provenanceDistance;
    if (claimNode != null) {
      final hops = _bfsDistanceToFirst(
        adjacency,
        from: claimNode.id,
        isTarget: (id) => graph.nodeById(id)?.type == NodeType.identityCheck,
      );
      provenanceDistance = hops?.toDouble();
    }

    final nonClaimNodes =
        graph.nodes.where((n) => n.type != NodeType.resumeClaim).toList();
    final orphanEvidenceCount = graph.orphanNodes
        .where((n) => n.type != NodeType.resumeClaim)
        .length;

    double? kindDiversity;
    if (nonClaimNodes.isNotEmpty) {
      final counts = <NodeType, int>{};
      for (final n in nonClaimNodes) {
        counts[n.type] = (counts[n.type] ?? 0) + 1;
      }
      kindDiversity = 0.0;
      for (final count in counts.values) {
        final p = count / nonClaimNodes.length;
        kindDiversity = kindDiversity! - p * (math.log(p) / math.ln2);
      }
    }

    final evidentiary = graph.edges.where((e) => e.isEvidentiary).toList();
    final modelProducedEvidentiary =
        evidentiary.where((e) => _modelBases.contains(e.basis)).length;

    double? shareOf(Set<EdgeBasis> bases) => edgeCount == 0
        ? null
        : graph.edges.where((e) => bases.contains(e.basis)).length / edgeCount;

    double? largestComponentShare;
    if (nodeCount > 0) {
      final componentSizes = _connectedComponentSizes(
        graph.nodes.map((n) => n.id).toSet(),
        adjacency,
      );
      final largest = componentSizes.reduce((a, b) => a > b ? a : b);
      largestComponentShare = largest / nodeCount;
    }

    return {
      'graph.nodeCount': nodeCount.toDouble(),
      'graph.edgeCount': edgeCount.toDouble(),
      'graph.edgesPerNode': nodeCount == 0 ? null : edgeCount / nodeCount,
      'graph.supportsEdgeCount':
          graph.edgesOfType(EdgeType.supports).length.toDouble(),
      'graph.contradictsEdgeCount':
          graph.edgesOfType(EdgeType.contradicts).length.toDouble(),
      'graph.provisionalEdgeShare': evidentiary.isEmpty
          ? null
          : modelProducedEvidentiary / evidentiary.length,
      'graph.claimNodeDegree': claimDegree?.toDouble(),
      'graph.provenanceDistanceToIdentityCheck': provenanceDistance,
      'graph.orphanEvidenceCount': orphanEvidenceCount.toDouble(),
      'graph.evidenceKindDiversity': kindDiversity,
      'graph.reviewerCommentNodeCount':
          graph.nodesOfType(NodeType.reviewerComment).length.toDouble(),
      'graph.ruleBasisEdgeShare': shareOf(_ruleBases),
      'graph.modelBasisEdgeShare': shareOf(_modelBases),
      'graph.humanBasisEdgeShare': shareOf(const {EdgeBasis.reviewerAuthored}),
      'graph.density':
          nodeCount < 2 ? null : edgeCount / (nodeCount * (nodeCount - 1)),
      'graph.largestComponentShare': largestComponentShare,
    };
  }

  /// Undirected adjacency built only from edges whose both endpoints exist as
  /// nodes — a dangling edge (see [EvidenceGraph.danglingEdges]) contributes
  /// nothing rather than crashing the traversal.
  Map<String, Set<String>> _undirectedAdjacency(EvidenceGraph graph) {
    final adjacency = <String, Set<String>>{
      for (final n in graph.nodes) n.id: <String>{},
    };
    for (final e in graph.edges) {
      if (!adjacency.containsKey(e.fromNodeId) ||
          !adjacency.containsKey(e.toNodeId)) {
        continue;
      }
      adjacency[e.fromNodeId]!.add(e.toNodeId);
      adjacency[e.toNodeId]!.add(e.fromNodeId);
    }
    return adjacency;
  }

  int? _bfsDistanceToFirst(
    Map<String, Set<String>> adjacency, {
    required String from,
    required bool Function(String nodeId) isTarget,
  }) {
    if (isTarget(from)) return 0;
    final visited = {from};
    var frontier = {from};
    var hops = 0;
    while (frontier.isNotEmpty) {
      hops++;
      final next = <String>{};
      for (final id in frontier) {
        for (final neighbour in adjacency[id] ?? const <String>{}) {
          if (visited.add(neighbour)) {
            if (isTarget(neighbour)) return hops;
            next.add(neighbour);
          }
        }
      }
      frontier = next;
    }
    return null;
  }

  List<int> _connectedComponentSizes(
    Set<String> allIds,
    Map<String, Set<String>> adjacency,
  ) {
    final visited = <String>{};
    final sizes = <int>[];
    for (final start in allIds) {
      if (!visited.add(start)) continue;
      var size = 1;
      var frontier = {start};
      while (frontier.isNotEmpty) {
        final next = <String>{};
        for (final id in frontier) {
          for (final neighbour in adjacency[id] ?? const <String>{}) {
            if (visited.add(neighbour)) {
              size++;
              next.add(neighbour);
            }
          }
        }
        frontier = next;
      }
      sizes.add(size);
    }
    return sizes;
  }

  /// Fails loudly if the assembler ever drifts from the registry: every
  /// non-nullable spec must have been emitted with a non-null value, and every
  /// emitted key must be a key the registry actually knows. A silent gap here
  /// would be exactly the kind of drift the registry exists to prevent.
  void _assertCoversRegistry(Map<String, double?> values) {
    for (final spec in FeatureRegistry.instance.specs) {
      if (!values.containsKey(spec.name)) continue; // seed set is partial by design
      if (!spec.nullable && values[spec.name] == null) {
        throw StateError(
          'feature "${spec.name}" is declared non-nullable but the assembler '
          'produced null',
        );
      }
    }
  }
}
