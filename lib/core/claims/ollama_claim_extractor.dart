import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'claim.dart';
import 'claim_extractor.dart';
import 'heuristic_claim_extractor.dart';

/// Claim extraction by a language model running **locally** via Ollama.
///
/// ## Why local, and why that is a feature rather than a budget decision
///
/// The resume never leaves the machine. For a system whose pitch is provenance
/// and honest handling of a person's own words, "your document was not uploaded
/// anywhere" is a claim this project can actually make and defend — and it
/// removes the demo's dependence on a venue network, a rate limit, and a
/// third-party key all at once.
///
/// ## The grounding rule — the load-bearing part of this class
///
/// [Claim] documents that a claim is the candidate's own assertion: "if we did
/// not read it in their own words, it is not a claim". A language model asked to
/// extract will sometimes paraphrase, tidy, or invent — and a *fabricated* claim
/// attributed to a candidate is the single worst output this system could
/// produce. So every string the model returns is checked for presence in the
/// source document, and anything not found there is **discarded** and reported
/// in [ClaimExtraction.rejectedUngrounded]. The model is allowed to *select*
/// text; it is never allowed to *author* it.
///
/// ## Failure is degradation, never a crash and never a guess
///
/// Ollama not running, a timeout, malformed JSON, an HTTP error — every one of
/// these falls back to [HeuristicClaimExtractor] with
/// [ClaimExtraction.degradedReason] set, so the UI can say which mechanism
/// actually ran. Nothing here throws, and nothing invents claims to fill a gap.
class OllamaClaimExtractor implements ClaimExtractor {
  OllamaClaimExtractor({
    http.Client? client,
    this.baseUrl = AppConfig.ollamaBaseUrl,
    this.model = AppConfig.ollamaModel,
    this.timeout = const Duration(seconds: 90),
    this.maxCandidates = 8,
    this.fallback = const HeuristicClaimExtractor(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final String model;

  /// Generous by design: a 7B model sharing a laptop with the face service can
  /// take tens of seconds. Extraction runs once, before the interview starts,
  /// so a slow answer costs nothing that matters.
  final Duration timeout;

  final int maxCandidates;

  /// Used whenever the model cannot be reached or cannot be trusted. Rules are
  /// a worse extractor but an honest one, and the result says which ran.
  final HeuristicClaimExtractor fallback;

  /// Bullet markers the model carries over when it copies a resume line
  /// verbatim. Matches [HeuristicClaimExtractor]'s set so both extractors
  /// present claims the same way.
  static final RegExp _bulletPrefix = RegExp(r'^[\-\*•·▪‣◦]\s*');

  static const String _instruction = '''
You extract claims a person made about themselves from their own document.

Rules:
1. Copy each claim EXACTLY as it appears in the document. Do not reword, fix
   grammar, expand abbreviations, or merge lines. Verbatim only.
2. A claim is an assertion about what this person did, built, used, led, or
   achieved. Skip headings, contact details, dates alone, and school names.
3. If the document contains no such assertions, return an empty list.
4. Never write a claim that is not present in the document.

Reply with JSON only, in this exact shape:
{"claims": [{"text": "<verbatim line from the document>", "skill": "<one technology named in that line, or null>"}]}
''';

  /// Load the model into memory ahead of time, returning whether it is ready.
  ///
  /// Measured on the development machine: a cold call costs ~40s, almost all of
  /// it loading weights, while a warm one costs ~2.6s. That gap is the
  /// difference between a demo that looks broken and one that looks instant, so
  /// this is worth calling at app start rather than discovering the cost when a
  /// candidate uploads their resume.
  ///
  /// Never throws — a false return means "not available", which is a fact the
  /// caller may want to show, not an error to handle.
  Future<bool> warmUp() async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/chat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'messages': [
                {'role': 'user', 'content': 'ok'},
              ],
              'options': {'num_predict': 1},
            }),
          )
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ClaimExtraction> extract(String documentText,
      {required String source}) async {
    // No document means no claims. Asking a model about nothing wastes tens of
    // seconds to be told what we already know.
    if (documentText.trim().isEmpty) {
      return const ClaimExtraction(claims: [], kind: ExtractorKind.localLlm);
    }

    late final String content;
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/chat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'format': 'json',
              'options': {'temperature': 0},
              'messages': [
                {'role': 'system', 'content': _instruction},
                {'role': 'user', 'content': documentText},
              ],
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        return _degrade(documentText, source,
            'the local model service answered HTTP ${response.statusCode}');
      }

      final envelope = jsonDecode(response.body);
      final message = envelope is Map ? envelope['message'] : null;
      final text = message is Map ? message['content'] : null;
      if (text is! String || text.trim().isEmpty) {
        return _degrade(documentText, source,
            'the local model returned no content');
      }
      content = text;
    } on TimeoutException {
      return _degrade(documentText, source,
          'the local model did not answer within ${timeout.inSeconds}s');
    } catch (e) {
      // Connection refused is the expected case here: Ollama simply is not
      // running. Everything else unexpected lands in the same honest place.
      return _degrade(
          documentText, source, 'could not reach the local model service ($e)');
    }

    final List<dynamic> raw;
    try {
      final parsed = jsonDecode(content);
      final claims = parsed is Map ? parsed['claims'] : null;
      if (claims is! List) {
        return _degrade(documentText, source,
            'the local model did not return a claims list');
      }
      raw = claims;
    } catch (_) {
      return _degrade(
          documentText, source, 'the local model returned malformed JSON');
    }

    final claims = <Claim>[];
    final rejected = <String>[];
    final seen = <String>{};

    for (final entry in raw) {
      if (claims.length >= maxCandidates) break;
      if (entry is! Map) continue;

      final text = entry['text'];
      if (text is! String) continue;
      // The model copies the line verbatim, which for a resume usually means it
      // brings the bullet marker with it. Stripping it is presentation, not
      // rewording — and it happens *before* the grounding check so the check
      // still runs against the candidate's own words either way.
      final trimmed =
          text.trim().replaceFirst(_bulletPrefix, '').trim();
      if (trimmed.isEmpty) continue;
      if (!seen.add(trimmed.toLowerCase())) continue;

      // The grounding gate. Anything the model authored rather than selected is
      // refused here, no matter how plausible it reads.
      if (!_isGroundedIn(trimmed, documentText)) {
        rejected.add(trimmed);
        continue;
      }

      final skill = entry['skill'];
      claims.add(Claim(
        id: 'c${claims.length + 1}',
        text: trimmed,
        source: source,
        skill: skill is String && skill.trim().isNotEmpty && skill != 'null'
            ? skill.trim()
            : null,
      ));
    }

    return ClaimExtraction(
      claims: claims,
      kind: ExtractorKind.localLlm,
      rejectedUngrounded: rejected,
    );
  }

  /// True when [candidate] genuinely appears in [document].
  ///
  /// Whitespace is collapsed and case ignored on both sides, because a model
  /// re-wrapping a line or changing a bullet's spacing has not changed the
  /// person's words. Nothing beyond that is forgiven: no fuzzy matching, no
  /// token overlap threshold, no "close enough". A looser rule here would
  /// re-open exactly the hole this gate exists to close.
  static bool _isGroundedIn(String candidate, String document) {
    String normalise(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalise(document).contains(normalise(candidate));
  }

  ClaimExtraction _degrade(String documentText, String source, String reason) {
    return ClaimExtraction(
      claims: fallback.extract(documentText, source: source),
      kind: ExtractorKind.heuristicRule,
      degradedReason: reason,
    );
  }
}
