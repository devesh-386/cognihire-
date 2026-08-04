/// The application shell: persistent navigation, a top bar, plus a content area.
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
/// than pages they visit in sequence.
///
/// Destinations are built **lazily** — a destination is an empty box until it
/// is first selected, and is kept alive from then on. A plain `IndexedStack`
/// builds every child immediately, which would mean opening the app paid for
/// reading the session store and mounting the telemetry sandbox before the user
/// had asked for either. With nine destinations that matters more than it did
/// with four.
///
/// ## The top bar, and the rule about its buttons
///
/// The Golden Taupe mockups put a search field, a notification bell, a help
/// affordance, and two named buttons across the top of every screen. All of
/// those are here, and **every one of them does something real**: search queries
/// the session store, the bell lists conditions the app has actually detected,
/// help opens the shipped explanation of what the product does and does not
/// claim. Nothing in this chrome is a placeholder, because a control that looks
/// live and is inert is worse than an absent one — it teaches the user that the
/// interface lies.
///
/// Where a mockup button had no honest implementation it was **renamed to the
/// real capability** rather than kept and stubbed. There is no team to invite in
/// a local-first tool that never uploads anything, so that button became the
/// export it would have needed anyway.
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

  /// Shown in the compact bottom bar, where the labels share the screen
  /// width. Falls back to [label]. Exists so the rail does not have to be
  /// abbreviated to suit the narrowest window the app will ever see.
  final String? shortLabel;

  final WidgetBuilder builder;
}

/// The sidebar's single prominent action.
///
/// Rendered as a custom control rather than a [FilledButton] on purpose: the
/// filled-button slot belongs to whatever the *page* is asking the user to do,
/// and a permanent chrome button competing with it at the same visual weight
/// makes both weaker.
class ShellPrimaryAction {
  const ShellPrimaryAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

/// One thing the app has noticed and the user should know about.
///
/// These are *detected conditions*, never marketing. The bell shows the count of
/// these and nothing else; when the list is empty it says so rather than showing
/// a dot.
class ShellNotice {
  const ShellNotice({
    required this.title,
    required this.detail,
    this.tone = ShellNoticeTone.info,
    this.onTap,
  });

  final String title;
  final String detail;
  final ShellNoticeTone tone;
  final VoidCallback? onTap;
}

enum ShellNoticeTone { info, caution, fault }

/// Who the shell is currently acting as, shown in the sidebar footer.
class ShellIdentity {
  const ShellIdentity({
    required this.name,
    required this.role,
    this.onTap,
  });

