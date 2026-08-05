/// Ticket 11 (self-hosted alternative) — the public apply page's entry
/// point. Its own main() because it needs nothing else the HR/candidate apps
/// carry (no auth store, no interview screens) — just Supabase for the
/// role dropdown and the apply-webhook call.
///
/// Build/run with:
///   flutter build web -t lib/main_apply.dart
///   flutter run -d chrome -t lib/main_apply.dart
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'core/config.dart';
import 'core/design/app_theme.dart';
import 'features/apply/apply_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await supabase.Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
  runApp(const ApplyApp());
}

class ApplyApp extends StatelessWidget {
  const ApplyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniHire — Apply',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const ApplyScreen(),
    );
  }
}
