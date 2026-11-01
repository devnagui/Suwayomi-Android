import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../global_providers/global_providers.dart';
import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/logger/operation_log.dart';
import '../../data/local_cache_repository.dart';

class LocalCacheActions extends HookConsumerWidget {
  const LocalCacheActions({super.key, this.mangaId});

  final int? mangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final l10n = context.l10n;

    Future<void> perform(
      String title,
      String description,
      Future<int> Function() action,
      String Function(int) success,
    ) async {
      if (busy.value) return;
      busy.value = true;
      try {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(title),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        final result = await AsyncValue.guard(action);
        if (!context.mounted) return;
        if (result.hasError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.error.toString())),
          );
          return;
        }
        ref.invalidate(graphQlClientProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(success(result.requireValue))),
        );
        if (mangaId != null) await Navigator.of(context).maybePop();
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    final repository = ref.watch(localCacheRepositoryProvider);
    if (mangaId != null) {
      return IconButton(
        tooltip: l10n.forgetLocalManga,
        icon: busy.value
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.cleaning_services_rounded),
        onPressed: busy.value
            ? null
            : () => perform(
                  l10n.forgetLocalManga,
                  l10n.forgetLocalMangaDescription,
                  () => repository.forgetManga(mangaId!),
                  (_) => l10n.localMangaForgotten,
                ),
      );
    }

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.cleaning_services_rounded),
          title: Text(l10n.clearCache),
          subtitle: Text(l10n.clearLocalCacheDescription),
          enabled: !busy.value,
          trailing: busy.value
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: () => perform(
            l10n.clearCache,
            l10n.clearLocalCacheDescription,
            repository.clearLocalCache,
            (_) => l10n.cacheCleared,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.link_off_rounded),
          title: Text(l10n.removeMissingMangaLinks),
          subtitle: Text(l10n.removeMissingMangaLinksDescription),
          enabled: !busy.value,
          onTap: () => perform(
            l10n.removeMissingMangaLinks,
            l10n.removeMissingMangaLinksDescription,
            repository.removeMissingMangaLinks,
            l10n.localMangaLinksRemoved,
          ),
        ),
      ],
    );
  }
}

class OperationLogTile extends StatelessWidget {
  const OperationLogTile({super.key, this.operationLog, this.compact = false});

  final OperationLog? operationLog;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final log = operationLog ?? OperationLog.instance;
    final l10n = context.l10n;
    void openLog() => showDialog(
          context: context,
          builder: (context) => ValueListenableBuilder<List<String>>(
            valueListenable: log,
            builder: (context, entries, _) => AlertDialog(
              title: Text(l10n.operationLog),
              content: SizedBox(
                width: 600,
                height: MediaQuery.sizeOf(context).height * 0.5,
                child: SingleChildScrollView(
                  child: SelectableText(
                    entries.isEmpty
                        ? l10n.noOperationsLogged
                        : log.exportText(),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: entries.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                              ClipboardData(text: log.exportText()));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.copied)),
                          );
                        },
                  child: Text(l10n.copyOperationLog),
                ),
                TextButton(
                  onPressed: entries.isEmpty
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(l10n.clearOperationLog),
                              content: Text(l10n.clearOperationLogDescription),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: Text(l10n.cancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: Text(l10n.clearOperationLog),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) log.clear();
                        },
                  child: Text(l10n.clearOperationLog),
                ),
                TextButton(
                  onPressed: entries.isEmpty
                      ? null
                      : () async {
                          final result = await AsyncValue.guard(
                              () => FilePicker.platform.saveFile(
                                    dialogTitle: l10n.exportOperationLog,
                                    fileName: 'suwayomi-android-operations.txt',
                                    type: FileType.custom,
                                    allowedExtensions: ['txt'],
                                    bytes: Uint8List.fromList(
                                        utf8.encode(log.exportText())),
                                  ));
                          if (!context.mounted) return;
                          if (result.hasError) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(result.error.toString())),
                            );
                          } else if (result.valueOrNull != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(l10n.operationLogExported)),
                            );
                          }
                        },
                  child: Text(l10n.exportOperationLog),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.close),
                ),
              ],
            ),
          ),
        );
    return compact
        ? IconButton(
            tooltip: l10n.operationLog,
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: openLog,
          )
        : ListTile(
            leading: const Icon(Icons.receipt_long_rounded),
            title: Text(l10n.operationLog),
            subtitle: Text(l10n.operationLogDescription),
            onTap: openLog,
          );
  }
}
