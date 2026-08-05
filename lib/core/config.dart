/// Runtime configuration.
///
/// Override at build time:
///   flutter run --dart-define=FACE_SERVICE_URL=http://192.168.1.10:8000
class AppConfig {
  /// Base URL of the face analysis service.
  static const faceServiceUrl = String.fromEnvironment(
    'FACE_SERVICE_URL',
    defaultValue: 'http://localhost:8000',
  );

  /// Base URL of the local Ollama service used for claim extraction. Local by
  /// default and by intent: the resume never leaves the machine, so there is no
  /// key to manage and no third party to trust.
  static const ollamaBaseUrl = String.fromEnvironment(
    'OLLAMA_BASE_URL',
    defaultValue: 'http://localhost:11434',
  );

  /// The Ollama model tag to use. `qwen2.5:7b` is the general-purpose sibling of
  /// the coder variant — claim extraction is prose selection, not code.
  static const ollamaModel = String.fromEnvironment(
    'OLLAMA_MODEL',
    defaultValue: 'qwen2.5:7b',
  );

  /// Minimum face pixel area required before an enrolment capture is accepted.
  /// Below this the face is too small for a dependable embedding, and we say
  /// so rather than enrolling a weak reference that causes mismatches later.
  static const minEnrolmentFaceSize = 15000;

  /// Supabase project URL. The anon/publishable key is safe to ship in the
  /// client by design — every table it can reach is RLS-scoped by
  /// organization_id (see the `cognihire` project's `cognihire_minimal_schema`
  /// migration), so the key alone grants no cross-tenant access.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://foffzvwmxnsmbixkilxt.supabase.co',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'sb_publishable_UKR2UuhjY3--RhlvZbGt8A_L3_Mf_dN',
  );
}
