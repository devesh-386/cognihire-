import 'package:cognihire/core/privacy/candidate_id.dart';
import 'package:cognihire/core/privacy/scrubber.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CandidateId — non-linkable HMAC identifiers', () {
    test('the same (secret, seed) pair always derives the same id', () {
      final a = CandidateId.derive(secret: 's3cret', seed: 'alice@example.com');
      final b = CandidateId.derive(secret: 's3cret', seed: 'alice@example.com');
      expect(a.value, b.value);
    });

    test('a different seed under the same secret derives a different id', () {
      final a = CandidateId.derive(secret: 's3cret', seed: 'alice@example.com');
      final b = CandidateId.derive(secret: 's3cret', seed: 'bob@example.com');
      expect(a.value, isNot(b.value));
    });

    test('a different secret derives a different id for the same seed — '
        'ids cannot be linked across research-release batches with '
        'different keys', () {
      final a = CandidateId.derive(secret: 'key-2026-A', seed: 'alice@example.com');
      final b = CandidateId.derive(secret: 'key-2026-B', seed: 'alice@example.com');
      expect(a.value, isNot(b.value));
    });

    test('the id never contains the raw seed as a substring', () {
      final id = CandidateId.derive(secret: 'k', seed: 'alice@example.com');
      expect(id.value.contains('alice'), isFalse);
      expect(id.value.contains('example.com'), isFalse);
    });

    test('is a fixed-length hex string regardless of seed length', () {
      final short = CandidateId.derive(secret: 'k', seed: 'a');
      final long = CandidateId.derive(
          secret: 'k', seed: 'a very long identifying string indeed' * 10);
      expect(short.value.length, long.value.length);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(short.value), isTrue);
    });

    test('an empty secret is rejected — an unkeyed hash is not an HMAC', () {
      expect(() => CandidateId.derive(secret: '', seed: 'x'), throwsArgumentError);
    });

    test('an empty seed is rejected — nothing to derive an id from', () {
      expect(() => CandidateId.derive(secret: 'k', seed: ''), throwsArgumentError);
    });
  });

  group('Scrubber — removes personally-identifying text', () {
    const scrubber = Scrubber();

    test('an email address is redacted', () {
      final r = scrubber.scrub('Reach me at alice.nguyen@example.com please');
      expect(r.text.contains('alice.nguyen@example.com'), isFalse);
      expect(r.text, contains('[EMAIL]'));
      expect(r.redactionCount, 1);
    });

    test('a known name is redacted when supplied as a scrub target', () {
      final r = scrubber.scrub(
        'Alice Nguyen led the migration. Alice was thorough.',
        knownNames: const ['Alice Nguyen'],
      );
      expect(r.text.contains('Alice Nguyen'), isFalse);
      expect(r.text.contains('Alice'), isFalse);
      expect(r.text, contains('[NAME]'));
    });

    test('a known institution is redacted when supplied as a scrub target', () {
      final r = scrubber.scrub(
        'Graduated from Springfield University in 2022.',
        knownInstitutions: const ['Springfield University'],
      );
      expect(r.text.contains('Springfield University'), isFalse);
      expect(r.text, contains('[INSTITUTION]'));
    });

    test('text with nothing to scrub round-trips unchanged and reports zero', () {
      final r = scrubber.scrub('Wrote a function that reverses a string.');
      expect(r.text, 'Wrote a function that reverses a string.');
      expect(r.redactionCount, 0);
    });

    test('multiple emails in one string are all redacted', () {
      final r = scrubber.scrub('cc: a@x.com and b@y.com');
      expect(r.redactionCount, 2);
      expect(r.text.contains('@'), isFalse);
    });

    test('matching is case-insensitive for supplied names and institutions', () {
      final r = scrubber.scrub(
        'ALICE NGUYEN studied at SPRINGFIELD UNIVERSITY.',
        knownNames: const ['Alice Nguyen'],
        knownInstitutions: const ['Springfield University'],
      );
      expect(r.text.contains('ALICE'), isFalse);
      expect(r.text.contains('SPRINGFIELD'), isFalse);
    });

    test('an empty string scrubs to an empty string with zero redactions', () {
      final r = scrubber.scrub('');
      expect(r.text, '');
      expect(r.redactionCount, 0);
    });
  });
}