  final String name;
  final String role;
  final VoidCallback? onTap;
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.destinations,
    this.initialIndex = 0,
    this.title = 'CogniHire',
    this.tagline = 'Verified-claim interviewing',
    this.primaryAction,
    this.identity,
    this.notices = const [],
    this.onSearch,
    this.searchHint = 'Search sessions, candidates, or claims…',
    this.topBarActions = const [],
    this.onHelp,
  });

  final List<ShellDestination> destinations;
  final int initialIndex;
  final String title;

  /// The line under the wordmark. Describes the product, and is deliberately not
  /// "AI-Native Hiring" as the mockup had it — this tool does not make hiring
  /// decisions and its chrome should not imply otherwise.
  final String tagline;

  final ShellPrimaryAction? primaryAction;
  final ShellIdentity? identity;
  final List<ShellNotice> notices;

  /// Invoked when the top-bar search field is submitted. When null the field is
  /// not rendered at all — an inert search box is the worst button on any page.
  final ValueChanged<String>? onSearch;

  final String searchHint;
  final List<Widget> topBarActions;
  final VoidCallback? onHelp;

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

  /// Lets a page hand navigation back to the shell — "open this candidate's
  /// session in the Candidates tab" rather than pushing a route that buries the
  /// rail. Looked up with [AppShellController.of].
  void _goTo(String label) {
    final i = widget.destinations.indexWhere((d) => d.label == label);
    if (i >= 0) _select(i);
  }

  /// A bottom [NavigationBar] cannot hold nine destinations without every label
  /// being clipped to a sliver — Material's own bar assumes three to five. Past
  /// four visible slots the rest collapse into a "More" sheet rather than being
  /// silently squeezed unreadable.
  static const int _maxBottomSlots = 4;

  Widget _bottomBar(BuildContext context) {
    final overflow = widget.destinations.length > _maxBottomSlots;
    final visibleCount =
        overflow ? _maxBottomSlots - 1 : widget.destinations.length;

    // If the currently-selected destination would be pushed into the overflow
    // sheet, show it in the visible slots instead of "More" so the bar never
    // displays as unselected while a real page is open.
    final visible = <int>[];
    if (overflow && _index >= visibleCount) {
      visible.add(_index);
      for (var i = 0; i < widget.destinations.length && visible.length < visibleCount; i++) {
        if (i != _index) visible.add(i);
      }
      visible.sort();
    } else {
      visible.addAll(List.generate(visibleCount, (i) => i));
    }

    final selectedSlot = visible.indexOf(_index);

    return NavigationBar(
      selectedIndex: selectedSlot >= 0 ? selectedSlot : 0,
      onDestinationSelected: (slot) {
        if (overflow && slot == visible.length) {
          _showOverflowSheet(context, visible);
          return;
        }
        _select(visible[slot]);
      },
      destinations: [
        for (final i in visible)
          NavigationDestination(
            icon: Icon(widget.destinations[i].icon),
            selectedIcon: Icon(widget.destinations[i].selectedIcon),
            label: widget.destinations[i].shortLabel ?? widget.destinations[i].label,
          ),
        if (overflow)
          const NavigationDestination(
            icon: Icon(Icons.more_horiz),
            label: 'More',
          ),
      ],
    );
  }

  void _showOverflowSheet(BuildContext context, List<int> shown) {
    final hidden = [
      for (var i = 0; i < widget.destinations.length; i++)
        if (!shown.contains(i)) i,
    ];

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final i in hidden)
              ListTile(
                leading: Icon(widget.destinations[i].icon),
                title: Text(widget.destinations[i].label),
                selected: i == _index,
                onTap: () {
                  Navigator.of(context).pop();
                  _select(i);
                },
              ),
          ],
        ),
      ),
    );
  }

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

    final controller = AppShellController._(
      goTo: _goTo,
      selected: widget.destinations.isEmpty
          ? ''
          : widget.destinations[_index].label,
    );

    if (compact) {
      return _Scope(
        controller: controller,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _TopBar(
                  compact: true,
                  title: widget.title,
                  searchHint: widget.searchHint,
                  onSearch: widget.onSearch,
                  notices: widget.notices,
                  onHelp: widget.onHelp,
                  actions: widget.topBarActions,
                  primaryAction: widget.primaryAction,
                ),
                Expanded(child: body),
              ],
            ),
          ),
          bottomNavigationBar: _bottomBar(context),
        ),
      );
    }

    return _Scope(
      controller: controller,
      child: Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              _Rail(
                index: _index,
                extended: expanded,
                title: widget.title,
                tagline: widget.tagline,
                destinations: widget.destinations,
                onSelected: _select,
                primaryAction: widget.primaryAction,
                identity: widget.identity,
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: Column(
                  children: [
                    _TopBar(
                      compact: false,
                      title: widget.title,
                      searchHint: widget.searchHint,
                      onSearch: widget.onSearch,
                      notices: widget.notices,
                      onHelp: widget.onHelp,
                      actions: widget.topBarActions,
                      primaryAction: null,
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets a screen move the shell to another destination by name.
///
/// Exists so a "view this in Candidates" link inside the dashboard switches tabs
/// instead of pushing a full-screen route on top of the rail — the rail is the
/// map, and losing it to see a neighbouring page is the navigation problem the
/// shell was built to fix.
class AppShellController {
  const AppShellController._({required this.goTo, required this.selected});

  final void Function(String destinationLabel) goTo;

  /// The label of the destination currently on screen.
  final String selected;

  static AppShellController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Scope>()?.controller;
}

class _Scope extends InheritedWidget {
  const _Scope({required this.controller, required super.child});

  final AppShellController controller;

  @override
  bool updateShouldNotify(_Scope old) =>
      old.controller.selected != controller.selected;
}

// ---------------------------------------------------------------------------
// Rail
// ---------------------------------------------------------------------------

class _Rail extends StatelessWidget {
  const _Rail({
    required this.index,
    required this.extended,
    required this.title,
    required this.tagline,
    required this.destinations,
    required this.onSelected,
    required this.primaryAction,
    required this.identity,
  });

  final int index;
  final bool extended;
  final String title;
  final String tagline;
  final List<ShellDestination> destinations;
  final ValueChanged<int> onSelected;
  final ShellPrimaryAction? primaryAction;
  final ShellIdentity? identity;

  /// Must match [NavigationRail.minExtendedWidth] below, and Material's own
  /// collapsed rail width, or the leading and trailing blocks would not line up
  /// with the destinations between them.
  static const double _extendedWidth = 252;
  static const double _collapsedWidth = 72;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      extended: extended,
      minExtendedWidth: _extendedWidth,
      labelType:
          extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
      // NavigationRail lays its leading and trailing slots out with an
      // unbounded width, so a stretch Column inside either one asserts. Both
      // are pinned to the rail's own width instead.
      leading: SizedBox(
        width: extended ? _extendedWidth : _collapsedWidth,
        child: Padding(
          padding: EdgeInsets.only(
            top: Spacing.lg,
            bottom: Spacing.xl,
            left: extended ? Spacing.md : Spacing.sm,
            right: extended ? Spacing.md : Spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Wordmark(extended: extended, title: title, tagline: tagline),
              if (primaryAction != null) ...[
                const SizedBox(height: Spacing.xl),
                _RailAction(action: primaryAction!, extended: extended),
              ],
            ],
          ),
        ),
      ),
      // Expanded pushes the footer to the bottom of the column; without it the
      // trailing block sits immediately under the last destination.
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: identity == null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: extended ? _extendedWidth : _collapsedWidth,
                  child: _RailFooter(identity: identity!, extended: extended),
                ),
        ),
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

/// The sidebar CTA. A gold-filled control with an explicit hover state, built
/// from an [InkWell] rather than a [FilledButton] — see [ShellPrimaryAction].
class _RailAction extends StatelessWidget {
  const _RailAction({required this.action, required this.extended});

  final ShellPrimaryAction action;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final content = extended
        ? Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, size: 18, color: scheme.onTertiary),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  action.label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onTertiary,
                      ),
                ),
              ),
            ],
          )
        : Icon(action.icon, size: 20, color: scheme.onTertiary);

    return Tooltip(
      message: extended ? '' : action.label,
      child: Material(
        color: scheme.tertiary,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          onTap: action.onPressed,
          borderRadius: BorderRadius.circular(Radii.control),
          child: Container(
            height: 46,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
              horizontal: extended ? Spacing.md : 0,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.identity, required this.extended});

  final ShellIdentity identity;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final avatar = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondary.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.person_outline, size: 17, color: scheme.secondary),
    );

    final body = extended
        ? Row(
            children: [
              avatar,
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      identity.name,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      identity.role,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          )
        : avatar;

    return Column(
      children: [
        const Divider(height: 1, thickness: 1),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.md,
          ),
          child: Tooltip(
            message: extended ? '' : '${identity.name} — ${identity.role}',
            child: InkWell(
              onTap: identity.onTap,
              borderRadius: BorderRadius.circular(Radii.control),
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: body,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({
    required this.extended,
    required this.title,
    required this.tagline,
  });

  final bool extended;
  final String title;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mark = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Icon(
        Icons.verified_outlined,
        color: theme.colorScheme.onPrimary,
        size: 20,
      ),
    );

    if (!extended) return Center(child: mark);

    return Row(
      children: [
        mark,
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                tagline.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends StatefulWidget {
  const _TopBar({
    required this.compact,
    required this.title,
    required this.searchHint,
    required this.onSearch,
    required this.notices,
    required this.onHelp,
    required this.actions,
    required this.primaryAction,
  });

  final bool compact;
  final String title;
  final String searchHint;
  final ValueChanged<String>? onSearch;
  final List<ShellNotice> notices;
  final VoidCallback? onHelp;
  final List<Widget> actions;

  /// On a compact window the sidebar is gone, so the primary action moves here.
  final ShellPrimaryAction? primaryAction;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    widget.onSearch?.call(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final trailing = <Widget>[
      if (widget.notices.isNotEmpty || !widget.compact)
        _NoticeBell(notices: widget.notices),
      if (widget.onHelp != null)
        IconButton(
          onPressed: widget.onHelp,
          tooltip: 'What this tool does and does not claim',
          icon: const Icon(Icons.help_outline, size: 20),
        ),
      ...widget.actions,
      if (widget.primaryAction != null)
        IconButton(
          onPressed: widget.primaryAction!.onPressed,
          tooltip: widget.primaryAction!.label,
          icon: Icon(widget.primaryAction!.icon, size: 20),
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? Spacing.md : Spacing.xl,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          if (widget.onSearch != null)
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _search,
                    onSubmitted: _submit,
                    textInputAction: TextInputAction.search,
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.searchHint,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      // Pill, per the mockup's search treatment.
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        borderSide: BorderSide(color: scheme.outlineVariant),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        borderSide:
                            BorderSide(color: scheme.tertiary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: Text(widget.title, style: theme.textTheme.titleMedium),
            ),
          const SizedBox(width: Spacing.sm),
          // Wrap so a narrow window folds the actions onto a second line rather
          // than overflowing them off the right edge.
          Flexible(
            flex: 0,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Spacing.xs,
              children: trailing,
            ),
          ),
        ],
      ),
    );
  }
}

/// The notification bell.
///
/// Shows a count only when there is something to count, and its menu lists real
/// detected conditions. An always-on dot — which the mockup had — trains the
/// user to ignore it.
class _NoticeBell extends StatelessWidget {
  const _NoticeBell({required this.notices});

  final List<ShellNotice> notices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final icon = Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.notifications_none, size: 20),
        if (notices.isNotEmpty)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.error,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(
                '${notices.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onError,
                  fontSize: 9,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
      ],
    );

    if (notices.isEmpty) {
      return IconButton(
        tooltip: 'Nothing needs attention',
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nothing needs attention right now.'),
          ),
        ),
        icon: icon,
      );
    }

    return PopupMenuButton<int>(
      tooltip: '${notices.length} thing(s) need attention',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 420),
      onSelected: (i) => notices[i].onTap?.call(),
      itemBuilder: (context) => [
        for (var i = 0; i < notices.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: notices[i].onTap != null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (notices[i].tone) {
                    ShellNoticeTone.info => Icons.info_outline,
                    ShellNoticeTone.caution => Icons.warning_amber,
                    ShellNoticeTone.fault => Icons.error_outline,
                  },
                  size: 16,
                  color: switch (notices[i].tone) {
                    ShellNoticeTone.info => scheme.onSurfaceVariant,
                    ShellNoticeTone.caution => context.evidence.unmeasured,
                    ShellNoticeTone.fault => scheme.error,
                  },
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(notices[i].title, style: theme.textTheme.titleSmall),
                      Text(
                        notices[i].detail,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: icon,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page frame
// ---------------------------------------------------------------------------

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
              child: _header(theme, compact),
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

  /// The title block and actions, laid out for the available width rather than
  /// hoping they fit.
  ///
  /// On a wide window this is one row: title on the left with `Expanded`,
  /// actions on the right in a `Wrap`. That is fine because there is width to
  /// spare.
  ///
  /// On a compact window it is NOT the same row with things squeezed — `Row`
  /// gives every non-flexible child (the actions `Wrap`) however much width it
  /// *wants* before the `Expanded` title gets whatever is left. A title next to
  /// actions that need most of a narrow row can be squeezed to a sliver a few
  /// pixels wide, wrapping "Good afternoon" letter-by-letter into hundreds of
  /// vertical pixels — a real overflow this shape produced, not a hypothetical
  /// one. Stacking the actions under the title instead means the title always
  /// gets the row's full width and the actions get their own, separate line to
  /// spread across.
  Widget _header(ThemeData theme, bool compact) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: Spacing.xs),
          Text(subtitle!, style: theme.textTheme.bodySmall),
        ],
      ],
    );

    if (actions.isEmpty) return titleBlock;

    final actionsRow = Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      alignment: compact ? WrapAlignment.start : WrapAlignment.end,
      children: actions,
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleBlock,
          const SizedBox(height: Spacing.md),
          actionsRow,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: titleBlock),
        const SizedBox(width: Spacing.md),
        actionsRow,
      ],
    );
  }
}
