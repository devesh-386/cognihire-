import '../../app/routes.dart';
import '../auth/principal.dart';

/// What should happen when someone tries to open a route.
///
/// A sealed decision rather than a bool, because "no" has three genuinely
/// different meanings and collapsing them produces bad behaviour: a signed-out
/// user who is *denied* sees an intimidating error instead of a login form, and
/// a signed-in candidate who is *redirected to login* is asked to authenticate
/// as an account they are already using.
sealed class RouteDecision {
  const RouteDecision();
}

/// Open it.
final class RouteAllowed extends RouteDecision {
  const RouteAllowed(this.route);
  final AppRoute route;
}

/// Nobody is signed in. Send them to sign-in, remembering where they were
/// going so they land there afterwards rather than on a generic home screen.
final class RouteNeedsSignIn extends RouteDecision {
  const RouteNeedsSignIn({this.intended});

  /// The path originally requested, to resume after a successful sign-in.
  final String? intended;
}

/// Signed in, but not permitted. This is the candidate-opens-an-HR-page case.
///
/// Carries [missing] so the UI can say what was required. That is a deliberate
/// choice about *authenticated* users only — telling a signed-in person "this
/// needs the analytics permission" is helpful and leaks nothing they could not
/// infer from the navigation they can already see.
final class RouteForbidden extends RouteDecision {
  const RouteForbidden(this.route, this.missing);
  final AppRoute route;
  final List<Object> missing;
}

/// No route with that path exists.
final class RouteNotFound extends RouteDecision {
  const RouteNotFound(this.path);
  final String path;
}

/// Already signed in, but the route is sign-out-only (a login form). Send them
/// to their own home instead.
final class RouteAlreadySignedIn extends RouteDecision {
  const RouteAlreadySignedIn(this.home);
  final AppRoute home;
}

/// Decides whether a [Principal] may open a path.
///
/// ## The single choke point
///
/// Every navigation goes through [resolve]. There is no second path into a
/// screen — a widget that could be pushed directly, bypassing this, is a hole
/// regardless of how the navigation that normally reaches it is guarded. That
/// is why the shells build their destination lists from
/// [AppRoutes.hr]/[AppRoutes.candidate] filtered through [permitted] rather
/// than hardcoding screens: the navigation cannot offer something the guard
/// would refuse, and the guard still refuses it if something else tries.
///
/// ## Stateless on purpose
///
/// [resolve] takes the principal as an argument rather than reading a global.
/// A guard that consulted ambient state could not be tested exhaustively across
/// the role matrix in one file, and would be one stale-cache bug away from
/// authorising against the previously signed-in user.
abstract final class RouteResolver {
  /// Decide what to do about [path] for [principal] (null when signed out).
  static RouteDecision resolve(String path, Principal? principal) {
    final route = AppRoutes.find(path);
    if (route == null) return RouteNotFound(path);

    if (route.signedOutOnly) {
      return principal == null
          ? RouteAllowed(route)
          : RouteAlreadySignedIn(AppRoutes.homeFor(principal.role));
    }

    if (principal == null) return RouteNeedsSignIn(intended: path);

    final missing =
        route.requires.where((p) => !principal.can(p)).toList(growable: false);
    if (missing.isNotEmpty) return RouteForbidden(route, missing);

    return RouteAllowed(route);
  }

  /// Whether [principal] may open [route]. Convenience for building navigation;
  /// [resolve] remains the thing that actually gates entry.
  static bool permits(AppRoute route, Principal? principal) =>
      resolve(route.path, principal) is RouteAllowed;

  /// The subset of [routes] that [principal] may open, in the given order.
  ///
  /// Used to build each shell's destination list. A destination the guard would
  /// refuse must never appear in navigation — offering a button that leads to a
  /// refusal is worse than not offering it, because the user reasonably
  /// concludes something is broken.
  static List<AppRoute> permitted(
    List<AppRoute> routes,
    Principal? principal,
  ) =>
      routes.where((r) => permits(r, principal)).toList(growable: false);
}
