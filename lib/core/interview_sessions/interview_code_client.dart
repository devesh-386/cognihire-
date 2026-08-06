/// Thin client for `POST {AppConfig.aiGatewayUrl}/interview-codes/generate`.
///
/// The HR desktop is explicitly a caller here, never a source of truth —
/// code generation, the code alphabet, expiry math, and attempt limits all
/// live in `service/session/interview_codes.py`. This file exists only to
/// send the request and parse the response, same as [GatewayClaimExtractor].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class GeneratedInterviewCode {
  const GeneratedInterviewCode({
    required this.id,
    required this.code,
    required this.roleTitle,
    required this.expiresAt,
    required this.maxAttempts,
  });

  final String id;
  final String code;
  final String roleTitle;
  final DateTime expiresAt;
  final int maxAttempts;

  factory GeneratedInterviewCode.fromJson(Map<String, dynamic> json) {
    return GeneratedInterviewCode(
      id: json['id'] as String? ?? '',
      code: json['code'] as String? ?? '',
      roleTitle: json['role_title'] as String? ?? '',
      expiresAt: DateTime.parse(json['expires_at'] as String),
      maxAttempts: (json['max_attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

class InterviewCodeClient {
  InterviewCodeClient({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<GeneratedInterviewCode> generate({
    required String candidateId,
    required String organizationId,
    required String roleTitle,
    int maxAttempts = 3,
    int expiresInHours = 72,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/interview-codes/generate'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'candidate_id': candidateId,
            'organization_id': organizationId,
            'role_title': roleTitle,
            'max_attempts': maxAttempts,
            'expires_in_hours': expiresInHours,
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError('the gateway answered HTTP ${response.statusCode} '
          'generating an interview code');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('the gateway returned an unexpected shape');
    }
    return GeneratedInterviewCode.fromJson(decoded);
  }
}
