import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../utils/extensions/custom_extensions.dart';
import '../data/updates/updates_repository.dart';

class StopUpdatesButton extends HookConsumerWidget {
  const StopUpdatesButton({super.key, this.mangaId});

  final int? mangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final running = mangaId != null ||
        (ref.watch(updatesSocketProvider).valueOrNull?.isRunning ??
            ref.watch(updateSummaryProvider).valueOrNull?.isRunning ??
            false);
    final label = mangaId == null
        ? context.l10n.cancelAllUpdates
        : context.l10n.cancelMangaUpdate;
    return IconButton(
      tooltip: label,
      icon: const Icon(Icons.stop_circle_outlined),
      onPressed: !running || busy.value
          ? null
          : () async {
              final confirmed = mangaId != null ||
                  await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.l10n.cancelAllUpdates),
                          content:
                              Text(context.l10n.cancelAllUpdatesDescription),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.l10n.cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(context.l10n.cancelAllUpdates),
                            ),
                          ],
                        ),
                      ) ==
                      true;
              if (confirmed != true || !context.mounted) return;
              busy.value = true;
              final result = await AsyncValue.guard(
                () => ref
                    .read(updatesRepositoryProvider)
                    .stopUpdates(mangaId: mangaId),
              );
              if (!context.mounted) return;
              busy.value = false;
              if (result.hasError) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                    mangaId != null &&
                            result.error.toString().contains('mangaIds') &&
                            (result.error.toString().contains('defined') ||
                                result.error.toString().contains('Unknown'))
                        ? context.l10n.cancelMangaUpdateUnsupported
                        : result.error.toString(),
                  )),
                );
              } else {
                ref.invalidate(updateSummaryProvider);
              }
            },
    );
  }
}
