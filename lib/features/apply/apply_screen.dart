/// Ticket 11 (self-hosted alternative) — a public "apply" page that replaces
/// the Google Form dependency. Anyone with the link can submit; no sign-in,
/// no Google account, no Apps Script. Posts straight to the apply-webhook
/// Edge Function, which creates a candidate + a scheduled invitation exactly
/// like the Google Form path does.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/config.dart';
import '../../core/design/app_theme.dart';

class OpenRole {
  const OpenRole({required this.id, required this.title});
  final String id;
  final String title;
}

/// Default role loader — calls the public `list_open_roles()` RPC via the
/// live Supabase singleton. Overridable via [ApplyScreen.loadRoles] so the
/// screen is testable without a live Supabase project (mirrors
/// InvitationsScreen's injectable `loadSessions`).
Future<List<OpenRole>> _defaultLoadRoles() async {
  final rows =
      await supabase.Supabase.instance.client.rpc('list_open_roles') as List;
  return rows
      .map((r) => OpenRole(
            id: (r as Map)['id'] as String,
            title: r['title'] as String,
          ))
      .toList();
}

class ApplyScreen extends StatefulWidget {
  const ApplyScreen({
    super.key,
    this.loadRoles = _defaultLoadRoles,
    this.submitApplication,
  });

  final Future<List<OpenRole>> Function() loadRoles;

  /// Overridable for tests; defaults to a real POST to apply-webhook.
  final Future<http.Response> Function(Map<String, dynamic> body)?
      submitApplication;

  @override
  State<ApplyScreen> createState() => _ApplyScreenState();
}

class _ApplyScreenState extends State<ApplyScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  DateTime? _preferredTime;
  String? _roleId;
  List<OpenRole> _roles = const [];
  bool _loadingRoles = true;
  String? _rolesError;

  String? _resumeFileName;
  List<int>? _resumeBytes;

  bool _submitting = false;
  String? _error;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _loadRoles();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await widget.loadRoles();
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _loadingRoles = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesError = 'Could not load open roles: $error';
        _loadingRoles = false;
      });
    }
  }

  Future<void> _pickResume() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'doc', 'docx'],
      withData: true,
    );
    final picked = result?.files.single;
    if (picked == null || picked.bytes == null) return;
    setState(() {
      _resumeFileName = picked.name;
      _resumeBytes = picked.bytes;
    });
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 10, minute: 0),
    );
    if (time == null) return;
    setState(() {
      _preferredTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty || email.isEmpty) {
      setState(() => _error = 'Enter your name and email.');
      return;
    }
    if (_roleId == null) {
      setState(() => _error = 'Choose the role you are applying for.');
      return;
    }
    if (_preferredTime == null) {
      setState(() => _error = 'Choose a preferred interview time.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final payload = {
      'name': name,
      'email': email,
      'roleId': _roleId,
      'preferredTimeIso': _preferredTime!.toIso8601String(),
      if (_resumeBytes != null) 'resumeBase64': base64Encode(_resumeBytes!),
      if (_resumeFileName != null) 'resumeFilename': _resumeFileName,
    };

    try {
      final response = widget.submitApplication != null
          ? await widget.submitApplication!(payload)
          : await http.post(
              Uri.parse('${AppConfig.supabaseUrl}/functions/v1/apply-webhook'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            );
      if (!mounted) return;
      if (response.statusCode >= 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _submitting = false;
          _error = body['error'] as String? ?? 'Submission failed.';
        });
        return;
      }
      setState(() {
        _submitting = false;
        _submitted = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not submit: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_submitted) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 48, color: theme.colorScheme.primary),
                const SizedBox(height: Spacing.md),
                Text('Application received', style: theme.textTheme.titleLarge),
                const SizedBox(height: Spacing.sm),
                const Text(
                  "We'll email your interview code shortly before your "
                  'scheduled time.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Apply for an interview')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                ),
                const SizedBox(height: Spacing.sm),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: Spacing.sm),
                if (_loadingRoles)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    child: LinearProgressIndicator(),
                  )
                else if (_rolesError != null)
                  Text(_rolesError!, style: TextStyle(color: theme.colorScheme.error))
                else if (_roles.isEmpty)
                  const Text('No open roles right now — check back later.')
                else
                  DropdownButtonFormField<String>(
                    initialValue: _roleId,
                    decoration:
                        const InputDecoration(labelText: 'Role applying for'),
                    items: _roles
                        .map((r) => DropdownMenuItem(
                              value: r.id,
                              child: Text(r.title),
                            ))
                        .toList(),
                    onChanged: (value) => setState(() => _roleId = value),
                  ),
                const SizedBox(height: Spacing.sm),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(_preferredTime == null
                      ? 'Choose preferred interview time'
                      : _preferredTime.toString()),
                ),
                const SizedBox(height: Spacing.sm),
                OutlinedButton.icon(
                  onPressed: _pickResume,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(_resumeFileName ?? 'Upload résumé (optional)'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Spacing.sm),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: Spacing.lg),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit application'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
