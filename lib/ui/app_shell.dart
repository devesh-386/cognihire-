/// The application shell: persistent navigation plus a content area.
///
/// ## The problem this solves
///
/// Every destination used to be reached by pushing a route from a list on the
/// home screen, which had two costs. A reviewer comparing a past session
/// against the one in front of them had to navigate back to the root and down
/// again, losing their place both ways. And because the entry points were rows
/// in a list, adding a feature meant adding a row — which is exactly how three
/// finished features ended up unreachable: nobody added the row.
///
/// A persistent rail makes the app's surface visible at all times. What exists
/// is what is in the rail, so a feature that has not been given a destination
/// is obvious rather than invisible.
///
/// ## Why an IndexedStack and not a route per destination
///
/// Switching destinations preserves each one's scroll position and transient
/// state, because these are workspaces a reviewer moves between mid-task rather
/// than pages they visit in sequence. The cost is that every destination stays
/// alive; that is acceptable at four of them and would not be at forty.
///
/// Destinations are built **lazily** — a destination is an empty box until it
/// is first selected, and is kept alive from then on. A plain `IndexedStack`
/// builds every child immediately, which would mean opening the app paid for
/// reading the session store and mounting the telemetry sandbox before the user
/// had asked for either.
library;

import 'package:flutter/material.dart';

import '../core/design/app_theme.dart';
import 'tokens.dart';

/// One destination in the shell.
class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.builder,
    this.shortLabel,
  });

  final IconData icon;
  final IconData selectedIcon;

  /// Shown in the rail, where there is room for a descriptive name.
  final String label;

  /// Shown in the compact bottom bar, where four labels share the screen
  /// width. Falls back to [label]. Exists so the rail does not have to be
  /// abbreviated to suit the narrowest window the app will ever see.
  final String? shortLabel;

  final WidgetBuilder builder;
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.destinations,
    this.initialIndex = 0,
    this.title = 'CogniHire',
  });

  final List<ShellDestination> destinations;
  final int initialIndex;
  final String title;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index = widget.initialIndex.clamp(
    0,
    widget.destinations.length - 1,
  );

  /// Destinations that have been opened at least once. Only these are built;
  /// the rest stay as empty boxes holding their slot in the stack.
  late final Set<int> _visited = {_index};

  void _select(int i) => setState(() {
        _index = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    final compact = Breakpoints.isCompact(context);
    final expanded = Breakpoints.isExpanded(context);

    final body = IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < widget.destinations.length; i++)
          // Each destination keeps its own Navigator-free subtree; pushes still
          // go to the root navigator and cover the shell, which is right for
          // the flows that take over the screen (enrolment, live interview).
          if (_visited.contains(i))
            Builder(builder: widget.destinations[i].builder)
          else
            const SizedBox.shrink(),
      ],
    );

    if (compact) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: [
            for (final d in widget.destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.shortLabel ?? d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _Rail(
              index: _index,
              extended: expanded,
              title: widget.title,
              destinations: widget.destinations,
              onSelected: _select,
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.index,
    required this.extended,
    required this.title,
    required this.destinations,
    required this.onSelected,
  });

  final int index;
  final bool extended;
  final String title;
  final List<ShellDestination> destinations;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      extended: extended,
      labelType:
          extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
      backgroundColor: theme.colorScheme.surface,
      leading: Padding(
        padding: const EdgeInsets.only(
          top: Spacing.lg,
          bottom: Spacing.xl,
          left: Spacing.sm,
          right: Spacing.sm,
        ),
        child: _Wordmark(extended: extended, title: title),
      ),
      destinations: [
        for (final d in destinations)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          ),
      ],
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.extended, required this.title});

  final bool extended;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mark = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Icon(
        Icons.verified_outlined,
        color: theme.colorScheme.onPrimary,
        size: 19,
      ),
    );

    if (!extended) return mark;

    // Bounded width: an extended rail is a fixed-width column, so an unbounded
    // Row here would overflow rather than ellipsize.
    return SizedBox(
      width: 168,
      child: Row(
        children: [
          mark,
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A standard page frame for anything rendered inside the shell: a sticky
/// header with title and optional actions, then scrollable content constrained
/// to a readable measure.
///
/// Screens use this rather than their own `Scaffold` + `AppBar` so that the
/// header rhythm, the content inset, and the maximum measure are decided once.
class ShellPage extends StatelessWidget {
  const ShellPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions = const [],
    this.maxWidth = Measures.workspace,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = Breakpoints.isCompact(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? Spacing.lg : Spacing.xxl,
            Spacing.xl,
            compact ? Spacing.lg : Spacing.xxl,
            Spacing.lg,
          ),
          // Same measure and same centring as the body below, so the title
          // sits directly above the left edge of the first card instead of
          // floating off on its own axis.
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.headlineSmall),
                        if (subtitle != null) ...[
                          const SizedBox(height: Spacing.xs),
                          Text(subtitle!, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: Spacing.md),
                    // Wrap so a narrow window drops actions onto another line
                    // instead of squeezing the title.
                    Wrap(spacing: Spacing.sm, children: actions),
                  ],
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              compact ? Spacing.lg : Spacing.xxl,
              Spacing.xl,
              compact ? Spacing.lg : Spacing.xxl,
              Spacing.xxxl,
            ),
            // Centred, not left-pinned. A measure-constrained column shoved
            // against the left edge of a wide window reads as a layout that
            // failed rather than one that chose its width.
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
