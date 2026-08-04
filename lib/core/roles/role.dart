/// A role being interviewed for, and how a session's claims line up against it.
///
/// ## What this is, and what it deliberately is not
///
/// The design mockups call this "Jobs" and pair it with an "ATS Alignment" ring
/// scoring a candidate out of 100 against a job description. This is the same
/// feature without the score.
///
/// A role here is a **list of skills someone decided this role needs**, written
/// by the person running the interview. Matching it against a session answers
/// one factual question per skill: did the candidate claim it, and was that
/// claim examined? That is a coverage report. It is not a fit assessment, it does
/// not rank candidates, and it cannot — the app has no evidence about how well
/// anyone would do the job, so any number claiming to express that would be
/// fabricated.
///
/// The distinction matters legally as well as intellectually: an automated
/// alignment score used to filter applicants is the thing NYC Local Law 144 calls
/// an automated employment decision tool and requires a bias audit for. A
/// per-skill "claimed / examined / substantiated" table is not.
library;

/// A role definition. Authored locally; nothing is fetched or inferred.
class Role {
  const Role({
    required this.id,
    required this.title,
    required this.requiredSkills,
    required this.createdAt,
    this.desirableSkills = const [],
    this.notes = '',
  });

  final String id;
  final String title;

  /// Skills the author marked as required. Compared case-insensitively against
  /// claim skill tags.
  final List<String> requiredSkills;

  /// Skills that are wanted but not required. Kept separate so a coverage report
  /// can say which gaps actually matter to the author.
  final List<String> desirableSkills;

  final String notes;
  final DateTime createdAt;

  List<String> get allSkills => [...requiredSkills, ...desirableSkills];

  Role copyWith({
    String? title,
    List<String>? requiredSkills,
    List<String>? desirableSkills,
    String? notes,
  }) =>
      Role(
        id: id,
        title: title ?? this.title,
        requiredSkills: requiredSkills ?? this.requiredSkills,
        desirableSkills: desirableSkills ?? this.desirableSkills,
        notes: notes ?? this.notes,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'requiredSkills': requiredSkills,
        'desirableSkills': desirableSkills,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Strict, in the manner of the rest of this codebase's decoders: a missing or
  /// wrongly-typed field raises rather than defaulting, because a role that
  /// silently loses its required skills would produce a coverage report claiming
  /// full coverage of nothing.
  static Role fromJson(Map<String, Object?> json, String context) {
    T need<T>(String key) {
      final value = json[key];
      if (value is! T) {
        throw FormatException(
          '$context: field "$key" is ${value == null ? 'missing' : 'a '
              '${value.runtimeType}'}, expected $T',
        );
      }
      return value;
    }

    List<String> strings(String key) {
      final value = json[key];
      if (value == null) return const [];
      if (value is! List) {
        throw FormatException('$context: field "$key" is not a list');
      }
      return value.map((e) {
        if (e is! String) {
          throw FormatException('$context: "$key" holds a non-string entry');
        }
        return e;
      }).toList();
    }

    final createdAt = DateTime.tryParse(need<String>('createdAt'));
    if (createdAt == null) {
      throw FormatException('$context: "createdAt" is not an ISO-8601 instant');
    }

    return Role(
      id: need<String>('id'),
      title: need<String>('title'),
      requiredSkills: strings('requiredSkills'),
      desirableSkills: strings('desirableSkills'),
      notes: json['notes'] is String ? json['notes'] as String : '',
      createdAt: createdAt,
    );
  }
}

/// What a session showed about one skill a role asks for.
enum SkillEvidenceState {
  /// The candidate claimed it and a reviewer marked the claim substantiated.
  substantiatedClaim,

  /// The candidate claimed it, it was probed, and no reviewer has ruled on it.
  examinedClaim,

  /// The candidate claimed it, but nothing in the session tested the claim.
  claimedNotExamined,

  /// No claim in the session carries this skill tag at all. Absence of a claim,
  /// not absence of the skill — the candidate may simply not have written about
  /// it, and this state says only what the record shows.
  noClaim,
}

/// One row of a role coverage report.
class SkillCoverageRow {
  const SkillCoverageRow({
    required this.skill,
    required this.required_,
    required this.state,
    required this.claimCount,
  });

  final String skill;

  /// Trailing underscore because `required` is a Dart keyword.
  final bool required_;

  final SkillEvidenceState state;
  final int claimCount;
}
