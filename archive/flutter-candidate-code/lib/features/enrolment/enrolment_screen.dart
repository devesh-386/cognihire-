import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/verification/face_engine.dart';
import 'enrolment_controller.dart';

/// Captures the candidate's reference face.
///
/// Everything the camera cannot do is stated plainly on screen. There is no
/// "virtual camera" fallback that renders a convincing scanner animation while
/// measuring nothing — the reference build had one, and it made a dead camera
/// look like a working one.
class EnrolmentScreen extends StatefulWidget {
  const EnrolmentScreen({super.key, required this.onEnrolled});

  /// Called with the successful capture once enrolment succeeds. Passes the
  /// whole outcome, not just the embedding, so the caller can record how good
  /// the reference itself was — a weak reference explains mismatches later.
  final void Function(EnrolmentCaptured capture) onEnrolled;

  @override
  State<EnrolmentScreen> createState() => _EnrolmentScreenState();
}

class _EnrolmentScreenState extends State<EnrolmentScreen> {
  CameraController? _camera;
  String? _cameraError;
  bool _initialising = true;
  bool _capturing = false;
  EnrolmentOutcome? _outcome;

  late final EnrolmentController _controller = EnrolmentController(
    engine: HttpFaceEngine(baseUrl: AppConfig.faceServiceUrl),
  );

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _cameraError = 'No camera found on this device.';
          _initialising = false;
        });
        return;
      }

      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();

      if (!mounted) return;
      setState(() {
        _camera = controller;
        _initialising = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraError = 'Camera unavailable: $e';
        _initialising = false;
      });
    }
  }

  @override
  void dispose() {
    // May already be null if enrolment succeeded and released it early.
    _camera?.dispose();
    _camera = null;
    super.dispose();
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _capturing) return;

    setState(() {
      _capturing = true;
      _outcome = null;
    });

    Uint8List? bytes;
    try {
      final shot = await camera.takePicture();
      bytes = await shot.readAsBytes();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _outcome = EnrolmentFailed('Could not capture frame: $e');
        _capturing = false;
      });
      return;
    }

    final outcome = await _controller.captureFrom(bytes);
    if (!mounted) return;

    setState(() {
      _outcome = outcome;
      _capturing = false;
    });

    if (outcome is EnrolmentCaptured) {
      // Release the camera BEFORE handing over. Navigation creates the next
      // screen before disposing this route, and a platform camera is a
      // single-owner resource — holding it here makes the session screen fail
      // with "camera with given device id already exists".
      await _releaseCamera();
      if (!mounted) return;
      widget.onEnrolled(outcome);
    }
  }

  Future<void> _releaseCamera() async {
    final camera = _camera;
    if (camera == null) return;
    if (mounted) setState(() => _camera = null);
    await camera.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Identity enrolment')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _preview()),
            const SizedBox(height: 16),
            if (_outcome != null) _outcomeBanner(_outcome!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _camera == null || _capturing ? null : _capture,
              icon: _capturing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.camera_alt),
              label: Text(_capturing ? 'Analysing…' : 'Capture reference face'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    if (_initialising) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_cameraError != null || _camera == null) {
      // Honest dead-end. No decorative scanner standing in for a real feed.
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(
              _cameraError ?? 'Camera unavailable',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Enrolment cannot proceed without a camera.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: CameraPreview(_camera!),
    );
  }

  Widget _outcomeBanner(EnrolmentOutcome outcome) {
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, Color colour, String title, List<String> lines) =
        switch (outcome) {
      EnrolmentCaptured(:final faceSize) => (
          Icons.check_circle,
          Colors.green.shade600,
          'Reference face enrolled',
          ['Face area $faceSize px'],
        ),
      EnrolmentRejected(:final reason, :final guidance) => (
          Icons.error_outline,
          Colors.orange.shade800,
          reason,
          guidance,
        ),
      EnrolmentFailed(:final reason) => (
          Icons.cloud_off,
          scheme.error,
          'Enrolment could not run',
          [reason],
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: colour)),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('• $line',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
