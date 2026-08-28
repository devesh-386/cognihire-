/// Regression test for recruiter gateway calls that shipped without auth.
///
/// `service/main.py` resolves the caller's organisation from a bearer token on
/// every recruiter route. `InterviewReportClient` and `EmailStatusClient` sent
/// no `Authorization` header at all, so those routes answered 401 for every
/// recruiter, always. It surfaced on the session report screen as three
/// simultaneous failures — résumé, report, and email status — reading as
/// "the gateway answered HTTP 401" rather than "you are signed out".
///
/// The bug was invisible to the existing tests because they only asserted on
/// decoding a 200 body: a client that never authenticates still parses a
/// stubbed 200 perfectly. These tests assert on the *request* instead.
///
/// Supabase is not initialised here, so `gatewayAuthHeaders()` cannot read a
/// live session — `Supabase.instance` throws before a bootstrap. That is the
/// signed-out path, and it is the half worth pinning: the client must still
/// issue the request with no Authorization header rather than crash, so the
/// user sees the gateway's own 401 instead of an unhandled exception. The
/// signed-in half is covered by the header being built in exactly one place
/// (`gatewayAuthHeaders`), which `candidate_resume_client` already exercised
/// against a real session before this refactor.
library;

import 'dart:convert';

import 'package:cognihire/core/interview_sessions/email_status_client.dart';
import 'package:cognihire/core/interview_sessions/interview_report_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('recruiter gateway clients', () {
    test('the report client sends its request to the report route', () async {
      Uri? seen;
      final client = InterviewReportClient(
        baseUrl: 'https://gateway.test',
        client: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode({
              'role_title': 'Backend Engineer',
              'status': 'complete',
              'completion_percent': 100,
              'topics': <dynamic>[],
              'rejected_ungrounded_topics': <dynamic>[],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final report = await client.fetch('session-1');

      expect(seen.toString(),
          'https://gateway.test/interview/report/session-1');
      expect(report.roleTitle, 'Backend Engineer');
    });

    test('the email status client sends its request to the emails route',
        () async {
      Uri? seen;
      final client = EmailStatusClient(
        baseUrl: 'https://gateway.test',
        client: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode({'emails': <dynamic>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final emails = await client.listForCode('code-1');

      expect(seen.toString(),
          'https://gateway.test/interview-codes/code-1/emails');
      expect(emails, isEmpty);
    });

    test('a 401 surfaces as an error rather than an empty report', () async {
      final client = InterviewReportClient(
        baseUrl: 'https://gateway.test',
        client: MockClient((_) async => http.Response('unauthorized', 401)),
      );

      expect(
        () => client.fetch('session-1'),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('401'))),
      );
    });
  });
}
