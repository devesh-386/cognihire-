import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/roles/role_question_priority.dart';
import 'package:flutter_test/flutter_test.dart';

Claim _claim(String id, {String? skill}) =>
    Claim(id: id, text: 'claim $id', source: 'resume', skill: skill);

Role _role({List<String> required = const [], List<String> desirable = const []}) =>
    Role(
      id: 'role-1',
      title: 'Backend Engineer',
      requiredSkills: required,
      desirableSkills: desirable,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('orderClaimsForRole', () {
    test('required-skill claims move ahead of untagged and unrelated claims',
        () {
      final untagged = _claim('untagged');
      final unrelated = _claim('unrelated', skill: 'Photoshop');
      final required = _claim('required', skill: 'PostgreSQL');

      final ordered = orderClaimsForRole(
        [untagged, unrelated, required],
        _role(required: ['PostgreSQL']),
      );

      expect(ordered.map((c) => c.id), ['required', 'untagged', 'unrelated']);
    });

    test('required skills come before desirable skills', () {
      final desirable = _claim('desirable', skill: 'Docker');
      final required = _claim('required', skill: 'Go');

      final ordered = orderClaimsForRole(
        [desirable, required],
        _role(required: ['Go'], desirable: ['Docker']),
      );

      expect(ordered.map((c) => c.id), ['required', 'desirable']);
    });

    test('matching is case- and whitespace-insensitive, same rule as '
        'role_coverage.dart', () {
      final claim = _claim('c1', skill: '  PostgreSQL  ');

      final ordered = orderClaimsForRole(
        [_claim('other'), claim],
        _role(required: ['postgresql']),
      );

      expect(ordered.first.id, 'c1');
    });

    test('claims within the same priority group keep their original order '
        '(stable)', () {
      final a = _claim('a', skill: 'Go');
      final b = _claim('b', skill: 'Go');
      final c = _claim('c', skill: 'Go');

      final ordered = orderClaimsForRole([a, b, c], _role(required: ['Go']));

      expect(ordered.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('a role with no skills at all leaves claim order untouched', () {
      final claims = [_claim('a'), _claim('b'), _claim('c')];

      final ordered = orderClaimsForRole(claims, _role());

      expect(ordered.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('every original claim is present exactly once — nothing dropped or '
        'duplicated', () {
      final claims = [
        _claim('a', skill: 'Go'),
        _claim('b'),
        _claim('c', skill: 'Rust'),
      ];

      final ordered = orderClaimsForRole(claims, _role(required: ['Go']));

      expect(ordered.length, claims.length);
      expect(ordered.map((c) => c.id).toSet(), claims.map((c) => c.id).toSet());
    });

    test('a claim tagged with a skill the role never asked for is treated '
        'the same as an untagged claim, not penalised further', () {
      final untagged = _claim('untagged');
      final unrelated = _claim('unrelated', skill: 'Photoshop');
      final required = _claim('required', skill: 'Go');

      final ordered = orderClaimsForRole(
        [unrelated, untagged, required],
        _role(required: ['Go']),
      );

      // 'required' first; the other two keep their relative order behind it.
      expect(ordered.map((c) => c.id), ['required', 'unrelated', 'untagged']);
    });
  });
}
