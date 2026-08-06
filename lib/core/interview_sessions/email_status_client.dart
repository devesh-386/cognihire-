/// Thin client for Ticket 21's email-status endpoints — same "caller, not
/// source of truth" rule as [InterviewCodeClient]: what counts as sent,
/// failed, or due for retry all lives in `service/notifications/`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class EmailDeliveryStatus {
  const EmailDeliveryStatus({
    required this.emailType,
    required this.status,
    required this.attempts,
    this.lastError,
    this.sentAt,
  });

  /// 'invitation' | 'reminder_1h' | 'reminder_30m'.
  final String emailType;

  /// 'pending' | 'sent' | 'failed'.
  final String status;
  final int attempts;
  final String? lastError;
  final DateTime? sentAt;

  factory EmailDeliveryStatus.fromJson(Map<String, dynamic> json) {
    final sentAt = json['sent_at'] as String?;
    return EmailDeliveryStatus(
      emailType: json['email_type'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastError: json['last_error'] as String?,
      sentAt: sentAt == null ? null : DateTime.parse(sentAt),
    );
  }
}

class EmailStatusClient {
  EmailStatusClient({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<List<EmailDeliveryStatus>> listForCode(String codeId) async {
    final response = await _client
        .get(Uri.parse('$baseUrl/interview-codes/$codeId/emails'))
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError(
        'the gateway answered HTTP ${response.statusCode} listing email status',
      );
    }
    final decoded = jsonDecode(response.body);
    final emails = decoded is Map<String, dynamic> ? decoded['emails'] : null;
    if (emails is! List) return const [];
    return emails
        .whereType<Map<String, dynamic>>()
        .map(EmailDeliveryStatus.fromJson)
        .toList();
  }

  Future<EmailDeliveryStatus> resendInvitation(String codeId) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/interview-codes/resend-invitation'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code_id': codeId}),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError(
        'the gateway answered HTTP ${response.statusCode} resending the invitation',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('the gateway returned an unexpected shape');
    }
    return EmailDeliveryStatus.fromJson(decoded);
  }
}
