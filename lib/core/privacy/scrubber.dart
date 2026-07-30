/// The result of scrubbing a piece of text for a research-release export.
class ScrubResult {
  const ScrubResult({required this.text, required this.redactionCount});

  final String text;

  /// How many redactions were made. Zero is a real, reportable outcome — it
  /// means the text had nothing to remove, not that scrubbing was skipped.
  final int redactionCount;
}

/// Removes personally-identifying text before a resume, claim, or transcript
/// leaves the device for research release.
///
/// ## What this catches and what it does not
///
/// Pattern-based detection (email addresses) is caught unconditionally.
/// Names and institutions are **not** pattern-detectable in general text —
/// "Alice" could be a name or a variable name — so this only redacts names and
/// institutions the caller explicitly supplies as known targets, typically
/// pulled from the same resume's own header fields before the free text is
/// scrubbed. That is a narrower guarantee than "no PII survives", stated
/// honestly rather than oversold: this is one layer of the research-release
/// pipeline (§5 of the ML redesign), not the whole of it.
class Scrubber {
  const Scrubber();

  static final RegExp _emailPattern = RegExp(
    r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}',
  );

  ScrubResult scrub(
    String text, {
    List<String> knownNames = const [],
    List<String> knownInstitutions = const [],
  }) {
    var result = text;
    var count = 0;

    final emailMatches = _emailPattern.allMatches(result).length;
    result = result.replaceAll(_emailPattern, '[EMAIL]');
    count += emailMatches;

    for (final name in knownNames) {
      if (name.isEmpty) continue;
      // Redact the full name, then its individual tokens ("Alice" alone, later
      // in the same text, is still the same declared PII) — longest match
      // first so "Alice Nguyen" isn't consumed piecemeal before the full-name
      // pattern gets to it.
      final targets = [name, ...name.split(RegExp(r'\s+'))]
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final target in targets) {
        final pattern = RegExp(
          r'\b' + RegExp.escape(target) + r'\b',
          caseSensitive: false,
        );
        count += pattern.allMatches(result).length;
        result = result.replaceAll(pattern, '[NAME]');
      }
    }

    for (final institution in knownInstitutions) {
      if (institution.isEmpty) continue;
      final pattern = RegExp(RegExp.escape(institution), caseSensitive: false);
      count += pattern.allMatches(result).length;
      result = result.replaceAll(pattern, '[INSTITUTION]');
    }

    return ScrubResult(text: result, redactionCount: count);
  }
}
