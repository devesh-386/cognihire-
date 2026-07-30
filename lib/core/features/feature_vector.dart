import 'feature_registry.dart';

/// A versioned, named bundle of feature values for one point-in-time
/// assembly (typically: one claim's task, at the moment it is scored).
///
/// ## Design rules, inherited from the registry
///
/// * Every key in [values] must be a name known to [FeatureRegistry] — a
///   feature that is not registered cannot be put in a vector, which is the
///   single enforcement point that keeps the registry authoritative rather
///   than aspirational.
/// * A value of `null` means "not measurable" and is preserved exactly through
///   JSON — never collapsed to `0`, never dropped from the map. Dropping the
///   key would make "not measurable" indistinguishable from "not yet
///   computed"; keeping the key with a JSON `null` makes it indistinguishable
///   from nothing else.
class FeatureVector {
  // Constructing directly with a non-current [registryVersion] is legal (used
  // by fromJson to hold an already-rejected old vector's data mid-parse in
  // tests) but the assembler always stamps the live version; version
  // enforcement for *loaded* vectors happens in fromJson, deliberately.
  FeatureVector({
    required this.registryVersion,
    required Map<String, double?> values,
  }) : values = Map.unmodifiable(_validated(values));

  final int registryVersion;
  final Map<String, double?> values;

  static Map<String, double?> _validated(Map<String, double?> values) {
    for (final name in values.keys) {
      if (!FeatureRegistry.instance.contains(name)) {
        throw ArgumentError('"$name" is not a registered feature');
      }
    }
    return values;
  }

  double? value(String name) => values[name];

  /// Whether [name] was actually measured in this vector (present and
  /// non-null). False both for "not in this vector" and "present but null" —
  /// callers that need to distinguish those two read [values] directly.
  bool isMeasured(String name) => values[name] != null;

  Map<String, Object?> toJson() => {
        'registryVersion': registryVersion,
        'values': values,
      };

  /// Rebuild from JSON. Refuses a vector computed under a different registry
  /// version — an old vector's features may have been redefined, renamed, or
  /// removed, and silently comparing it against current-version features would
  /// compare quantities that no longer mean the same thing.
  static FeatureVector fromJson(Map<String, Object?> json) {
    const context = 'FeatureVector';
    final version = json['registryVersion'];
    if (version is! int) {
      throw const FormatException('$context: missing "registryVersion"');
    }
    if (version != featureRegistryVersion) {
      throw FormatException(
        '$context: stored under registry v$version, current build is '
        'v$featureRegistryVersion — not safe to compare or reuse',
      );
    }
    final raw = json['values'];
    if (raw is! Map) {
      throw const FormatException('$context: missing "values" object');
    }
    final values = <String, double?>{};
    raw.forEach((key, v) {
      if (v == null) {
        values[key as String] = null;
      } else if (v is num) {
        values[key as String] = v.toDouble();
      } else {
        throw FormatException(
          '$context: value for "$key" expected num or null, got '
          '${v.runtimeType}',
        );
      }
    });
    return FeatureVector(registryVersion: version, values: values);
  }
}
