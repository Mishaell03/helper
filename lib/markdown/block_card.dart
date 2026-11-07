import 'package:flutter/material.dart';

import 'models.dart';

enum BlockAction { copy, pin, delete, type }

class BlockCard extends StatelessWidget {
  const BlockCard({
    super.key,
    required this.block,
    required this.selected,
    required this.showDescriptions,
    required this.enabled,
    required this.onOpen,
    required this.onAction,
    this.onStop,
    this.automationStatus,
    this.canAutomate = false,
  });

  static const extent = 94.0;
  final BlockSummary block;
  final bool selected;
  final bool showDescriptions;
  final bool enabled;
  final VoidCallback onOpen;
  final ValueChanged<BlockAction> onAction;
  final VoidCallback? onStop;
  final String? automationStatus;
  final bool canAutomate;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      selected: selected,
      button: true,
      hint: 'Enter — открыть, Ctrl+C — копировать',
      label: '${block.displayTitle}${block.pinned ? ', закреплён' : ''}',
      child: Material(
        color: Colors.white.withValues(alpha: selected ? 0.075 : 0.035),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(5),
          side: BorderSide(
            color: selected
                ? const Color(0xFF7A8598)
                : Colors.white.withValues(alpha: 0.12),
            width: selected ? 1.3 : 0.7,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        block.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: PopupMenuButton<BlockAction>(
                        tooltip: 'Действия с блоком',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        constraints: const BoxConstraints(minWidth: 150),
                        enabled: enabled,
                        icon: const Icon(Icons.more_horiz),
                        onSelected: onAction,
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: BlockAction.copy,
                            child: Text('Копировать'),
                          ),
                          if (canAutomate)
                            const PopupMenuItem(
                              value: BlockAction.type,
                              child: Text('Начать ввод…'),
                            ),
                          PopupMenuItem(
                            value: BlockAction.pin,
                            child: Text(
                              block.pinned ? 'Открепить' : 'Закрепить',
                            ),
                          ),
                          const PopupMenuItem(
                            value: BlockAction.delete,
                            child: Text('Удалить'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Text(
                    showDescriptions && block.description.isNotEmpty
                        ? block.description
                        : block.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: automationStatus == null
                          ? const SizedBox.shrink()
                          : Text(
                              automationStatus!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 10,
                              ),
                            ),
                    ),
                    if (onStop != null)
                      IconButton(
                        tooltip: 'Остановить ввод блока',
                        onPressed: onStop,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 24,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.stop, size: 16),
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 24,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      tooltip: block.pinned ? 'Открепить' : 'Закрепить',
                      onPressed: enabled
                          ? () => onAction(BlockAction.pin)
                          : null,
                      icon: Icon(
                        block.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                        color: block.pinned ? Colors.white : Colors.white60,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
