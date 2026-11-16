import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_input_activation.dart';
import 'automation_controls.dart';
import 'text_automation.dart';

/// Public editor: contents belong to the current session, never to a file/DB.
class DraftEditor extends StatelessWidget {
  const DraftEditor({
    super.key,
    required this.text,
    required this.automation,
    required this.onStart,
    this.enabled = true,
  });

  final TextEditingController text;
  final TextAutomationController? automation;
  final VoidCallback onStart;
  final bool enabled;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: text,
    builder: (context, value, _) {
      final controller = automation;
      final editing =
          enabled &&
          !(controller?.protects(TextAutomationController.draftBlockId) ??
              false) &&
          !(controller?.commandPending ?? false);
      return ListView(
        key: const Key('draftEditor'),
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Текст и код',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Вставьте или напишите текст. Он хранится только до выхода из приложения, '
            'без файла и без записи в базу.',
            style: TextStyle(fontSize: 11, color: Colors.white60),
          ),
          const SizedBox(height: 8),
          TextInputActivation(
            child: TextField(
              key: const Key('draftText'),
              controller: text,
              enabled: editing,
              minLines: 8,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'Текст для автоввода',
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: editing
                    ? () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (context.mounted &&
                            !(controller?.protects(
                                  TextAutomationController.draftBlockId,
                                ) ??
                                false) &&
                            !(controller?.commandPending ?? false)) {
                          text.value = TextEditingValue(
                            text: data?.text ?? '',
                            selection: TextSelection.collapsed(
                              offset: data?.text?.length ?? 0,
                            ),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.content_paste, size: 16),
                label: const Text('Вставить'),
              ),
              TextButton(
                onPressed: editing && value.text.isNotEmpty ? text.clear : null,
                child: const Text('Очистить'),
              ),
            ],
          ),
          if (controller != null) ...[
            TypingSpeedSettings(controller: controller, enabled: enabled),
            TextButton.icon(
              onPressed:
                  enabled && controller.canStart && value.text.trim().isNotEmpty
                  ? onStart
                  : null,
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Начать ввод через 5 с'),
            ),
            const Text(
              'Выберите целевое окно во время отсчёта. Горячая клавиша запуска — '
              'через 1 с. Пауза и стоп доступны снизу и по горячим клавишам. '
              'Во время операции редактирование заблокировано; остановите ввод, '
              'чтобы изменить текст.',
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ] else
            const Text('Автоввод доступен в Windows.'),
        ],
      );
    },
  );
}
