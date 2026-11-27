import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/app_sizes.dart';
import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/misc/toast/toast.dart';
import '../../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../../../widgets/emoticons.dart';
import '../../../../../../widgets/input_popup/widgets/text_field_dialog.dart';
import '../../../../controller/server_controller.dart';
import '../../data/browse_settings_repository.dart';

class ExtensionRepositoryScreen extends HookConsumerWidget {
  const ExtensionRepositoryScreen({super.key});
  @override
  Widget build(context, ref) {
    final repository = ref.watch(browseSettingsRepositoryProvider);
    final stores = ref.watch(extensionStoresProvider);
    final isAdding = useState(false);
    final removingStores = useState(<String>{});
    onRefresh() => ref.refresh(extensionStoresProvider.future);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.extensionRepository)),
      floatingActionButton: FloatingActionButton(
        onPressed: isAdding.value
            ? null
            : () async {
                String? newUrl = await showDialog<String?>(
                  context: context,
                  builder: (context) => TextFieldDialog(
                    title: context.l10n.extensionRepository,
                    hintText: context.l10n
                        .enterProp(context.l10n.extensionRepository),
                  ),
                );
                if (newUrl == null) return;
                if (newUrl.isNotBlank && newUrl.isUrl && !isAdding.value) {
                  isAdding.value = true;
                  try {
                    final result = await AsyncValue.guard(
                      () => repository.addExtensionStore(newUrl),
                    );
                    if (context.mounted) {
                      result.showToastOnError(ref.read(toastProvider));
                      if (!result.hasError) {
                        ref.invalidate(extensionStoresProvider);
                      }
                    }
                  } finally {
                    if (context.mounted) isAdding.value = false;
                  }
                } else if (context.mounted) {
                  ref.read(toastProvider)?.showError(context.l10n
                      .invalidProp(context.l10n.extensionRepository));
                }
              },
        child: isAdding.value
            ? const MiniCircularProgressIndicator()
            : const Icon(Icons.add_rounded),
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: stores.showUiWhenData(
          context,
          (repoList) => repoList.isNotBlank
              ? ListView.builder(
                  itemCount: repoList!.length,
                  itemBuilder: (context, index) {
                    final repo = repoList[index];
                    if (repo.isBlank) return const SizedBox.shrink();
                    return Card(
                      margin: KEdgeInsets.a8.size,
                      child: ListTile(
                        title: Text(
                          repo,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.copy_rounded),
                              onPressed: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: repo));
                                if (context.mounted) {
                                  ref
                                      .read(toastProvider)
                                      ?.show(context.l10n.copied);
                                }
                              },
                            ),
                            IconButton(
                              icon: removingStores.value.contains(repo)
                                  ? const MiniCircularProgressIndicator()
                                  : const Icon(Icons.delete_rounded),
                              onPressed: removingStores.value.contains(repo)
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: Text(dialogContext
                                              .l10n.deleteCategoryTitle),
                                          content: Text(repo),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(
                                                dialogContext,
                                                false,
                                              ),
                                              child: Text(
                                                dialogContext.l10n.cancel,
                                              ),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(
                                                dialogContext,
                                                true,
                                              ),
                                              child: Text(
                                                dialogContext.l10n.remove,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true ||
                                          !context.mounted) {
                                        return;
                                      }
                                      removingStores.value = {
                                        ...removingStores.value,
                                        repo,
                                      };
                                      try {
                                        final result = await AsyncValue.guard(
                                          () => repository
                                              .removeExtensionStore(repo),
                                        );
                                        if (context.mounted) {
                                          result.showToastOnError(
                                            ref.read(toastProvider),
                                          );
                                          if (!result.hasError) {
                                            ref.invalidate(
                                              extensionStoresProvider,
                                            );
                                          }
                                        }
                                      } finally {
                                        if (context.mounted) {
                                          removingStores.value = {
                                            ...removingStores.value,
                                          }..remove(repo);
                                        }
                                      }
                                    },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                )
              : Emoticons(
                  title: context.l10n
                      .noPropFound(context.l10n.extensionRepository),
                  subTitle: context.l10n.extensionRepositoryDescription,
                  button: TextButton(
                    onPressed: onRefresh,
                    child: Text(context.l10n.refresh),
                  ),
                ),
          refresh: onRefresh,
        ),
      ),
    );
  }
}
