import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/claims/claim.dart';
import '../../core/config.dart';
import '../../core/design/app_theme.dart';
import '../../core/integrity/integrity_tracker.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/verification/face_engine.dart';
import '../../core/verification/verification_result.dart';
import '../../core/verification/verification_session.dart';
import '../audit/claim_audit_screen.dart';
import '../session/verification_status_card.dart';
import 'interview_voice_controller.dart';
import 'live_interview_screen.dart';

/// The real, verified interview: [LiveInterviewScreen]'s live voice
/// conversation, running underneath a continuous face-verification camera
/// loop for the life of the session — identity is re-checked throughout, not
/// just once at login.
///
/// This is what `/candidate/interview` mounts. It replaced an earlier
/// typing-form screen that ran the same camera loop but asked questions from
/// a scripted ladder rather than a live model; that screen is retired, not
/// merged — this one covers everything it did: enrolment is still a
/// precondition (a session cannot start without an enrolled reference), the
/// camera still runs for the life of the session, and the audit still
/// reports gaps honestly rather than a fabricated pass.
class VoiceInterviewScreen extends StatefulWidget {
  const VoiceInterviewScreen({
    super.key,
    required this.claims,
    required this.enrolledEmbedding,
    this.jobRequirements = const [],
    this.store,
    this.candidateLabel = 'Unlabelled session',
    this.researchConsentGranted,
  });

  final List<Claim> claims;

  /// The reference captured at enrolment. Required — a session cannot start
  /// without one.
  final List<double> enrolledEmbedding;

  /// The target role's required skills, if one was picked — passed straight
  /// through to [LiveTurnClient] so `newtopic` turns can open a role
  /// requirement, not only a resume claim. Empty means the session covers
  /// claims only, same as before role targeting existed.
  final List<String> jobRequirements;

  final AuditStore? store;
  final String candidateLabel;

  /// See [InterviewVoiceController.new]'s parameter of the same name.
  final bool? researchConsentGranted;

  @override
  State<VoiceInterviewScreen> createState() => _VoiceInterviewScreenState();
}

class _VoiceInterviewScreenState extends State<VoiceInterviewScreen> {
  late final InterviewVoiceController _interview = InterviewVoiceController(
    claims: widget.claims,
    jobRequirements: widget.jobRequirements,
    researchConsentGranted: widget.researchConsentGranted,
  );
  final _tracker = IntegrityTracker();

  CameraController? _camera;
  String? _cameraError;
  bool _grabbing = false;
  VerificationSession? _verification;
  VerificationResult? _latestVerification;
  bool _halted = false;
  bool _starting = true;
  bool _warm = false;

  bool _finishing = false;

  @override
  void initState() {
    super.initState();
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

    // Runs alongside the camera/verification setup above rather than after
    // it — a candidate should not wait through both a cold model load and a
    // camera init back to back when neither depends on the other finishing
    // first.
    final results = await Future.wait([session.start(), _interview.warmUp()]);
    final warm = results[1] as bool;

    if (!mounted) return;
    setState(() {
      _starting = false;
      _warm = warm;
    });

    if (widget.claims.isNotEmpty) {
      _interview.openWithQuestion(_openingQuestionFor(widget.claims.first));
    }
  }

  /// A plain, honest opener — not a model call. The live model takes over
  /// from the candidate's first answer onward; asking it to also invent the
  /// very first question would mean sending it something before there is any
  /// TRANSCRIPT to ground a `quote` in.
  static String _openingQuestionFor(Claim claim) =>
      'Tell me about this: ${claim.text}';

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

  /// Ends the session, saves the audit, then shows it either way — even when
  /// the save itself failed, because the reviewer is looking at a real
  /// session that simply was not written to disk, and needs to know that
  /// before closing the window.
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
    _verification?.dispose();
    _camera?.dispose();
    _interview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_starting) {
      return const Scaffold(
        backgroundColor: Color(0xFF17140F),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Starting the camera and waking up the interviewer…',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (widget.claims.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('No claims to examine.')),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish());
      },
      child: LiveInterviewScreen(
        controller: _interview,
        identityOverlay: _identityOverlay(),
      ),
    );
  }

  Widget _identityOverlay() {
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 100,
            height: 72,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _cameraPreview(),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          SizedBox(
            width: 160,
            child: VerificationStatusCard(result: _latestVerification),
          ),
          if (_halted)
            Container(
              margin: const EdgeInsets.only(top: Spacing.xs),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                border: Border.all(color: Colors.red.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Session halted: identity mismatch sustained.',
                style: TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          if (!_warm)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                "Couldn't reach the local model — the scripted question bank "
                'will fill in if needed.',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade200),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cameraPreview() {
    final camera = _camera;
    if (camera == null) {
      return Container(
        color: Colors.black45,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(4),
        child: Text(
          _cameraError ?? 'Camera unavailable',
          style: const TextStyle(fontSize: 9, color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      );
    }
    return CameraPreview(camera);
  }
}
