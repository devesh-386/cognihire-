# Ticket 13 — candidate web app (scaffold slice)

## What this slice covers
- lib/main_candidate.dart: separate entry point, candidate-only. Compile-time
  guarantee (not a runtime flag) that the HR sign-in/register form never ships
  on a link handed to candidates.
- SignInScreen gets a `showRecruiterOption` param (default true, unchanged for
  the HR app) — false renders only the candidate code card, centered.
- Confirmed `flutter build web -t lib/main_candidate.dart` succeeds cleanly.
- Ran it live: `flutter run -d web-server --web-port 8767 -t lib/main_candidate.dart`,
  loaded http://localhost:8767 in the browser pane. Verified via
  document.title ("CogniHire — Interview", confirming the candidate entry
  point mounted, not the HR app's "CogniHire") and `flt-glass-pane` presence
  (Flutter's web canvas actually rendering), zero console errors. Could not
  get a pixel screenshot -- the Browser pane wasn't compositing frames in this
  session; title + DOM + console checks are the evidence instead.

## Not yet done (rest of Ticket 13)
- Still points at localhost Ollama/face service by default -- needs Ticket 9's
  Coolify deployment live to actually run an interview from a real browser
  elsewhere.
- Webcam identity verification not yet exercised on this entry point.
- No deployment target chosen yet for hosting the built web/ output itself
  (Coolify can serve a static site too, or Supabase Storage + a CDN, or
  Netlify/Vercel -- not decided).

## flutter analyze / test
No issues found. 735 passed (+1 for the showRecruiterOption test), 0 failed.
