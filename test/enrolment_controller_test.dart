import 'dart:typed_data';

import 'package:cognihire/core/verification/face_engine.dart';
import 'package:cognihire/features/enrolment/enrolment_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEngine implements FaceEngine {
  FaceFrameAnalysis? next;
  Object? throwThis;

  @override
  Future<FaceFrameAnalysis> analyseFrame(Uint8List bytes) async {
    if (throwThis != null) throw throwThis!;
    return next ??
        const FaceFrameAnalysis(faceDetected: false, embedding: null);
  }
}

void main() {
  late _FakeEngine engine;
  late EnrolmentController controller;

  setUp(() {
    engine = _FakeEngine();
    controller = EnrolmentController(engine: engine, minFaceSize: 15000);
  });

  final frame = Uint8List.fromList([1, 2, 3]);
  final embedding = List<double>.generate(512, (i) => i * 0.01);

  test('null frame fails rather than enrolling nothing', () async {
    expect(await controller.captureFrom(null), isA<EnrolmentFailed>());
  });

  test('engine unavailable fails, never silently enrols', () async {
    engine.throwThis = const FaceEngineUnavailable('offline');
    final r = await controller.captureFrom(frame);
    expect(r, isA<EnrolmentFailed>());
  });

  test('no face is rejected with actionable guidance', () async {
    engine.next = const FaceFrameAnalysis(faceDetected: false, embedding: null);
    final r = await controller.captureFrom(frame);

    expect(r, isA<EnrolmentRejected>());
    expect((r as EnrolmentRejected).guidance, isNotEmpty);
  });

  test('face detected but no embedding is a failure, not an enrolment',
      () async {
    engine.next = const FaceFrameAnalysis(faceDetected: true, embedding: null);
    expect(await controller.captureFrom(frame), isA<EnrolmentFailed>());
  });

  test('face too small is rejected to avoid a weak reference', () async {
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: embedding,
      faceSize: 5000,
      recommendations: const ['Improve lighting'],
    );
    final r = await controller.captureFrom(frame);

    expect(r, isA<EnrolmentRejected>());
    final rejected = r as EnrolmentRejected;
    expect(rejected.guidance, contains('Move closer to the camera'));
    expect(rejected.guidance, contains('Improve lighting'));
  });

  test('good capture enrols', () async {
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: embedding,
      faceSize: 40000,
    );
    final r = await controller.captureFrom(frame);

    expect(r, isA<EnrolmentCaptured>());
    expect((r as EnrolmentCaptured).embedding.length, 512);
  });
}
