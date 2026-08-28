/// Thin client for `GET {AppConfig.aiGatewayUrl}/interview/report/{id}`.
///
/// Same "thin, dumb client" rule as [GatewayClaimExtractor]: this file knows
/// one URL and one response shape, and nothing about how the report was
/// assembled (`ai/evidence_linking.py` + `ai/report_generation.py`, no model
/// call). It reads Supabase-persisted state through the gateway rather than
/// directly, unlike [SupabaseInterviewSessionStore] — the report is
/// synthesized server-side (last-attempt-per-topic, rejected-topic surfacing)
/// rather than being a straight table read, so it belongs behind the gateway
/// like every other AI-pipeline output.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/gateway_headers.dart';
import '../config.dart';

class InterviewTopicReport {
  const InterviewTopicReport({
    required this.topic,
    required this.claimText,
    required this.objective,
    required this.outcome,
    required this.confidence,
    required this.evidenceQuote,
    required this.reason,
    required this.attempts,
  });

  final String topic;
  final String claimText;
  final String objective;
  final String? outcome; // "supported" | "not_supported" | null
  final double? confidence;
  final String? evidenceQuote;
  final String? reason;
  final int attempts;

  factory InterviewTopicReport.fromJson(Map<String, dynamic> json) {
    return InterviewTopicReport(
      topic: json['topic'] as String? ?? '',
      claimText: json['claim_text'] as String? ?? '',
      objective: json['objective'] as String? ?? '',
      outcome: json['outcome'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble(),
      evidenceQuote: json['evidence_quote'] as String?,
      reason: json['reason'] as String?,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

class InterviewReport {
  const InterviewReport({
    required this.roleTitle,
    required this.status,
    required this.completionPercent,
    required this.topics,
    required this.rejectedUngroundedTopics,
  });

  final String roleTitle;
  final String status;
  final int completionPercent;
  final List<InterviewTopicReport> topics;
  final List<String> rejectedUngroundedTopics;

  factory InterviewReport.fromJson(Map<String, dynamic> json) {
    final rawTopics = json['topics'];
    final rawRejected = json['rejected_ungrounded_topics'];
    return InterviewReport(
      roleTitle: json['role_title'] as String? ?? '',
      status: json['status'] as String? ?? '',
      completionPercent: (json['completion_percent'] as num?)?.toInt() ?? 0,
      topics: rawTopics is List
          ? rawTopics
              .whereType<Map<String, dynamic>>()
              .map(InterviewTopicReport.fromJson)
              .toList()
          : const [],
      rejectedUngroundedTopics:
          rawRejected is List ? rawRejected.whereType<String>().toList() : const [],
    );
  }
}

class InterviewReportClient {
  InterviewReportClient({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<InterviewReport> fetch(String sessionId) async {
    final response = await _client
        .get(
          Uri.parse('$baseUrl/interview/report/$sessionId'),
          headers: gatewayAuthHeaders(),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError('the gateway answered HTTP ${response.statusCode} for '
          'the report on session $sessionId');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('the gateway returned an unexpected shape for the report');
    }
    return InterviewReport.fromJson(decoded);
  }
}
