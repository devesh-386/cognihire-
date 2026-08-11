import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_store.dart';
import '../../core/auth/principal.dart';
import '../../core/auth/user_role.dart';
import '../../core/config.dart';
import '../../core/design/app_theme.dart';
import '../../core/invitations/invitation.dart';
import '../../core/invitations/invitation_store.dart';

/// The app's front door: choose which experience you are signing into.
///
/// ## Why a chooser, not a password form (yet)
///
/// The product has always described two experiences — [UserRole]'s own
/// documentation calls this "the sign-in chooser". Real credential verification
/// is a later slice (the `AuthStore`/`SupabaseAuthStore` already exist for it);
/// this screen's job is the structural one the app was missing entirely: making
/// "I am HR" and "I am the candidate" two distinct entry points that mount two
/// distinct experiences. Until credentials are wired, choosing HR constructs a
/// [Principal] for a demo account of that role.
///
/// ## Why the candidate side needs a code
///
/// A candidate is not a walk-up account: they interview *because* HR invited
/// them to a specific role. Requiring the invitation code here — rather than a
/// bare "Continue as Candidate" button — is what makes that binding real rather
/// than a UI label. See `invitations_screen.dart` for where the code comes from.
///
/// The [Principal] this produces is the one and only thing downstream code
/// reads to decide what a person may see — see `Principal.can`.
class SignInScreen extends StatelessWidget {
  const SignInScreen({
    super.key,
    required this.invitationStore,
    required this.authStore,
    required this.onSignIn,
    this.provisionOrganization,
  });

  final InvitationStore invitationStore;

  /// Real credential verification (Ticket 10) — [InMemoryAuthStore] in tests
  /// and local dev, `SupabaseAuthStore` in the running app.
  final AuthStore authStore;

  /// Called once someone has signed in. [invitation] is non-null only for a
  /// candidate who entered through a redeemed code — the caller uses it to
  /// bind the session that follows to that invitation's role.
  final void Function(Principal principal, Invitation? invitation) onSignIn;

  /// Creates an organisation for a freshly-registered recruiter and returns
  /// their [Principal] with `organisationId` now set, or null on failure. A
  /// brand new account has no organisation yet — see
  /// `provision_organization` in the `cognihire` Supabase project for why
  /// this has to be a separate post-registration step rather than part of
  /// [AuthStore.register] itself. Null in contexts (tests, previews) that
  /// never register a fresh recruiter.
  final Future<Principal?> Function(String organizationName)?
      provisionOrganization;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;
    return Scaffold(
      // A soft brand-tinted glow behind the header, fading into the ordinary
      // surface — this is the one screen nobody is "working in", so it can
      // afford to look designed rather than functional the way the workspace
      // screens (correctly) do.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.9),
            radius: 1.3,
            colors: [brand.accentSoft.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: Spacing.xl),
                  _BrandMark(colour: brand.accent),
                  const SizedBox(height: Spacing.lg),
                  Text('CogniHire',
                      style: theme.textTheme.displaySmall,
                      textAlign: TextAlign.center),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    'Verified-claim interviewing for recruiters.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Spacing.section),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _RecruiterAuthCard(
                      authStore: authStore,
                      provisionOrganization: provisionOrganization,
                      onSignedIn: (principal) => onSignIn(principal, null),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The wordmark's icon: a tinted circle, not a bare glyph. Same visual math
/// as the initials avatar elsewhere in the app (`patterns.dart`) — a
/// low-alpha fill of [colour] with a slightly stronger border of the same
/// colour — so the brand mark and the rest of the app read as one language
/// rather than the login screen inventing its own.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Icon(Icons.verified_user_outlined, size: 26, color: colour),
    );
  }
}

/// A card header's icon, tinted the same way as [_BrandMark] — every icon on
/// this screen reads as "badge", not "glyph floating in whitespace".
class _CardIcon extends StatelessWidget {
  const _CardIcon({required this.icon, required this.colour});

  final IconData icon;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 24, color: colour),
    );
  }
}

/// Real HR sign-in (Ticket 10) — replaces the earlier one-tap demo button.
/// Two modes: sign in to an existing account, or register a new one, which
/// also creates that account's organisation via [provisionOrganization].
class _RecruiterAuthCard extends StatefulWidget {
  const _RecruiterAuthCard({
    required this.authStore,
    required this.onSignedIn,
    this.provisionOrganization,
  });

  final AuthStore authStore;
  final void Function(Principal principal) onSignedIn;
  final Future<Principal?> Function(String organizationName)?
      provisionOrganization;

  @override
  State<_RecruiterAuthCard> createState() => _RecruiterAuthCardState();
}

class _RecruiterAuthCardState extends State<_RecruiterAuthCard> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Registration now happens on the web portal (Supabase Auth there), not
  /// in-app — a brand new organisation/recruiter account is created through
  /// the same flow candidates never see, then the recruiter comes back here
  /// and signs in normally. Opens in a new tab rather than navigating this
  /// one away, since this is a Flutter *web* app (see launch.json — there is
  /// no native mobile/desktop target to deep-link back into) and signing in
  /// afterwards needs this tab still open.
  Future<void> _openBrowserRegistration() async {
    final uri = Uri.parse('${AppConfig.portalUrl}/signup');
    // webOnlyWindowName opens a new tab under Flutter web rather than
    // navigating this one away; ignored on other platforms.
    await launchUrl(uri, webOnlyWindowName: '_blank');
  }

  String _messageFor(AuthFailure failure, String? detail) {
    switch (failure) {
      case AuthFailure.invalidCredentials:
        return 'Incorrect email or password.';
      case AuthFailure.wrongRole:
        return detail ?? 'This account is not registered as a recruiter.';
      case AuthFailure.emailAlreadyRegistered:
        return 'An account already exists for that email — sign in instead.';
      case AuthFailure.weakPassword:
        return detail ?? 'Choose a stronger password.';
      case AuthFailure.unavailable:
        return 'Could not reach the sign-in service. Check your connection.';
      case AuthFailure.unrecognisedRole:
        return 'This account is not set up correctly. Contact support.';
    }
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await widget.authStore.signIn(
      email: email,
      password: password,
      asRole: UserRole.recruiter,
    );
    if (!mounted) return;

    switch (result) {
      case AuthRejected(:final failure, :final message):
        setState(() {
          _submitting = false;
          _error = _messageFor(failure, message);
        });
      case AuthSuccess(:final principal):
        widget.onSignedIn(principal);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardIcon(
              icon: Icons.business_center_outlined,
              colour: theme.colorScheme.tertiary,
            ),
            const SizedBox(height: Spacing.lg),
            Text('Continue as ${UserRole.recruiter.label}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.sm),
            Text(
              UserRole.recruiter.description,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.lg),
            if (_registering) ...[
              Text(
                'Account creation happens on the CogniHire website — opens '
                'in a new tab. Come back here and sign in once it\'s done.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openBrowserRegistration,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Create account on cognihire.online'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Work email'),
              ),
              const SizedBox(height: Spacing.sm),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: Spacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('Enter as ${UserRole.recruiter.label}'),
                ),
              ),
            ],
            const SizedBox(height: Spacing.sm),
            Center(
              child: TextButton(
                onPressed: _submitting
                    ? null
                    : () => setState(() {
                          _registering = !_registering;
                          _error = null;
                        }),
                child: Text(_registering
                    ? 'Already have an account? Sign in'
                    : "New organisation? Create an account"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

