import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/features/feature_vector.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 28, 11, 0, 0);

  group('registry', () {
    test('every registered feature has a unique name and a declared group', () {
      final names = <String>{};
      for (final spec in FeatureRegistry.instance.specs) {
        expect(names.add(spec.name), isTrue, reason: 'duplicate ${spec.name}');
        expect(spec.name.contains('.'), isTrue,
            reason: '${spec.name} should be group-qualified');
      }
      expect(FeatureRegistry.instance.specs, isNotEmpty);
    });

    test('lookup of an unknown feature throws, never returns a default', () {
      expect(() => FeatureRegistry.instance.spec('nope.notreal'),
          throwsArgumentError);
    });
  });

  group('FeatureVector — null means not-measurable, never zero', () {
    test('a null feature serialises as JSON null, not 0 and not absent', () {
      final v = FeatureVector(
        registryVersion: featureRegistryVersion,
        values: const {'typing.meanInterKeyIntervalMs': null},
      );
      final json = v.toJson();
      final values = json['values'] as Map<String, Object?>;
      expect(values.containsKey('typing.meanInterKeyIntervalMs'), isTrue);
      expect(values['typing.meanInterKeyIntervalMs'], isNull);
    });

    test('round-trips through JSON preserving null vs 0.0 distinction', () {
      final v = FeatureVector(
        registryVersion: featureRegistryVersion,
        values: const {
          'typing.backspaceRate': 0.0,
          'typing.meanInterKeyIntervalMs': null,
        },
      );
      final back = FeatureVector.fromJson(v.toJson());
      expect(back.value('typing.backspaceRate'), 0.0);
      expect(back.value('typing.meanInterKeyIntervalMs'), isNull);
      expect(back.isMeasured('typing.backspaceRate'), isTrue);
      expect(back.isMeasured('typing.meanInterKeyIntervalMs'), isFalse);
    });

    test('constructing with an unregistered feature name is rejected', () {
      expect(
        () => FeatureVector(
          registryVersion: featureRegistryVersion,
          values: const {'made.up': 1.0},
        ),
        throwsArgumentError,
      );
    });

    test('a vector from a different registry version is detectable on load', () {
      final json = FeatureVector(
        registryVersion: featureRegistryVersion,
        values: const {},
      ).toJson();
      json['registryVersion'] = featureRegistryVersion + 1;
      expect(() => FeatureVector.fromJson(json), throwsFormatException);
    });
  });

  group('assembler — computes from the three telemetry sources', () {
    ProcessTelemetry telemetryOf(List<int> lengthsAtSeconds) {
      final t = ProcessTelemetry(taskStartedAt: t0);
      var s = 1;
      for (final len in lengthsAtSeconds) {
        t.record(len, at: t0.add(Duration(seconds: s++)));
      }
      return t;
    }

    KeystrokeLog keystrokesOf(List<(int, KeycodeClass, KeystrokeAction)> evts) {
      final log = KeystrokeLog();
      var ms = 0;
      for (final (gap, cls, action) in evts) {
        ms += gap;
        log.add(KeystrokeEvent(
          at: t0.add(Duration(milliseconds: ms)),
          keycodeClass: cls,
          action: action,
          cursorPosition: 0,
          selectionLength: 0,
          lengthBefore: 0,
          lengthAfter: 1,
        ));
      }
      return log;
    }

    test('empty inputs yield all-null features — nothing is faked as zero', () {
      final v = const FeatureAssembler().assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      // Every registered feature that depends on measurement is null here.
      expect(v.value('typing.meanInterKeyIntervalMs'), isNull);
      expect(v.value('temporal.timeToFirstKeystrokeMs'), isNull);
      expect(v.value('editing.revisionRatio'), isNull);
      // The one genuinely-always-measurable feature: a count, which is 0 events.
      expect(v.value('session.eventCount'), 0.0);
    });

    test('mean inter-key interval is the average gap between keystrokes', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (300, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = const FeatureAssembler().assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      // Timestamps at 0ms, 100ms, 400ms → gaps of 100ms and 300ms → mean 200ms.
      expect(v.value('typing.meanInterKeyIntervalMs'), closeTo(200, 1e-9));
    });

    test('mean inter-key interval is null with fewer than two keystrokes', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = const FeatureAssembler().assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.meanInterKeyIntervalMs'), isNull);
    });

    test('backspace rate is deletes over total keystrokes', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.delete, KeystrokeAction.delete),
        (50, KeycodeClass.delete, KeystrokeAction.delete),
      ]);
      final v = const FeatureAssembler().assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.backspaceRate'), closeTo(0.5, 1e-9));
    });

    test('process-derived features are pulled through from ProcessSignals', () {
      final t = telemetryOf([100, 50]); // +100 then -50 → revisionRatio 0.5
      final v = const FeatureAssembler().assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.revisionRatio'), closeTo(0.5, 1e-9));
      expect(v.value('temporal.timeToFirstKeystrokeMs'), closeTo(1000, 1e-9));
    });

    test('every value the assembler emits is a registered feature', () {
      final v = const FeatureAssembler().assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      for (final name in v.values.keys) {
        // Throws if any emitted name is not in the registry.
        FeatureRegistry.instance.spec(name);
      }
      expect(v.registryVersion, featureRegistryVersion);
    });
  });
}
