/// Ticket 13 — the candidate web app's entry point.
///
/// A separate `main` rather than a flag on the existing one: the link HR
/// emails to a candidate should never expose an HR sign-in/register form,
/// even hidden behind a toggle a curious candidate could find in devtools.
/// Building this as its own entry point makes that a compile-time fact, not
/// a runtime one. Everything downstream — stores, the shell, the interview
/// screens — is exactly what `main.dart` already uses; only the sign-in
/// screen configuration and the absence of the recruiter provisioning
/// callback differ.
///
/// Build/run with:
///   flutter build web -t lib/main_candidate.dart
///   flutter run -d chrome -t lib/main_candidate.dart
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'core/auth/principal.dart';
import 'core/auth/supabase_auth_store.dart';
import 'core/config.dart';
import 'core/email/email_sender.dart';
import 'core/invitations/invitation.dart';
import 'core/invitations/invitation_store_supabase.dart';
import 'core/persistence/audit_store.dart';
import 'core/persistence/store_factory.dart';
import 'core/roles/role_store_supabase.dart';
import 'core/design/app_theme.dart';
import 'features/auth/sign_in_screen.dart';
import 'main.dart' show HomeScreen;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await supabase.Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
  final client = supabase.Supabase.instance.client;

  AuditStore store;
  String location;
  bool durable;
  try {
    store = await createAuditStore();
    location = await auditStorageLocation();
    durable = storageIsDurable;
  } catch (error) {
    store = InMemoryAuditStore();
    location = 'Storage unavailable ($error) — sessions will not be kept.';
    durable = false;
  }

  runApp(CandidateApp(
    invitationStore: SupabaseInvitationStore(client),
    roleStore: SupabaseRoleStore(client),
    authStore: SupabaseAuthStore(client),
    store: store,
    storageLocation: location,
    storageIsDurable: durable,
  ));
}

class CandidateApp extends StatefulWidget {
  const CandidateApp({
    super.key,
    required this.invitationStore,
    required this.roleStore,
    required this.authStore,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
  });

  final SupabaseInvitationStore invitationStore;
  final SupabaseRoleStore roleStore;
  final SupabaseAuthStore authStore;
  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  State<CandidateApp> createState() => _CandidateAppState();
}

class _CandidateAppState extends State<CandidateApp> {
  ThemeMode _themeMode = ThemeMode.system;
  Principal? _principal;
  Invitation? _redeemedInvitation;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniHire — Interview',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: _principal == null
          ? SignInScreen(
              invitationStore: widget.invitationStore,
              authStore: widget.authStore,
              showRecruiterOption: false,
              onSignIn: (p, invitation) => setState(() {
                _principal = p;
                _redeemedInvitation = invitation;
              }),
            )
          : HomeScreen(
              key: ValueKey(_principal!.id),
              store: widget.store,
              roleStore: widget.roleStore,
              invitationStore: widget.invitationStore,
              emailSender: const NullEmailSender(),
              redeemedInvitation: _redeemedInvitation,
              storageLocation: widget.storageLocation,
              storageIsDurable: widget.storageIsDurable,
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
              principal: _principal,
              onSignOut: () => setState(() {
                _principal = null;
                _redeemedInvitation = null;
              }),
            ),
    );
  }
}
