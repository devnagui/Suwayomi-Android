import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../../utils/extensions/custom_extensions.dart';

// Both sections keep their own navigator, scroll position and selection state.
class ActivityScreen extends InheritedWidget {
  const ActivityScreen({
    super.key,
    required this.currentIndex,
    required this.onSectionSelected,
    required super.child,
  });

  final int currentIndex;
  final ValueChanged<int> onSectionSelected;

  static ActivityScreen? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ActivityScreen>();

  @override
  bool updateShouldNotify(ActivityScreen oldWidget) =>
      currentIndex != oldWidget.currentIndex ||
      onSectionSelected != oldWidget.onSectionSelected;
}

class ActivityTabs extends HookWidget implements PreferredSizeWidget {
  const ActivityTabs({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    final activity = ActivityScreen.maybeOf(context)!;
    final controller = useTabController(
      initialLength: 2,
      initialIndex: activity.currentIndex,
    );
    useEffect(() {
      controller.index = activity.currentIndex;
      return null;
    }, [activity.currentIndex]);
    return TabBar(
      controller: controller,
      onTap: activity.onSectionSelected,
      tabs: [
        Tab(text: context.l10n.updates),
        Tab(text: context.l10n.downloads),
      ],
    );
  }
}
