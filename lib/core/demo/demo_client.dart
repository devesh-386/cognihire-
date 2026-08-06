/// Thin client for Ticket 19's demo environment endpoints —
/// `POST {AppConfig.aiGatewayUrl}/demo/seed` and `/demo/reset`.
///
/// Same "thin, dumb caller" rule as [InterviewCodeClient]: everything about
/// what gets seeded (the org name, the roles, the five candidate profiles,
/// how reset restores state) lives in `service/demo/`. This file only sends
/// the request and reads back a summary to show in the HR desktop.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class DemoEnvironmentResult {
  const DemoEnvironmentResult({
    required this.organizationName,
    required this.hrEmail,
    required this.hrPassword,
    required this.roleCount,
    required this.candidateCount,
    required this.seededAt,
  });

  final String organizationName;
  final String hrEmail;
  final String hrPassword;
  final int roleCount;
  final int candidateCount;

  /// Stamped client-side when the response arrives — the backend doesn't
  /// return a seeded-at timestamp, and "just now" is all "Last seeded"
  /// needs to say.
  final DateTime seededAt;

  factory DemoEnvironmentResult.fromJson(Map<String, dynamic> json) {
    final hrLogin = json['hr_login'] as Map<String, dynamic>? ?? const {};
    return DemoEnvironmentResult(
      organizationName: json['organization_name'] as String? ?? '',
      hrEmail: hrLogin['email'] as String? ?? '',
      hrPassword: hrLogin['password'] as String? ?? '',
      roleCount: (json['roles'] as List?)?.length ?? 0,
      candidateCount: (json['candidates'] as List?)?.length ?? 0,
      seededAt: DateTime.now(),
    );
  }
}

class DemoClient {
  DemoClient({
    http.Client? client,
    this.baseUrl = AppConfig.aiGatewayUrl,
    // Seeding runs five candidates through the real resume pipeline
    // sequentially — generous enough that a cold-start gateway doesn't
    // time out mid-seed.
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<DemoEnvironmentResult> seed() => _post('/demo/seed');

  Future<DemoEnvironmentResult> reset() => _post('/demo/reset');

  Future<DemoEnvironmentResult> _post(String path) async {
    final response = await _client
        .post(Uri.parse('$baseUrl$path'))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError(
        'the gateway answered HTTP ${response.statusCode} for $path',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('the gateway returned an unexpected shape');
    }
    if (decoded['status'] == 'no_demo_environment') {
      throw StateError(
        decoded['message'] as String? ??
            'No demo environment exists yet — seed it first.',
      );
    }
    return DemoEnvironmentResult.fromJson(decoded);
  }
}
