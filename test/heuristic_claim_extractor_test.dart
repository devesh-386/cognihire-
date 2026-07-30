import 'package:cognihire/core/claims/heuristic_claim_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const extractor = HeuristicClaimExtractor();

  group('basic extraction', () {
    test('empty text yields no candidates', () {
      expect(extractor.extract('', source: 'resume'), isEmpty);
    });

    test('whitespace-only text yields no candidates', () {
      expect(extractor.extract('   \n\n  \t  ', source: 'resume'), isEmpty);
    });

    test('a plausible bullet line becomes one candidate claim', () {
      final claims = extractor.extract(
        'Built and shipped a React dashboard used by 200+ staff',
        source: 'resume',
      );
      expect(claims, hasLength(1));
      expect(claims.first.text,
          'Built and shipped a React dashboard used by 200+ staff');
      expect(claims.first.source, 'resume');
    });

    test('candidate ids are stable and sequential', () {
      final claims = extractor.extract(
        'Built and shipped a React dashboard used by 200+ staff\n'
        'Optimised Postgres queries, cutting p95 latency by 60 percent',
        source: 'resume',
      );
      expect(claims.map((c) => c.id).toList(), ['c1', 'c2']);
    });
  });

  group('bullet-prefix and whitespace handling', () {
    test('common bullet characters are stripped from the front', () {
      final claims = extractor.extract(
        '- Built and shipped a React dashboard used by 200+ staff\n'
        '* Optimised Postgres queries across the reporting service\n'
        '• Led the migration off the legacy CI pipeline entirely',
        source: 'resume',
      );
      expect(claims.map((c) => c.text), [
        'Built and shipped a React dashboard used by 200+ staff',
        'Optimised Postgres queries across the reporting service',
        'Led the migration off the legacy CI pipeline entirely',
      ]);
    });

    test('surrounding whitespace on each line is trimmed', () {
      final claims = extractor.extract(
        '   Built and shipped a React dashboard used by 200+ staff   ',
        source: 'resume',
      );
      expect(claims.single.text,
          'Built and shipped a React dashboard used by 200+ staff');
    });
  });

  group('filtering out non-claim lines', () {
    test('blank lines between bullets are skipped, not turned into empty '
        'claims', () {
      final claims = extractor.extract(
        'Built and shipped a React dashboard used by 200+ staff\n'
        '\n'
        '\n'
        'Optimised Postgres queries across the reporting service',
        source: 'resume',
      );
      expect(claims, hasLength(2));
    });

    test('very short lines are filtered — too little to be a real claim', () {
      final claims = extractor.extract(
        'React\n'
        'Node.js\n'
        'Built and shipped a React dashboard used by 200+ staff',
        source: 'resume',
      );
      expect(claims, hasLength(1));
    });

    test('all-caps section headers are filtered', () {
      final claims = extractor.extract(
        'EXPERIENCE\n'
        'Built and shipped a React dashboard used by 200+ staff\n'
        'EDUCATION\n'
        'SKILLS',
        source: 'resume',
      );
      expect(claims, hasLength(1));
    });

    test('a line that is only an email address is filtered', () {
      final claims = extractor.extract(
        'alice.nguyen@example.com\n'
        'Built and shipped a React dashboard used by 200+ staff',
        source: 'resume',
      );
      expect(claims, hasLength(1));
    });

    test('exact duplicate lines are not turned into duplicate claims', () {
      final claims = extractor.extract(
        'Built and shipped a React dashboard used by 200+ staff\n'
        'Built and shipped a React dashboard used by 200+ staff',
        source: 'resume',
      );
      expect(claims, hasLength(1));
    });
  });

  group('skill tagging — best-effort keyword match, never invented', () {
    test('a recognised skill keyword present in the line is tagged', () {
      final claims = extractor.extract(
        'Built and shipped a React dashboard used by 200+ staff',
        source: 'resume',
      );
      expect(claims.single.skill, 'React');
    });

    test('matching is case-insensitive but the tag uses the canonical form',
        () {
      final claims = extractor.extract(
        'built and shipped a REACT dashboard for the ops team',
        source: 'resume',
      );
      expect(claims.single.skill, 'React');
    });

    test('no recognised keyword leaves skill null, never a guess', () {
      final claims = extractor.extract(
        'Wrote extensive documentation for the onboarding process',
        source: 'resume',
      );
      expect(claims.single.skill, isNull);
    });

    test('the match is a whole word — "reactive" must not tag as "React"',
        () {
      final claims = extractor.extract(
        'Designed a reactive user interface layer for the checkout flow',
        source: 'resume',
      );
      expect(claims.single.skill, isNull);
    });
  });

  group('candidate cap', () {
    test('respects maxCandidates, keeping the earliest lines', () {
      const small = HeuristicClaimExtractor(maxCandidates: 2);
      final claims = small.extract(
        'Built and shipped a React dashboard used by 200+ staff\n'
        'Optimised Postgres queries across the reporting service\n'
        'Led the migration off the legacy CI pipeline entirely',
        source: 'resume',
      );
      expect(claims, hasLength(2));
      expect(claims.first.text,
          'Built and shipped a React dashboard used by 200+ staff');
    });
  });

  group('honesty — this is a heuristic, not a semantic extractor', () {
    test('a non-claim sentence that happens to be long enough is still '
        'extracted — there is no attempt at semantic filtering beyond length '
        'and shape', () {
      final claims = extractor.extract(
        'This resume was generated for demonstration purposes only today',
        source: 'resume',
      );
      expect(claims, hasLength(1));
    });
  });
}
