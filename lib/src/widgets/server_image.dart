// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../constants/app_sizes.dart';
import '../constants/endpoints.dart';
import '../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../utils/extensions/custom_extensions.dart';
import '../utils/misc/app_utils.dart';
import '../utils/network/auth_headers.dart';
import '../utils/network/manga_cache_manager.dart';
import 'custom_circular_progress_indicator.dart';

class ServerImage extends HookConsumerWidget {
  const ServerImage({
    super.key,
    required this.imageUrl,
    this.size,
    this.fit,
    this.appendApiToUrl = false,
    this.progressIndicatorBuilder,
    this.wrapper,
    this.showReloadButton = false,
  });

  final String imageUrl;
  final Size? size;
  final BoxFit? fit;
  final bool appendApiToUrl;
  final Widget Function(BuildContext, String, DownloadProgress)?
      progressIndicatorBuilder;
  final Widget Function(Widget child)? wrapper;
  final bool showReloadButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = useState(UniqueKey());
    // Providers
    final httpHeaders = ref.watch(serverAuthHeadersProvider);

    final baseApi = "${Endpoints.baseApi(
      baseUrl: ref.watch(serverUrlProvider),
      port: ref.watch(serverPortProvider),
      addPort: ref.watch(serverPortToggleProvider).ifNull(),
      appendApiToUrl: appendApiToUrl,
    )}"
        "$imageUrl";

    finalProgressIndicatorBuilder(
            BuildContext context, String url, DownloadProgress progress) =>
        AppUtils.wrapOn(
          wrapper,
          progressIndicatorBuilder?.call(context, url, progress) ??
              const CenterSorayomiShimmerIndicator(),
        );

    Widget errorWidget(BuildContext context, String error, stackTrace) {
      if (showReloadButton) {
        return AppUtils.wrapOn(
          wrapper,
          Padding(
            padding: KEdgeInsets.a8.size,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.broken_image_rounded,
                    color: Colors.grey,
                  ),
                  const Gap(32),
                  TextButton(
                    onPressed: () {
                      key.value = (UniqueKey());
                    },
                    child: Text(context.l10n.reload),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        return AppUtils.wrapOn(
          wrapper,
          const Icon(
            Icons.broken_image_rounded,
            color: Colors.grey,
          ),
        );
      }
    }

    return CachedNetworkImage(
      key: key.value,
      imageUrl: baseApi,
      height: size?.height,
      cacheManager: ref.watch(mangaCacheManagerProvider),
      httpHeaders: httpHeaders,
      width: size?.width,
      fit: fit ?? BoxFit.cover,
      progressIndicatorBuilder: finalProgressIndicatorBuilder,
      errorWidget: errorWidget,
    );
  }
}

class ServerImageWithCpi extends StatelessWidget {
  const ServerImageWithCpi({
    super.key,
    required this.url,
    required this.outerSize,
    required this.innerSize,
    required this.isLoading,
  });
  final bool isLoading;
  final Size outerSize;
  final Size innerSize;
  final String url;
  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return SizedBox.fromSize(
        size: outerSize,
        child: Stack(
          alignment: AlignmentDirectional.center,
          children: [
            const Padding(
              padding: EdgeInsets.all(4.0),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            ServerImage(
              imageUrl: url,
              size: innerSize,
              progressIndicatorBuilder: (context, url, progress) =>
                  const CenterSorayomiShimmerIndicator(),
            )
          ],
        ),
      );
    } else {
      return ServerImage(imageUrl: url, size: outerSize);
    }
  }
}
