import 'claim.dart';

/// Turns resume text into candidate [Claim]s by shape and length alone — no
/// semantics, no model, no understanding of what a line means.
///
/// ## What this is, stated plainly, and why it exists at all
///
/// `ML_REDESIGN.md` §4.1 specifies a fine-tuned DeBERTa-v3 multi-task model
/// (NER + relation extraction + agency + verifiability) for real claim
/// extraction — that is Phase 1.1, and it needs a labelled dataset and a
/// model-serving pipeline this project does not have yet. Until then, the
/// interview ran on two hardcoded demo claims regardless of what resume was
/// uploaded, which is worse than an honest placeholder: it silently ignores
/// whatever the candidate actually wrote.
///
/// This class is that honest placeholder. It is a rule: strip bullet
/// markers, keep lines that look long enough to be an assertion, tag a
/// skill only when a literal keyword appears as a whole word. It has no
/// opinion about *meaning* — "This resume was generated for demonstration
/// purposes" passes through exactly as readily as a real accomplishment,
/// because nothing here reads for meaning. That is why every candidate it
/// produces is presented to the candidate for edit-or-discard before a
/// session starts (`main.dart`'s claim review step) rather than being fed
/// straight into an interview unreviewed — the human check is load-bearing,
/// not optional, precisely because this extractor cannot tell a real claim
/// from a coincidentally claim-shaped sentence.
///
/// Per the project's own rule-audit discipline ("never replace rules
/// unnecessarily"): this rule is not a stand-in pretending to be the model.
/// It is scoped, named, and documented as what it is, and it is meant to be
/// deleted — not extended — the day Phase 1.1 lands.
class HeuristicClaimExtractor {
  const HeuristicClaimExtractor({
    this.skillKeywords = _defaultSkillKeywords,
    this.maxCandidates = 8,
    this.minLineLength = 20,
  });

  /// Keywords checked as whole words, in order, against each candidate line.
  /// The first match tags the claim; case-insensitive, but the tag itself
  /// uses this list's canonical spelling.
  final List<String> skillKeywords;

  /// Hard cap on candidates returned, keeping the earliest lines. A resume
  /// with fifty bullet-shaped lines should not turn into fifty claims to
  /// review by hand.
  final int maxCandidates;

  /// Lines shorter than this (after trimming and bullet-stripping) are
  /// dropped — too short to plausibly be an assertion rather than a heading
  /// or a single skill word.
  final int minLineLength;

  static const _defaultSkillKeywords = [
    'React', 'Angular', 'Vue', 'Node.js', 'Python', 'Java', 'TypeScript',
    'JavaScript', 'Dart', 'Flutter', 'Swift', 'Kotlin', 'Go', 'Rust',
    'PostgreSQL', 'MySQL', 'MongoDB', 'Redis', 'GraphQL', 'REST',
    'Docker', 'Kubernetes', 'AWS', 'GCP', 'Azure', 'Terraform',
    'CI/CD', 'Jenkins', 'GitHub Actions',
    'TensorFlow', 'PyTorch', 'scikit-learn',
  ];

  static final RegExp _bulletPrefix = RegExp(r'^[\-\*•·▪‣◦]\s*');
  static final RegExp _emailOnly =
      RegExp(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$');

  List<Claim> extract(String resumeText, {required String source}) {
    final claims = <Claim>[];
    final seen = <String>{};

    for (final rawLine in resumeText.split('\n')) {
      if (claims.length >= maxCandidates) break;

      final stripped = rawLine.trim().replaceFirst(_bulletPrefix, '').trim();
      if (stripped.isEmpty) continue;
      if (stripped.length < minLineLength) continue;
      if (_looksLikeHeader(stripped)) continue;
      if (_emailOnly.hasMatch(stripped)) continue;
      if (!seen.add(stripped)) continue; // exact duplicate

      claims.add(Claim(
        id: 'c${claims.length + 1}',
        text: stripped,
        source: source,
        skill: _tagSkill(stripped),
      ));
    }

    return claims;
  }

  /// A section heading looks like "EXPERIENCE" or "SKILLS": short-ish, and
  /// every alphabetic character is uppercase. A real sentence of similar
  /// length will always contain a lowercase letter.
  bool _looksLikeHeader(String line) {
    final letters = line.split('').where((c) => RegExp(r'[A-Za-z]').hasMatch(c));
    if (letters.isEmpty) return false;
    return letters.every((c) => c == c.toUpperCase());
  }

  String? _tagSkill(String line) {
    for (final keyword in skillKeywords) {
      final pattern = RegExp(
        r'(?<![A-Za-z0-9])' + RegExp.escape(keyword) + r'(?![A-Za-z0-9])',
        caseSensitive: false,
      );
      if (pattern.hasMatch(line)) return keyword;
    }
    return null;
  }
}
