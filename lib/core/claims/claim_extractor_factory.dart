import 'claim_extractor.dart';
import 'gateway_claim_extractor.dart';

/// Builds the extractor the app should use by default: the AI Gateway.
///
/// There is deliberately no client-side provider switch here. Whether the
/// gateway answers with OpenAI or Ollama is a server config decision
/// (`LLM_PROVIDER` in `service/ai_gateway.py`), not something this app
/// chooses or even observes beyond the `ExtractorKind` label it gets back.
ClaimExtractor createDefaultClaimExtractor() => GatewayClaimExtractor();
