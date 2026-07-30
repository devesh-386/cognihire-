import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/claims/claim.dart';
import '../../core/config.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/verification/face_engine.dart';
import '../../core/verification/verification_result.dart';
import '../../core/verification/verification_session.dart';
import '../../core/integrity/integrity_tracker.dart';
import '../audit/claim_audit_screen.dart';
import '../session/verification_status_card.dart';
import 'interview_controller.dart';

/// The unified session: identity verified continuously while the candidate
/// works through their claims, with follow-ups raised live.
///
/// Both differentiators run in the same session because the audit needs them
/// together — a claim examined during a window where identity could not be
/// verified is a materially weaker piece of evidence, and the report says so.
///
/// Enrolment is a precondition, not an option — a session cannot start
/// without an enrolled reference. That is a decision about when the product
/// runs at all, and it is separate from what happens once it is running:
/// mid-session, a check can still fail (`Unchecked`, `Mismatch`), and the
/// audit still reports that honestly rather than fabricating a pass. Nothing
/// here claims the system can *prevent* a substitute sitting the enrolment
/// itself — it can't, and doesn't pretend to.
class InterviewScreen extends StatefulWidget {
  const InterviewScreen({
    super.key,
    required this.claims,
    required this.enrolledEmbedding,
    this.store,
    this.candidateLabel = 'Unlabelled session',
    this.researchConsentGranted,
  });

  final List<Claim> claims;

  /// The reference captured at enrolment. Required — see the class doc.
  final List<double> enrolledEmbedding;

  /// Where the finished audit is kept. Null runs the session without saving —
  /// which the screen says out loud when the session ends, rather than letting
  /// the reviewer assume a record exists.
  final AuditStore? store;

  /// What this session is filed under in the history list.
  final String candidateLabel;

  /// The candidate's research-release choice, captured before the session
  /// starts. `null` means it was never asked. See
  /// [InterviewController.new]'s doc for why `null` is kept distinct from
  /// `false`.
  final bool? researchConsentGranted;

  @override
  State<InterviewScreen> createState() => _InterviewScreenState();
}

class _InterviewScreenState extends State<InterviewScreen> {
  late final InterviewController _interview = InterviewController(
    claims: widget.claims,
    researchConsentGranted: widget.researchConsentGranted,
  );
  final _tracker = IntegrityTracker();
  final _answerController = TextEditingController();
  final Map<String, TextEditingController> _followUpControllers = {};

  CameraController? _camera;
  String? _cameraError;
  bool _grabbing = false;
  VerificationSession? _verification;
  VerificationResult? _latestVerification;
  bool _halted = false;
  bool _starting = true;

