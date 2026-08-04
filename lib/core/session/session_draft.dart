/// The session being set up, shared across the screens that contribute to it.
///
/// ## Why this exists
///
/// Setting up a session now spans two destinations. **Resume analysis** reads a
/// file, extracts candidate claims, and lets the candidate edit and confirm them.
/// **New session** names the session, records the research-release choice, and
/// starts it. Before this class, all of that lived in one screen's `State`, which
/// is why it had to be one screen.
///
/// Lifting it into a [ChangeNotifier] owned by the app means the two views are
/// looking at one draft rather than passing copies around. Confirm claims on one
/// screen and the other sees them, because there is only one list.
///
/// ## Why this owns the text controllers
///
/// The claim review list is editable, and the edits have to survive navigating
/// away and back — a candidate who tidies the wording of six claims and then
/// checks the setup page must not return to find their edits gone. A controller
/// created in a `State` dies with it. These live for as long as the draft does,
/// and [dispose] tears them down.
///
/// ## The rule this class enforces
///
/// [confirmedClaims] is only ever populated by [confirmReviewed], i.e. by an
/// explicit human action. Extraction alone never fills it. That is the load-
/// bearing check in the claim pipeline: a model — even a local one — is better
/// than text rules at finding assertions and is still not a substitute for the
/// person confirming these are their own words.
library;

import 'package:flutter/widgets.dart';

import '../claims/claim.dart';
import '../claims/claim_extractor.dart';
import '../roles/role.dart';
import '../roles/role_question_priority.dart';
import '../../features/resume/resume_pick.dart';

/// One extracted claim under review: the claim as found, an editable buffer
/// seeded from it, and whether the candidate has chosen to keep it.
class DraftClaim {
  DraftClaim({required this.claim})
      : controller = TextEditingController(text: claim.text),
        keep = true;

  final Claim claim;
  final TextEditingController controller;
  bool keep;

  /// Whether this row would contribute a claim if confirmed now. Blanking the
  /// text is a valid way to drop a claim, so an empty buffer counts as removed.
  bool get contributes => keep && controller.text.trim().isNotEmpty;
}

class SessionDraft extends ChangeNotifier {
  /// Demo claims, used only when no resume has been read. Kept so the app is
  /// still demonstrable without a file to hand — and clearly sourced as demo
  /// data so nobody mistakes a walkthrough for a real candidate's record.
  static const demoClaims = [
    Claim(
      id: 'c1',
      text: 'Built and shipped a React dashboard used by 200+ staff',
      source: 'Demo claim — no resume read',
      skill: 'React',
    ),
    Claim(
      id: 'c2',
      text: 'Optimised Postgres queries, cutting p95 latency by 60%',
      source: 'Demo claim — no resume read',
      skill: 'PostgreSQL',
    ),
  ];

  ResumePick? _pick;
  ClaimExtraction? _extraction;
  List<DraftClaim> _review = [];
  List<Claim> _confirmed = const [];
  bool _extracting = false;
  String _label = '';
  bool _researchConsent = false;
  Role? _targetRole;

  ResumePick? get pick => _pick;
  ClaimExtraction? get extraction => _extraction;
  List<DraftClaim> get review => List.unmodifiable(_review);
  List<Claim> get confirmedClaims => List.unmodifiable(_confirmed);
  bool get extracting => _extracting;
  bool get researchConsent => _researchConsent;

  /// The role this session is being run against, if the operator picked one.
  /// Purely descriptive on its own — see [effectiveClaims] and
  /// `role_question_priority.dart` for the one place it is allowed to act.
  Role? get targetRole => _targetRole;

  set targetRole(Role? value) {
    if (_targetRole?.id == value?.id) return;
    _targetRole = value;
    notifyListeners();
  }

  /// The session label, or a stated placeholder. Never an invented name.
  String get label => _label.trim().isEmpty ? 'Unlabelled session' : _label.trim();

  String get rawLabel => _label;

  /// What a session started now would actually examine: the candidate's own
  /// confirmed claims when there are any, otherwise the demo set — reordered
  /// so [targetRole]'s required skills are probed first when a role has been
  /// picked. No claim is added, dropped, or hidden by this; see
  /// `orderClaimsForRole`'s doc for exactly what the reordering does and does
  /// not do.
  List<Claim> get effectiveClaims {
    final base = _confirmed.isNotEmpty ? _confirmed : demoClaims;
    final role = _targetRole;
    return role == null ? base : orderClaimsForRole(base, role);
  }

  bool get usingDemoClaims => _confirmed.isEmpty;

  set label(String value) {
    if (_label == value) return;
    _label = value;
    notifyListeners();
  }

  set researchConsent(bool value) {
    if (_researchConsent == value) return;
    _researchConsent = value;
    notifyListeners();
  }

  /// A new file was chosen. Clears everything downstream of it — including any
  /// previously confirmed claims, because those belonged to the old resume and
  /// silently carrying them into a new one would attribute the wrong words to
  /// the candidate.
  void beginPick(ResumePick pick) {
    _pick = pick;
    _extraction = null;
    _confirmed = const [];
    _disposeReview();
    _review = [];
    _extracting = pick.hasText;
    notifyListeners();
  }

  /// Extraction finished for [pick]. Ignored if a newer file has been chosen
  /// since, so a slow result cannot overwrite a fresher one.
  void completeExtraction(ResumePick pick, ClaimExtraction extraction) {
    if (_pick != pick) return;
    _extracting = false;
    _extraction = extraction;
    _disposeReview();
    _review = extraction.claims.map((c) => DraftClaim(claim: c)).toList();
    notifyListeners();
  }

  void setKeep(DraftClaim item, bool keep) {
    item.keep = keep;
    notifyListeners();
  }

  /// Copies whatever the candidate has kept and possibly edited into the set the
  /// session will run on. Discarded rows and blanked text contribute nothing, and
  /// there is no fallback to the original extracted wording once removed.
  void confirmReviewed() {
    _confirmed = [
      for (final item in _review)
        if (item.contributes)
          Claim(
            id: item.claim.id,
            text: item.controller.text.trim(),
            source: item.claim.source,
            skill: item.claim.skill,
          ),
    ];
    notifyListeners();
  }

  /// Drops the resume and everything derived from it, returning the draft to the
  /// demo-claim state. Used by the "start over" affordance.
  void clearResume() {
    _pick = null;
    _extraction = null;
    _confirmed = const [];
    _disposeReview();
    _review = [];
    _extracting = false;
    notifyListeners();
  }

  void _disposeReview() {
    for (final item in _review) {
      item.controller.dispose();
    }
  }

  @override
  void dispose() {
    _disposeReview();
    super.dispose();
  }
}
