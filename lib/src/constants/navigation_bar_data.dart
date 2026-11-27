// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../utils/extensions/custom_extensions.dart';

class NavigationBarData {
  final String Function(BuildContext context) label;
  final IconData icon;
  final IconData activeIcon;

  // Static list for phone/small screens (History under More)
  static final phoneNavList = [
    NavigationBarData(
      icon: Icons.collections_bookmark_outlined,
      activeIcon: Icons.collections_bookmark_rounded,
      label: (context) => context.l10n.library,
    ),
    NavigationBarData(
      icon: Icons.new_releases_outlined,
      activeIcon: Icons.new_releases_rounded,
      label: (context) => context.l10n.activity,
    ),
    NavigationBarData(
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore_rounded,
      label: (context) => context.l10n.browse,
    ),
    NavigationBarData(
      icon: Icons.more_horiz_outlined,
      activeIcon: Icons.more_horiz_rounded,
      label: (context) => context.l10n.more,
    ),
  ];

  // Static list for tablet/large screens (History between Activity and Browse)
  static final tabletNavList = [
    NavigationBarData(
      icon: Icons.collections_bookmark_outlined,
      activeIcon: Icons.collections_bookmark_rounded,
      label: (context) => context.l10n.library,
    ),
    NavigationBarData(
      icon: Icons.new_releases_outlined,
      activeIcon: Icons.new_releases_rounded,
      label: (context) => context.l10n.activity,
    ),
    NavigationBarData(
      icon: Icons.history_outlined,
      activeIcon: Icons.history_rounded,
      label: (context) => context.l10n.history,
    ),
    NavigationBarData(
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore_rounded,
      label: (context) => context.l10n.browse,
    ),
    NavigationBarData(
      icon: Icons.more_horiz_outlined,
      activeIcon: Icons.more_horiz_rounded,
      label: (context) => context.l10n.more,
    ),
  ];

  // Dynamic navigation list based on context
  static List<NavigationBarData> getNavList(BuildContext context) {
    return context.isTablet ? tabletNavList : phoneNavList;
  }

  // Legacy navList for backward compatibility - defaults to phone layout
  static final navList = phoneNavList;

  // Shell branches: Library, Activity, History, Browse, More.
  static const phoneBranchIndices = [0, 1, 3, 4];
  static const tabletBranchIndices = [0, 1, 2, 3, 4];

  static int branchIndexForDestination(int index, {required bool isTablet}) =>
      (isTablet ? tabletBranchIndices : phoneBranchIndices)[index];

  static int destinationIndexForBranch(int index, {required bool isTablet}) {
    final indices = isTablet ? tabletBranchIndices : phoneBranchIndices;
    final destination = indices.indexOf(index);
    // Phone History deep links belong to More.
    return destination == -1 ? indices.indexOf(4) : destination;
  }

  NavigationBarData({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}
