import 'dart:math' as math;

/// A train/test split that partitions by **group**, never by row — Phase 3.2a.
///
/// ## Why grouped, and why it is not optional
///
/// The unit of independence in this data is a candidate, not a single answer.
/// One candidate produces many feature vectors (one per claim); if some of a
/// candidate's rows land in train and others in test, the model can memorise
/// that candidate's idiosyncratic typing rhythm or camera and be scored on
/// what is effectively the training set. The reported metric would then be
/// optimistic in exactly the way that later fails on a genuinely new person.
/// So the split is at the group level: a candidate is wholly in train or
/// wholly in test, and [GroupedSplit] makes leakage structurally impossible
/// rather than merely discouraged.
///
/// Deterministic given a seed so an evaluation is reproducible.
class GroupedSplit<T> {
  const GroupedSplit({required this.train, required this.test});

  final List<T> train;
  final List<T> test;

  /// Partition [examples] so that [trainFraction] of the *groups* go to train
  /// and the rest to test, with no group split across the two.
  static GroupedSplit<T> split<T>(
    List<T> examples, {
    required double trainFraction,
    required int seed,
    required String Function(T) groupOf,
  }) {
    if (trainFraction <= 0.0 || trainFraction >= 1.0) {
      throw ArgumentError(
        'trainFraction must be in (0,1) exclusive (got $trainFraction)',
      );
    }

    // Stable, sorted list of distinct groups, then a seeded shuffle so the
    // assignment is reproducible and independent of input row order.
    final groups = examples.map(groupOf).toSet().toList()..sort();
    groups.shuffle(math.Random(seed));

    final trainGroupCount = (groups.length * trainFraction).round();
    final trainGroups = groups.take(trainGroupCount).toSet();

    final train = <T>[];
    final test = <T>[];
    for (final e in examples) {
      if (trainGroups.contains(groupOf(e))) {
        train.add(e);
      } else {
        test.add(e);
      }
    }
    return GroupedSplit(train: train, test: test);
  }
}
