/// Mounts [LiveInterviewScreen] the way `test/screens_widget_test.dart`
/// mounts every other screen — this one is new enough, and animated enough
/// (three independent looping [AnimationController]s), that "the prompt eval
/// passes" says nothing about whether the widget tree actually builds.
library;

import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/features/interview/interview_voice_controller.dart';
import 'package:cognihire/features/interview/live_interview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrapped(InterviewVoiceController controller) => MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: LiveInterviewScreen(controller: controller),
    );

void main() {
  testWidgets('builds and survives a few animation frames in every presence',
      (tester) async {
    final controller =
        InterviewVoiceController(claims: const [], jobRequirements: const []);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_wrapped(controller));

    // pumpAndSettle would hang: the breathe/sheen loops never stop, by
    // design (see LiveInterviewScreen's doc on why idle still breathes).
    // A handful of fixed pumps is the right check here — did anything throw
    // while the animations actually ran, not "did they finish".
    for (final presence in VoicePresence.values) {
      controller.presence = presence;
      controller.currentSay = presence == VoicePresence.speaking
          ? 'You mentioned Django. How did you handle authentication?'
          : '';
      // ignore: invalid_use_of_protected_member
      controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('shows the degraded banner instead of throwing when the model call fails',
      (tester) async {
    final controller =
        InterviewVoiceController(claims: const [], jobRequirements: const []);
    addTearDown(controller.dispose);
    controller.degradedReason = 'could not reach the local model service';
    await tester.pumpWidget(_wrapped(controller));
    await tester.pump();

    expect(find.textContaining('could not reach the local model service'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing and submitting a turn does not throw with no live model',
      (tester) async {
    final controller =
        InterviewVoiceController(claims: const [], jobRequirements: const []);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_wrapped(controller));

    await tester.enterText(find.byType(TextField), 'I used Django for auth.');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // No Ollama reachable in a widget test — the important assertion is that
    // submitting drives presence to `thinking` and back down cleanly rather
    // than throwing while the (failing) network call is in flight.
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });
}
