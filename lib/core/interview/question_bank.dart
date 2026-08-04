import 'dart:math' as math;

import '../claims/claim.dart';

/// The four kinds of claim this system probes — Phase 4.1.
///
/// The design doc proposed eleven. Four ship, on one rule: a type only exists
/// if it changes the *question you would ask*. "Built a thing", "used a tool",
/// "held a role" and "achieved an outcome" each demand a different opening and
/// a different checkable detail. The other seven were subdivisions that asked
/// the same questions with different labels, which is taxonomy, not capability.
enum ClaimType {
  /// "I built / wrote / shipped X."
  builtArtifact,

  /// "I know / used / am proficient in Y."
  usedTool,

  /// "I led / owned / worked as Z."
  heldRole,

  /// "I improved / reduced / grew some measurable thing."
  achievedOutcome,
}

/// How far into a claim a question reaches.
///
/// The order is the whole point. Opening first because a specific question
/// asked cold gets a defensive non-answer from someone who *did* do the work.
/// Verifying last because it is only meaningful against the specifics the
/// earlier rungs already put on the record.
enum ProbeDepth {
  /// Invites the person to describe the claim in their own terms.
  opening,

  /// Goes after mechanism, constraints, and trade-offs — the things that are
  /// hard to describe convincingly without having been there.
  deepening,

  /// Asks for one concrete detail a reviewer can check against the rest of the
  /// session or against the artefact itself.
  verifying,
}

/// A question with a slot for the claim it probes.
class QuestionTemplate {
  const QuestionTemplate({
    required this.type,
    required this.depth,
    required this.template,
    this.checkableDetail = '',
  });

  final ClaimType type;
  final ProbeDepth depth;

  /// The question text, containing `{claim}` exactly where the claim goes. A
  /// template without the slot would ask every claim the same thing.
  final String template;

  /// For [ProbeDepth.verifying]: what a reviewer is meant to be able to check
  /// the answer against. Empty at other depths, where there is nothing to check
  /// yet — that emptiness is a fact, not an oversight.
  final String checkableDetail;

  String render(Claim claim) => template.replaceAll('{claim}', claim.text);
}

/// A question, rendered for a specific claim.
class Question {
  const Question({
    required this.text,
    required this.depth,
    required this.checkableDetail,
  });

  final String text;
  final ProbeDepth depth;
  final String checkableDetail;
}

/// The scoped question bank — Phase 4.1.
///
/// ## What the questions are and are not allowed to do
///
/// Every question here is written to be **easy to answer well if you did the
/// thing, and hard to answer specifically if you did not** — that asymmetry is
/// the entire mechanism. What none of them do is presume the answer. There are
/// no trick questions, no "prove it", no phrasing that treats the person as a
/// suspect: an accusatory question reliably produces a defensive answer from
/// honest and dishonest people alike, which destroys exactly the signal the
/// session is trying to collect. A test enforces that vocabulary ban.
class QuestionBank {
  const QuestionBank();

