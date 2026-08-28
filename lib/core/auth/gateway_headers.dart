/// The Authorization header every recruiter-facing gateway call needs.
///
/// `service/main.py` resolves the caller's organisation from a bearer token
/// (`_require_org`) on every recruiter route. That check was added to a set of
/// routes that had previously been open — see main.py's own comment, "replaces
/// six routes that simply forgot to call `_require_org`" — but the Flutter
/// clients were never updated to send a token. The result was an endpoint that
/// answered 401 for every recruiter, permanently, with the failure surfacing in
/// the UI as "the gateway answered HTTP 401" rather than as "you are signed
/// out": observed on the session report screen, where the résumé, the report and
/// the email status all failed at once.
///
/// Centralised rather than repeated per client so a new gateway client cannot
/// quietly ship without auth the way those did — there is one place to copy.
///
/// A null session yields no header, deliberately. The gateway then answers 401,
/// which is the honest outcome for a signed-out caller; inventing an empty
/// bearer token would turn that into a malformed-credential error instead.
///
/// `Supabase.instance` *asserts* rather than returning null when the SDK has
/// not been initialised, so the no-session path has to be caught, not
/// null-checked. Uninitialised is reachable from any entry point that does not
/// call `Supabase.initialize` — `main_apply.dart` and the widget tests among
/// them — and letting that assertion escape would replace a readable "HTTP 401"
/// with an unhandled error thrown from inside an unrelated screen's future.
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

Map<String, String> gatewayAuthHeaders({Map<String, String>? extra}) {
  supabase.Session? session;
  try {
    session = supabase.Supabase.instance.client.auth.currentSession;
  } catch (_) {
    session = null;
  }
  return {
    if (session != null) 'Authorization': 'Bearer ${session.accessToken}',
    ...?extra,
  };
}
