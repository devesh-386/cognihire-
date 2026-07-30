import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// What a face-recognition backend returns for one frame.
///
/// [embedding] is null whenever no embedding could be produced — no face in
/// frame, engine unavailable, bad image. It is never a zero-vector or a
/// placeholder, because downstream code must be able to tell "no measurement"
/// from "a measurement that happens to be low".
class FaceFrameAnalysis {
  const FaceFrameAnalysis({
    required this.faceDetected,
    required this.embedding,
    this.faceSize = 0,
    this.brightness = 0,
    this.recommendations = const [],
  });

  final bool faceDetected;
  final List<double>? embedding;
  final int faceSize;
  final double brightness;
  final List<String> recommendations;

  bool get hasEmbedding => embedding != null && embedding!.isNotEmpty;
}

/// Thrown when the engine could not be reached or could not process the frame.
/// Callers translate this into an `Unchecked` result — never into a score.
class FaceEngineUnavailable implements Exception {
  const FaceEngineUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'FaceEngineUnavailable: $reason';
}

/// Boundary for face analysis. Kept abstract so the verification loop can be
/// tested without a network, and so the backend can be swapped later.
abstract class FaceEngine {
  /// Analyse a single JPEG frame.
  ///
  /// Throws [FaceEngineUnavailable] if the analysis could not be performed.
  /// Returns a result with `embedding == null` if it ran but found no face.
  Future<FaceFrameAnalysis> analyseFrame(Uint8List jpegBytes);
}

/// Talks to the Python face service over HTTP.
///
/// Deliberately strict about the response: any missing or malformed field is
/// treated as engine unavailability rather than being defaulted. Defaulting a
/// missing `embedding_available` to `true` is exactly how the reference build
/// ended up reporting a 98.7% match against nothing.
class HttpFaceEngine implements FaceEngine {
  HttpFaceEngine({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<FaceFrameAnalysis> analyseFrame(Uint8List jpegBytes) async {
    final uri = Uri.parse('$baseUrl/face/analyze');

    late http.StreamedResponse response;
    try {
      final request = http.MultipartRequest('POST', uri)
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          jpegBytes,
          filename: 'frame.jpg',
        ));
      response = await _client.send(request).timeout(timeout);
    } catch (e) {
      throw FaceEngineUnavailable('request failed: $e');
    }

    if (response.statusCode != 200) {
      throw FaceEngineUnavailable('HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await response.stream.bytesToString())
          as Map<String, dynamic>;
    } catch (e) {
      throw FaceEngineUnavailable('malformed response: $e');
    }

    // The engine must state explicitly whether it produced an embedding.
    // Absence of the field is ambiguity, and ambiguity is unavailability.
    final available = body['embedding_available'];
    if (available is! bool) {
      throw FaceEngineUnavailable('response omitted embedding_available');
    }

    List<double>? embedding;
    if (available) {
      final raw = body['embedding'];
      if (raw is List && raw.isNotEmpty) {
        embedding = raw.map((v) => (v as num).toDouble()).toList();
      } else {
        // Claimed an embedding but did not supply one — do not invent it.
        throw FaceEngineUnavailable(
          'engine reported an embedding but returned none',
        );
      }
    }

    return FaceFrameAnalysis(
      faceDetected: body['face_detected'] as bool? ?? false,
      embedding: embedding,
      faceSize: (body['face_size'] as num?)?.toInt() ?? 0,
      brightness: (body['brightness'] as num?)?.toDouble() ?? 0,
      recommendations: (body['recommendations'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }
}
