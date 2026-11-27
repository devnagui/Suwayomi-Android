part of '../router_config.dart';

class ActivityBranch extends StatefulShellBranchData {
  const ActivityBranch();

  static final $initialLocation = const UpdatesRoute().location;
}

class ActivityShellRoute extends StatefulShellRouteData {
  const ActivityShellRoute();

  @override
  Widget builder(context, state, navigationShell) => ActivityScreen(
        currentIndex: navigationShell.currentIndex,
        onSectionSelected: (index) => navigationShell.goBranch(index),
        child: navigationShell,
      );
}

class ActivityRoute extends GoRouteData {
  const ActivityRoute();

  @override
  String redirect(context, state) => const UpdatesRoute().location;
}
