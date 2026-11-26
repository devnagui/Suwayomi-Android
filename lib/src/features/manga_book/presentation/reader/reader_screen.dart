// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../constants/enum.dart';
import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/logger/operation_log.dart';
import '../../../../utils/misc/toast/toast.dart';
import '../../../../utils/network/reader_read_ahead.dart';
import '../../../../utils/network/reading_progress.dart';
import '../../../settings/presentation/reader/widgets/reader_ignore_safe_area_tile/reader_ignore_safe_area_tile.dart';
import '../../../settings/presentation/reader/widgets/reader_mode_tile/reader_mode_tile.dart';
import '../../../settings/presentation/reader/widgets/reader_smart_download_tile/reader_smart_download_tile.dart';
import '../../domain/manga/manga_model.dart';
import '../manga_details/controller/manga_details_controller.dart';
import 'controller/reader_controller.dart';
import 'offline_reader_provider.dart';
import 'widgets/reader_mode/continuous_reader_mode.dart';
import 'widgets/reader_mode/single_page_reader_mode.dart';

class ReaderScreen extends HookConsumerWidget {
  const ReaderScreen({
    super.key,
    required this.mangaId,
    required this.chapterId,
    this.showReaderLayoutAnimation = false,
  });
  final int mangaId;
  final int chapterId;
  final bool showReaderLayoutAnimation;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mangaProvider = mangaWithIdProvider(mangaId: mangaId);
    final chapterProviderWithIndex = chapterProvider(chapterId: chapterId);
    final chapterPages = ref.watch(chapterPagesProvider(chapterId: chapterId));
    final manga = ref.watch(mangaProvider);
    final chapter = ref.watch(chapterProviderWithIndex);
    final defaultReaderMode = ref.watch(readerModeKeyProvider);
    final ignoreSafeArea = ref.watch(readerIgnoreSafeAreaProvider).ifNull();

    // Check for offline pages
    final offlinePagesAsync = ref.watch(
      offlineChapterPagesProvider(mangaId: mangaId, chapterId: chapterId),
    );
    final offlineFiles = offlinePagesAsync.valueOrNull;

    final smartDownloadEnabled = ref.watch(smartDownloadNextChapterProvider);
    final chapterPagesLoaded =
        chapterPages.valueOrNull?.pages.isNotEmpty == true ||
            offlineFiles?.isNotEmpty == true;
    useEffect(() {
      if (!smartDownloadEnabled) return null;
      if (!chapterPagesLoaded) return null;
      var active = true;
      Future.microtask(() {
        if (active) {
          unawaited(ref
              .read(readerReadAheadProvider.notifier)
              .request(mangaId, chapterId));
        }
      });
      return () => active = false;
    }, [smartDownloadEnabled, mangaId, chapterId, chapterPagesLoaded]);

    final progress = ref.watch(readingProgressProvider.notifier);
    final progressScope = ref.watch(readingProgressScopeProvider);
    final toast = ref.watch(toastProvider);
    final saveFailureText = context.l10n.readingProgressSaveFailed;
    final recorded = useRef<(int, int)?>(null);
    final onlinePageCount = chapterPages.valueOrNull?.pages.length ?? 0;
    final pageCount =
        onlinePageCount > 0 ? onlinePageCount : offlineFiles?.length ?? 0;
    final onPageChanged =
        useCallback<AsyncValueSetter<int>>((int currentPage) async {
      await Future<void>.value();
      if (!context.mounted) return;
      final chapterValue = chapter.valueOrNull;
      if (chapterValue == null ||
          pageCount <= 0 ||
          recorded.value == (chapterId, currentPage)) {
        return;
      }
      recorded.value = (chapterId, currentPage);
      try {
        if (progressScope == null) {
          throw StateError('Reading account is not configured');
        }
        await progress.record(chapterValue, currentPage, pageCount,
            serverLatest: manga.valueOrNull?.lastReadChapter,
            expectedScope: progressScope);
      } catch (error, stackTrace) {
        recorded.value = null;
        OperationLog.instance.record('ReadingProgress',
            outcome: 'save_failed',
            chapterId: chapterId,
            error: error,
            stackTrace: stackTrace);
        if (context.mounted) toast?.showError(saveFailureText);
      }
    }, [
      chapter.valueOrNull,
      pageCount,
      manga.valueOrNull,
      progress,
      progressScope,
      toast,
      saveFailureText
    ]);

