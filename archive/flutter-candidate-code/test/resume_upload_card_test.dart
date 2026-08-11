import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/features/resume/resume_upload_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: AppTheme.light, home: Scaffold(body: child));

void main() {
  testWidgets('shows the dropzone at rest, with no file implied yet',
      (tester) async {
    await tester.pumpWidget(_wrap(const ResumeUploadCard()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Click to browse'), findsOneWidget);
    expect(find.textContaining('.txt'), findsWidgets);
  });

  testWidgets('never claims automatic parsing for pdf/docx', (tester) async {
    await tester.pumpWidget(_wrap(const ResumeUploadCard()));
    await tester.pumpAndSettle();

    // The card's own description must not overclaim what this build does.
    expect(
      find.textContaining('not parsed yet'),
      findsOneWidget,
    );
  });

  testWidgets('renders in dark theme without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: ResumeUploadCard()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