  static const List<QuestionTemplate> _templates = [
    // --- builtArtifact ---
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.opening,
      template: 'Walk me through "{claim}" — what was it for, and who used it?',
    ),
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.opening,
      template: 'Where did "{claim}" start? What existed before you built it?',
    ),
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.deepening,
      template: 'On "{claim}", what was the hardest part to get right, and '
          'what did you try before the approach that worked?',
    ),
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.deepening,
      template: 'What did you deliberately leave out of "{claim}", and why was '
          'that the right call at the time?',
    ),
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.verifying,
      template: 'Describe one specific bug or failure in "{claim}" and how you '
          'tracked it down.',
      checkableDetail: 'a concrete failure mode, its symptom, and the '
          'diagnostic path — comparable against the artefact and against how '
          'the person debugs live in this session',
    ),
    QuestionTemplate(
      type: ClaimType.builtArtifact,
      depth: ProbeDepth.verifying,
      template: 'If someone opened "{claim}" today, which file or component '
          'would they need to understand first, and what does it do?',
      checkableDetail: 'a named entry point and its responsibility — checkable '
          'against the artefact itself',
    ),

    // --- usedTool ---
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.opening,
      template: 'What have you used "{claim}" for most recently?',
    ),
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.opening,
      template: 'How did you come to use "{claim}" — was it chosen, or already '
          'there?',
    ),
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.deepening,
      template: 'What does "{claim}" do badly? Where has it gotten in your way?',
    ),
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.deepening,
      template: 'When would you not reach for "{claim}", and what would you use '
          'instead?',
    ),
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.verifying,
      template: 'Describe something in "{claim}" that surprised you the first '
          'time — behaviour that was not what you expected.',
      checkableDetail: 'a specific behaviour of the tool, checkable against the '
          'tool\'s documented semantics',
    ),
    QuestionTemplate(
      type: ClaimType.usedTool,
      depth: ProbeDepth.verifying,
      template: 'What is the first thing you check in "{claim}" when something '
          'is slow or failing?',
      checkableDetail: 'a named diagnostic step, comparable against how the '
          'person works through the live task in this session',
    ),

    // --- heldRole ---
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.opening,
      template: 'In "{claim}", what were you responsible for day to day?',
    ),
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.opening,
      template: 'Who did you work with most closely in "{claim}", and on what?',
    ),
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.deepening,
      template: 'What decision in "{claim}" was yours to make, and what did you '
          'decide?',
    ),
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.deepening,
      template: 'What was going wrong in "{claim}" that you could not fix, and '
          'what did you do about it?',
    ),
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.verifying,
      template: 'Pick one week in "{claim}" and tell me what you shipped or '
          'changed that week.',
      checkableDetail: 'a bounded, dated piece of work — checkable against the '
          'timeline the person gave elsewhere in the session',
    ),
    QuestionTemplate(
      type: ClaimType.heldRole,
      depth: ProbeDepth.verifying,
      template: 'What would the person who reviewed your work in "{claim}" say '
          'you needed to get better at?',
      checkableDetail: 'a specific, named weakness — comparable against the '
          'self-description given elsewhere in the session',
    ),

    // --- achievedOutcome ---
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.opening,
      template: 'Take me through "{claim}" — what was the situation before?',
    ),
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.opening,
      template: 'Why did "{claim}" matter to whoever asked for it?',
    ),
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.deepening,
      template: 'What was the bottleneck behind "{claim}", and how did you '
          'work out that it was the bottleneck?',
    ),
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.deepening,
      template: 'What else changed at the same time as "{claim}"? How much of '
          'it would you attribute to your work?',
    ),
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.verifying,
      template: 'How was "{claim}" measured — what was the number before, and '
          'how was it captured?',
      checkableDetail: 'a named metric, a baseline, and a measurement method — '
          'the three things an unverifiable outcome is always missing',
    ),
    QuestionTemplate(
      type: ClaimType.achievedOutcome,
      depth: ProbeDepth.verifying,
      template: 'Did "{claim}" hold up after you moved on? How would you know?',
      checkableDetail: 'a durability claim with a stated way of knowing — '
          'checkable against the measurement method already given',
    ),
  ];

  /// Every template for [type], optionally narrowed to one [depth].
  static List<QuestionTemplate> templatesFor(ClaimType type,
          {ProbeDepth? depth}) =>
      _templates
          .where((t) => t.type == type && (depth == null || t.depth == depth))
          .toList(growable: false);

  /// A full opening -> deepening -> verifying ladder for [claim], taking up to
  /// [perDepth] questions per rung. Deterministic given [seed]; asking for more
  /// than a rung holds returns what exists rather than repeating a question.
  List<Question> ladderFor(
    Claim claim,
    ClaimType type, {
    int seed = 0,
    int perDepth = 1,
  }) {
    if (perDepth < 1) {
      throw ArgumentError('perDepth must be at least 1 (got $perDepth)');
    }
    final out = <Question>[];
    for (final depth in ProbeDepth.values) {
      final pool = templatesFor(type, depth: depth).toList();
      // Seed per depth so a rung's selection does not shift when a different
      // rung gains a template.
      pool.shuffle(math.Random(seed + depth.index));
      for (final t in pool.take(perDepth)) {
        out.add(Question(
          text: t.render(claim),
          depth: t.depth,
          checkableDetail: t.checkableDetail,
        ));
      }
    }
    return out;
  }

  /// Keyword rules per type, in priority order. Outcome is checked before the
  /// others because "reduced build times" is an outcome that also contains a
  /// verb the role and tool rules would happily match.
  ///
  /// ## These are matched on word boundaries, and that is not a detail
  ///
  /// An earlier version matched with plain `contains`, guarding the dangerous
  /// entries with a trailing space (`'led '`). That does not work: `'led '` is
  /// a substring of "compiled ", "handled ", "scheduled ", "controlled ",
  /// "settled ", "fulfilled " and "travelled ". Every one of those was
  /// classified [ClaimType.heldRole] and handed a leadership question ladder —
  /// silently, and confidently, about people who had led nothing. Measured on
  /// the LiveCareer corpus, this was the majority of all non-null
  /// classifications. See `question_bank_test.dart`, which pins each of those
  /// words to something other than a false leadership match.
  ///
  /// Word boundaries also mean an entry no longer needs its trailing-space
  /// guard, so `'cut '` and `'used '` are now `'cut'` and `'used'` and match
  /// "cut costs" and "used" at the end of a sentence alike.
  ///
  /// ## Coverage is deliberately not exhaustive
  ///
  /// The original lists were written against software resumes. The verbs below
  /// add the families that dominate real ones. What is *not* here is the large
  /// class of routine-duty bullets — "Monitored balance sheet accounts",
  /// "Responded to customer inquiries", "Participates in team meetings". Those
  /// are none of these four types, and forcing them into one would be exactly
  /// the invisible wrong guess this classifier exists to avoid. They return
  /// null on purpose. If that population matters, the honest fix is a fifth
  /// claim type with its own ladder, not a longer keyword list.
  static const List<(ClaimType, List<String>)> _rules = [
    (ClaimType.achievedOutcome, [
      'reduced', 'improved', 'increased', 'grew', 'cut', 'saved',
      'raised', 'lowered', 'scaled', 'sped up', 'decreased',
      'achieved', 'exceeded', 'boosted', 'streamlined', 'optimized',
      'optimised', 'accelerated', 'eliminated', 'generated', 'won',
    ]),
    (ClaimType.builtArtifact, [
      'built', 'created', 'designed', 'developed', 'shipped',
      'implemented', 'wrote', 'authored', 'launched',
      'established', 'instituted', 'introduced', 'drafted', 'produced',
      'deployed', 'configured', 'assembled', 'set up',
    ]),
    (ClaimType.heldRole, [
      'led', 'lead', 'managed', 'owned', 'headed', 'worked as',
      'served as', 'mentored', 'supervised', 'was the',
      'directed', 'oversaw', 'overseeing', 'coordinated', 'chaired',
      'staffed', 'recruited', 'responsible for', 'reported to',
    ]),
    (ClaimType.usedTool, [
      'proficient', 'experienced with', 'used', 'skilled in',
      'familiar with', 'expert in', 'fluent in', 'working knowledge',
      'operated', 'utilized', 'utilised', 'leveraged', 'administered',
      'programmed', 'certified in',
    ]),
  ];

  /// One compiled matcher per rule, in the same priority order. Built once:
  /// [classify] runs for every claim on every resume, and recompiling a few
  /// dozen patterns per call would make a batch evaluation needlessly slow.
  ///
  /// `\b` on both sides is what makes "reconciled" stop matching "led". The
  /// keywords are escaped rather than trusted as patterns — they are data, and
  /// a future entry containing a regex metacharacter should match literally
  /// rather than quietly become a wildcard.
  static final List<(ClaimType, RegExp)> _matchers = [
    for (final (type, keywords) in _rules)
      (
        type,
        RegExp(
          r'\b(?:' +
              keywords.map(RegExp.escape).join('|') +
              r')\b',
          caseSensitive: false,
        )
      ),
  ];

  /// Classify [claim], or return null when no rule matches.
  ///
  /// Null is the honest answer, not a failure: guessing a type picks a whole
  /// question ladder aimed at the wrong thing, and a reviewer reading "not
  /// classified" can route it themselves. A wrong guess is invisible; an
  /// admitted gap is actionable.
  static ClaimType? classify(Claim claim) {
    final text = claim.text.trim();
    if (text.isEmpty) return null;
    for (final (type, matcher) in _matchers) {
      if (matcher.hasMatch(text)) return type;
    }
    return null;
  }
}