    useEffect(() {
      if (chapter.valueOrNull == null || pageCount <= 0) return null;
      var active = true;
      final initialPage =
          progress.startingPage(chapter.valueOrNull!).clamp(0, pageCount - 1);
      Future.microtask(() {
        if (active) unawaited(onPageChanged(initialPage));
      });
      return () => active = false;
    }, [chapterId, pageCount, progressScope]);

    useEffect(
        () => () {
              unawaited(progress.flush());
            },
        [progress]);

    useEffect(() {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return () => SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: SystemUiOverlay.values,
          );
    }, []);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          unawaited(progress.flush());
          ref.invalidate(chapterProviderWithIndex);
          ref.invalidate(mangaChapterListProvider(mangaId: mangaId));
        }
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SafeArea(
          top: !ignoreSafeArea,
          bottom: !ignoreSafeArea,
          left: !ignoreSafeArea,
          right: !ignoreSafeArea,
          child: manga.showUiWhenData(
            context,
            (data) {
              if (data == null) return const SizedBox.shrink();
              return chapter.showUiWhenData(
                context,
                (chapterData) {
                  if (chapterData == null) return const SizedBox.shrink();
                  return chapterPages.showUiWhenData(
                    context,
                    (chapterPagesData) {
                      if (chapterPagesData == null) {
                        return const SizedBox.shrink();
                      }
                      return switch (
                          data.metaData.readerMode ?? defaultReaderMode) {
                        ReaderMode.singleVertical => SinglePageReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            scrollDirection: Axis.vertical,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.singleHorizontalRTL => SinglePageReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            reverse: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.continuousHorizontalLTR =>
                          ContinuousReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            scrollDirection: Axis.horizontal,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.continuousHorizontalRTL =>
                          ContinuousReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.singleHorizontalLTR => SinglePageReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.continuousVertical => ContinuousReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            showSeparator: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.webtoon => ContinuousReaderMode(
                            chapter: chapterData,
                            manga: data,
                            onPageChanged: onPageChanged,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,
                            chapterPages: chapterPagesData,
                            offlineFiles: offlineFiles,
                          ),
                        ReaderMode.defaultReader || null => switch (
                              defaultReaderMode ?? ReaderMode.webtoon) {
                            ReaderMode.singleHorizontalLTR =>
                              SinglePageReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.singleHorizontalRTL =>
                              SinglePageReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                reverse: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.singleVertical => SinglePageReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                scrollDirection: Axis.vertical,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.continuousHorizontalLTR =>
                              ContinuousReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                scrollDirection: Axis.horizontal,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.continuousHorizontalRTL =>
                              ContinuousReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                scrollDirection: Axis.horizontal,
                                reverse: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.continuousVertical =>
                              ContinuousReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                showSeparator: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                            ReaderMode.webtoon || _ => ContinuousReaderMode(
                                chapter: chapterData,
                                manga: data,
                                onPageChanged: onPageChanged,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,
                                chapterPages: chapterPagesData,
                                offlineFiles: offlineFiles,
                              ),
                          }
                      };
                    },
                  );
                },
                refresh: () => ref.refresh(chapterProviderWithIndex.future),
                addScaffoldWrapper: true,
              );
            },
            addScaffoldWrapper: true,
            refresh: () => ref.refresh(mangaProvider.future),
          ),
        ),
      ),
    );
  }
}
