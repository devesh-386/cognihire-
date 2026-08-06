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

  /// Base URL of a local Ollama instance. Only used by dev tools under
  /// `tool/` and by [OllamaClaimExtractor] when something constructs it
  /// directly for offline testing — the running app never talks to Ollama
  /// itself. See [aiGatewayUrl].
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

  /// Base URL of the AI Gateway — the FastAPI service that owns every call to
  /// an LLM. Today this is the same process as the face service
  /// (`faceServiceUrl`); kept as its own config key so gateway and face
  /// analysis can be split into separate deployments later without a client
  /// code change. The client never learns which model or provider answered a
  /// request beyond the `kind` label the gateway returns — no API key, no
  /// prompt, and no provider name are ever present in this app.
  static const aiGatewayUrl = String.fromEnvironment(
    'AI_GATEWAY_URL',
    defaultValue: faceServiceUrl,
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