  /// Guards against "End session" and the last "Next claim" both landing, which
  /// would write the same audit twice.
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _answerController.addListener(_onEdit);
    _start();
  }

  Future<void> _start() async {
    await _initCamera();
    if (!mounted) return;

    final session = VerificationSession(
      engine: HttpFaceEngine(baseUrl: AppConfig.faceServiceUrl),
      grabFrame: _grabFrame,
      tracker: _tracker,
      enrolledEmbedding: widget.enrolledEmbedding,
    );
    session.results.listen((r) {
      _interview.recordIdentityAttempt(r);
      if (mounted) setState(() => _latestVerification = r);
    });
    session.onCritical.listen((_) {
      if (mounted) setState(() => _halted = true);
    });
    _verification = session;
    await session.start();

    if (mounted) setState(() => _starting = false);
  }

  Future<void> _initCamera({int attempts = 4}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          _cameraError = 'No camera found on this device.';
          return;
        }
        final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first,
        );
        final controller = CameraController(front, ResolutionPreset.medium,
            enableAudio: false);
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        _camera = controller;
        _cameraError = null;
        return;
      } catch (e) {
        _cameraError = 'Camera unavailable: $e';
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
  }

  Future<Uint8List?> _grabFrame() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _grabbing) return null;
    _grabbing = true;
    try {
      final shot = await camera.takePicture();
      return await shot.readAsBytes();
    } catch (_) {
      return null;
    } finally {
      _grabbing = false;
    }
  }

  void _onEdit() {
    final fresh = _interview.recordEdit(_answerController.text);
    if (fresh.isNotEmpty && mounted) setState(() {});
  }

  void _nextClaim() {
    final moved = _interview.advance();
    if (!moved) {
      unawaited(_finish());
      return;
    }
    _answerController.removeListener(_onEdit);
    _answerController.clear();
    _answerController.addListener(_onEdit);
    _followUpControllers.clear();
    setState(() {});
  }

  /// Ends the session, saves the audit, then shows it.
  ///
  /// The audit is shown either way. A failed save is reported as a failed save
  /// — the reviewer is looking at a real session that simply was not written to
  /// disk, and needs to know that before they close the window.
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;

    _interview.end();
    _verification?.stop();
    final audit = _interview.buildAudit();

    String? saveError;
    final store = widget.store;
    if (store != null) {
      try {
        await store.saveAudit(audit, label: widget.candidateLabel);
      } catch (error) {
        saveError = '$error';
      }
    }

    if (!mounted) return;

    // Not awaited: pushReplacement completes only when the audit screen is
    // popped, and the save message needs to be visible *on* that screen. The
    // messenger lives above the route, so the bar survives the transition.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ClaimAuditScreen(
          audit: audit,
          label: widget.candidateLabel,
        ),
      ),
    );

    if (store == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('This session was not saved — no storage available.'),
      ));
    } else if (saveError != null) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 8),
        content: Text('Audit could NOT be saved: $saveError'),
      ));
    }
  }

  @override
  void dispose() {
    _answerController.removeListener(_onEdit);
    _answerController.dispose();
    for (final c in _followUpControllers.values) {
      c.dispose();
    }
    _verification?.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_starting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final claim = _interview.currentClaim;
    if (claim == null) {
      return const Scaffold(body: Center(child: Text('No claims to examine.')));
    }

    final isLast = _interview.currentIndex == widget.claims.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Claim ${_interview.currentIndex + 1} of ${widget.claims.length}',
        ),
        actions: [
          TextButton(
            onPressed: _finish,
            child: const Text('End session'),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: _taskPane(claim, isLast)),
          const VerticalDivider(width: 1),
          SizedBox(width: 330, child: _sidePane(claim)),
        ],
      ),
    );
  }

  Widget _taskPane(Claim claim, bool isLast) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Their claim',
                        style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Text('"${claim.text}"',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                    const SizedBox(height: 6),
                    Text(
                      'Demonstrate this. Write the code or explain the work.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _scriptedQuestions(claim),
            Expanded(
              child: TextField(
                controller: _answerController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Your answer…',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _halted ? null : _nextClaim,
              icon: Icon(isLast ? Icons.fact_check : Icons.arrow_forward),
              label: Text(isLast ? 'Finish and build audit' : 'Next claim'),
            ),
          ],
        ),
      );

  /// The scripted ladder for this claim: general -> specific -> checkable.
  ///
  /// Shown to the *interviewer* as prompts to work through, not auto-asked. And
  /// when the bank could not classify the claim it says so plainly instead of
  /// falling back to a generic question — a generic question presented as a
  /// targeted one is exactly the kind of quiet dishonesty this project refuses.
  Widget _scriptedQuestions(Claim claim) {
    final theme = Theme.of(context);
    final questions = _interview.questionsFor(claim.id);
    final type = _interview.claimTypeFor(claim.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Questions to work through',
                      style: theme.textTheme.labelMedium),
                ),
                if (type != null)
                  Text(type.name, style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 6),
            if (questions.isEmpty)
              Text(
                'This claim could not be classified, so there is no scripted '
                'ladder for it — ask your own questions. No generic prompt is '
                'shown here on purpose.',
                style: theme.textTheme.bodySmall,
              )
            else
              for (final q in questions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${q.depth.name}: ${q.text}',
                          style: theme.textTheme.bodySmall),
                      if (q.checkableDetail.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, left: 10),
                          child: Text(
                            'check against: ${q.checkableDetail}',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _sidePane(Claim claim) {
    final asked = _interview.followUpsFor(claim.id);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(height: 130, child: _preview()),
        const SizedBox(height: 12),
        VerificationStatusCard(result: _latestVerification),
        if (_halted) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              border: Border.all(color: Colors.red.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Session halted: identity mismatch sustained.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
        const Divider(height: 28),
        Text('Follow-ups', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Raised by how the answer was written. Answering them is how the '
          'claim gets substantiated.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (asked.isEmpty)
          Text('None yet.', style: Theme.of(context).textTheme.bodySmall)
        else
          for (final a in asked) _followUpCard(claim, a),
      ],
    );
  }

  Widget _followUpCard(Claim claim, AskedFollowUp asked) {
    final key = '${claim.id}:${asked.followUp.observation}';
    final controller =
        _followUpControllers.putIfAbsent(key, TextEditingController.new);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(asked.followUp.question,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(asked.followUp.observation,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (asked.wasAnswered)
              Row(
                children: [
                  Icon(Icons.check_circle,
                      size: 16, color: Colors.green.shade700),
                  const SizedBox(width: 6),
                  Text('Answered',
                      style: TextStyle(
                          fontSize: 12, color: Colors.green.shade700)),
                ],
              )
            else ...[
              TextField(
                controller: controller,
                maxLines: 3,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'Answer in your own words…',
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    _interview.answerFollowUp(
                        claim.id, asked, controller.text);
                    setState(() {});
                  },
                  child: const Text('Submit'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    final camera = _camera;
    if (camera == null) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.error),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(8),
        child: Center(
          child: Text(
            _cameraError ?? 'Camera unavailable',
            style: const TextStyle(fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CameraPreview(camera),
    );
  }
}
