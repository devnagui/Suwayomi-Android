import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../utils/extensions/custom_extensions.dart';
import '../../../utils/network/reader_read_ahead.dart';

class ReadAheadSummary extends ConsumerWidget {
  const ReadAheadSummary({super.key, required this.mangaId});

  final int mangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref
        .watch(readerReadAheadProvider)
        .values
        .where((status) => status.chapter.mangaId == mangaId)
        .toList();
    final recent = all.reversed.take(readerReadAheadCount).toList().reversed;
    final important = all
        .where((status) =>
            status.phase != ReadAheadPhase.waiting &&
            status.phase != ReadAheadPhase.ready &&
            status.phase != ReadAheadPhase.cancelled)
        .toList();
    final statuses = [
      ...important,
      ...recent.where((status) => !important.contains(status)),
    ].take(readerReadAheadCount);
    if (statuses.isEmpty) return const SizedBox.shrink();

    final l10n = context.l10n;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.readAheadTitle,
                style: Theme.of(context).textTheme.titleSmall),
            for (final status in statuses) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    switch (status.phase) {
                      ReadAheadPhase.ready => Icons.offline_pin_outlined,
                      ReadAheadPhase.failed => Icons.error_outline,
                      ReadAheadPhase.paused => Icons.pause_circle_outline,
                      _ => Icons.download_for_offline_outlined,
                    },
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(status.chapter.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          [
                            switch (status.phase) {
                              ReadAheadPhase.waiting => l10n.readAheadWaiting,
                              ReadAheadPhase.requesting =>
                                l10n.readAheadRequesting,
                              ReadAheadPhase.downloading =>
                                l10n.readAheadDownloading,
                              ReadAheadPhase.copying => l10n.readAheadCopying,
                              ReadAheadPhase.retrying => l10n.readAheadRetrying,
                              ReadAheadPhase.paused => l10n.readAheadPaused,
                              ReadAheadPhase.ready => l10n.readAheadReady,
                              ReadAheadPhase.failed => l10n.readAheadFailed,
                              ReadAheadPhase.cancelled =>
                                l10n.readAheadCancelled,
                            },
                            if (status.progress != null &&
                                (status.phase == ReadAheadPhase.downloading ||
                                    status.phase == ReadAheadPhase.copying))
                              '${(status.progress!.clamp(0.0, 1.0) * 100).round()}%',
                            if (status.attempt > 1)
                              l10n.readAheadAttempt(status.attempt),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (status.phase == ReadAheadPhase.failed)
                    TextButton(
                      onPressed: () => ref
                          .read(readerReadAheadProvider.notifier)
                          .retry(status.chapter.id),
                      child: Text(l10n.retry),
                    ),
                ],
              ),
              if (status.phase == ReadAheadPhase.requesting ||
                  status.phase == ReadAheadPhase.downloading ||
                  status.phase == ReadAheadPhase.copying ||
                  status.phase == ReadAheadPhase.retrying)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(
                    value: status.progress?.clamp(0.0, 1.0).toDouble(),
                    semanticsLabel: status.chapter.name,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
