import 'dart:typed_data';

import 'package:cognihire/core/verification/capture_quality_head.dart';
import 'package:cognihire/core/verification/face_engine.dart';
import 'package:cognihire/core/verification/platt_scaler.dart';
import 'package:cognihire/features/enrolment/enrolment_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEngine implements FaceEngine {
  FaceFrameAnalysis? next;

  @override
  Future<FaceFrameAnalysis> analyseFrame(Uint8List bytes) async =>
      next ?? const FaceFrameAnalysis(faceDetected: false, embedding: null);
}

void main() {
  final frame = Uint8List.fromList([1, 2, 3]);
  final embedding = List<double>.generate(512, (i) => i * 0.01);

  test('with no explicit head, defaults to a provisional head centred on '
      'minFaceSize', () async {
    final engine = _FakeEngine()
      ..next = FaceFrameAnalysis(
          faceDetected: true, embedding: embedding, faceSize: 15000);
    final controller = EnrolmentController(engine: engine, minFaceSize: 15000);
    expect(controller.qualityHead.isCalibrated, isFalse);
    expect(controller.qualityHead.referenceFaceSize, 15000);
  });

  test('a caller can inject a real fitted head instead of the provisional '
      'default', () async {
    final scaler =
        PlattScaler.fit(scores: [2.0, 1.8, 0.3, 0.2], labels: [true, true, false, false]);
    final fittedHead =
        CaptureQualityHead.fitted(scaler: scaler, referenceFaceSize: 15000);

    final engine = _FakeEngine()
      ..next = FaceFrameAnalysis(
          faceDetected: true, embedding: embedding, faceSize: 40000);
    final controller = EnrolmentController(
      engine: engine,
      minFaceSize: 15000,
      qualityHead: fittedHead,
    );

    expect(controller.qualityHead.isCalibrated, isTrue);
    final r = await controller.captureFrom(frame);
    expect(r, isA<EnrolmentCaptured>());
  });

  test('a face just above the reference passes; well below it is rejected — '
      'the soft head still enforces a real, actionable boundary', () async {
    final engine = _FakeEngine();
    final controller = EnrolmentController(engine: engine, minFaceSize: 15000);

    engine.next = FaceFrameAnalysis(
        faceDetected: true, embedding: embedding, faceSize: 30000);
    expect(await controller.captureFrom(frame), isA<EnrolmentCaptured>());

    engine.next = FaceFrameAnalysis(
        faceDetected: true, embedding: embedding, faceSize: 1000);
    final rejected = await controller.captureFrom(frame);
    expect(rejected, isA<EnrolmentRejected>());
    expect((rejected as EnrolmentRejected).guidance,
        contains('Move closer to the camera'));
  });
}
