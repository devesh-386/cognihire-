import 'package:cognihire/core/ml/grouped_split.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gen = SyntheticSufficiencyGenerator();

  test('train and test never share a group (no candidate leakage)', () {
    final ds = gen.generate(count: 500, seed: 1, groupCount: 40);
    final split = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 1, groupOf: (e) => e.group);
    final trainGroups = split.train.map((e) => e.group).toSet();
    final testGroups = split.test.map((e) => e.group).toSet();
    expect(trainGroups.intersection(testGroups), isEmpty);
  });

  test('every example lands in exactly one side; none are dropped', () {
    final ds = gen.generate(count: 500, seed: 2, groupCount: 40);
    final split = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 2, groupOf: (e) => e.group);
    expect(split.train.length + split.test.length, ds.examples.length);
  });

  test('the split is deterministic for a given seed', () {
    final ds = gen.generate(count: 500, seed: 3, groupCount: 40);
    final a = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 5, groupOf: (e) => e.group);
    final b = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 5, groupOf: (e) => e.group);
    expect(a.train.map((e) => e.group).toList(),
        b.train.map((e) => e.group).toList());
    expect(a.test.map((e) => e.group).toList(),
        b.test.map((e) => e.group).toList());
  });

  test('train fraction is approximately honored at the group level', () {
    final ds = gen.generate(count: 1000, seed: 4, groupCount: 100);
    final split = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 7, groupOf: (e) => e.group);
    final trainGroups = split.train.map((e) => e.group).toSet().length;
    // 70% of 100 groups -> ~70; allow slack for group-size variation.
    expect(trainGroups, inInclusiveRange(60, 80));
  });

  test('an out-of-range fraction throws', () {
    final ds = gen.generate(count: 10, seed: 1);
    expect(
        () => GroupedSplit.split(ds.examples,
            trainFraction: 1.5, seed: 1, groupOf: (e) => e.group),
        throwsArgumentError);
  });

  test('both sides are non-empty when there are enough groups', () {
    final ds = gen.generate(count: 500, seed: 6, groupCount: 40);
    final split = GroupedSplit.split(ds.examples,
        trainFraction: 0.7, seed: 6, groupOf: (e) => e.group);
    expect(split.train, isNotEmpty);
    expect(split.test, isNotEmpty);
  });
}
