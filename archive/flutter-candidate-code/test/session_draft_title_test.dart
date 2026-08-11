import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/session/session_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionDraft.sessionTitle', () {
    test('is the placeholder label when nothing is set', () {
      final draft = SessionDraft();
      addTearDown(draft.dispose);
      expect(draft.sessionTitle, 'Unlabelled session');
    });

    test('is just the label when no role is picked', () {
      final draft = SessionDraft();
      addTearDown(draft.dispose);
      draft.label = 'Jane Doe';
      expect(draft.sessionTitle, 'Jane Doe');
    });

    test('names the role so the report reads as one case', () {
      final draft = SessionDraft();
      addTearDown(draft.dispose);
      draft.label = 'Jane Doe';
      draft.targetRole = Role(
        id: 'r1',
        title: 'Senior Backend',
        requiredSkills: const ['Go'],
        createdAt: DateTime(2026, 1, 1),
      );
      expect(draft.sessionTitle, 'Jane Doe — Senior Backend');
    });

    test('appends the role even to the placeholder label', () {
      final draft = SessionDraft();
      addTearDown(draft.dispose);
      draft.targetRole = Role(
        id: 'r1',
        title: 'Senior Backend',
        requiredSkills: const ['Go'],
        createdAt: DateTime(2026, 1, 1),
      );
      expect(draft.sessionTitle, 'Unlabelled session — Senior Backend');
    });
  });
}
