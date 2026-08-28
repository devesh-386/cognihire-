/// Thin client for `GET {AppConfig.aiGatewayUrl}/candidates/{id}/resume`.
///
/// Same reason [InterviewReportClient] goes through the gateway rather than
/// reading Supabase directly: the résumé lives in a private storage bucket
/// with no client-side read policy, by design (Ticket 11 — nothing shipped in
/// a Flutter web bundle can hold a secret that keeps working, so the
/// service-role key that can read it never leaves the backend process).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/gateway_headers.dart';
import '../config.dart';

/// A candidate's uploaded résumé, or the absence of one — see
/// [CandidateResumeClient.fetch].
class CandidateResume {
  const CandidateResume({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class CandidateResumeClient {
  CandidateResumeClient({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  /// Returns the résumé, or null when this candidate has none on file (the
  /// gateway answers 404 for that — see the endpoint's own doc comment in
  /// `service/main.py`). Null is not an error here: most candidates in an
  /// early pipeline stage simply have not uploaded one yet.
  Future<CandidateResume?> fetch(String candidateId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/candidates/$candidateId/resume'),
      headers: gatewayAuthHeaders(),
    ).timeout(timeout);

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('the gateway answered HTTP ${response.statusCode} for '
          "candidate $candidateId's résumé");
    }

    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="([^"]+)"').firstMatch(disposition);
    return CandidateResume(
      bytes: response.bodyBytes,
      filename: match?.group(1) ?? '$candidateId-resume.pdf',
    );
  }
}
