import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'claim.dart';
import 'claim_extractor.dart';
import 'heuristic_claim_extractor.dart';

/// Claim extraction via the AI Gateway (`service/ai_gateway.py`, exposed at
/// `POST {AppConfig.aiGatewayUrl}/extract-claims`).
///
/// This client is deliberately thin. It does not know whether the gateway
/// used OpenAI or Ollama, what the prompt said, or what model answered — it
/// sends a document and a source label, and trusts the `kind` the gateway
/// reports back. No API key, base URL for a model provider, or prompt text
/// exists anywhere in this file, because none of that belongs in a client
/// that ships to a candidate's browser or device.
///
/// Failure handling matches [OllamaClaimExtractor]'s contract: never throw,
/// degrade to [HeuristicClaimExtractor] and say why.
class GatewayClaimExtractor implements ClaimExtractor {
  GatewayClaimExtractor({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    this.timeout = const Duration(seconds: 30),
    this.fallback = const HeuristicClaimExtractor(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;
  final HeuristicClaimExtractor fallback;

  @override
  Future<ClaimExtraction> extract(String documentText,
      {required String source}) async {
    if (documentText.trim().isEmpty) {
      return const ClaimExtraction(claims: [], kind: ExtractorKind.hostedLlm);
    }

    late final Map<String, dynamic> body;
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/extract-claims'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'document_text': documentText,
              'source': source,
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        return _degrade(documentText, source,
            'the AI gateway answered HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _degrade(
            documentText, source, 'the AI gateway returned an unexpected shape');
      }
      body = decoded;
    } on TimeoutException {
      return _degrade(documentText, source,
          'the AI gateway did not answer within ${timeout.inSeconds}s');
    } catch (e) {
      return _degrade(documentText, source, 'could not reach the AI gateway ($e)');
    }

    final kind = switch (body['kind']) {
      'hosted_llm' => ExtractorKind.hostedLlm,
      'local_llm' => ExtractorKind.localLlm,
      _ => ExtractorKind.heuristicRule,
    };

    final rawClaims = body['claims'];
    final claims = rawClaims is List
        ? rawClaims
            .whereType<Map<String, dynamic>>()
            .map((c) => Claim(
                  id: c['id'] as String? ?? '',
                  text: c['text'] as String? ?? '',
                  source: c['source'] as String? ?? source,
                  skill: c['skill'] as String?,
                ))
            .where((c) => c.text.isNotEmpty)
            .toList()
        : <Claim>[];

    final rejected = body['rejected_ungrounded'];

    return ClaimExtraction(
      claims: claims,
      kind: kind,
      degradedReason: body['degraded_reason'] as String?,
      rejectedUngrounded:
          rejected is List ? rejected.whereType<String>().toList() : const [],
    );
  }

  ClaimExtraction _degrade(String documentText, String source, String reason) {
    return ClaimExtraction(
      claims: fallback.extract(documentText, source: source),
      kind: ExtractorKind.heuristicRule,
      degradedReason: reason,
    );
  }
}
