import 'package:flutter/material.dart';

import 'text_automation.dart';

class TypingSpeedSettings extends StatelessWidget {
  const TypingSpeedSettings({super.key, required this.controller});
  final TextAutomationController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Скорость: ${controller.speed} симв/мин',
          key: const Key('typingSpeed'),
        ),
        SizedBox(
          height: 34,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: Colors.white54,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white70,
            ),
            child: Slider(
              min: 30,
              max: 500,
              divisions: 470,
              value: controller.speed.toDouble(),
              label: '${controller.speed}',
              semanticFormatterCallback: (value) =>
                  '${value.round()} символов в минуту',
              onChanged: controller.ready && !controller.commandPending
                  ? (value) => controller.previewSpeed(value.round())
                  : null,
              onChangeEnd: controller.ready && !controller.commandPending
                  ? (value) => controller.setSpeed(value.round())
                  : null,
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 4,
          children: [
            for (final preset in [
              (80, 'Медленно'),
              (180, 'Обычно'),
              (400, 'Быстро'),
            ])
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: controller.ready && !controller.commandPending
                    ? () => controller.setSpeed(preset.$1)
                    : null,
                child: Text(preset.$2),
              ),
          ],
        ),
      ],
    ),
  );
}

class AutomationControls extends StatelessWidget {
  const AutomationControls({
    super.key,
    required this.controller,
    required this.blockId,
  });
  final TextAutomationController controller;
  final int blockId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final active = controller.protects(blockId);
      final phase = controller.state.phase;
      final restart =
          controller.state.blockId == blockId &&
          (phase == AutomationPhase.stopped ||
              phase == AutomationPhase.completed ||
              phase == AutomationPhase.error);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TypingSpeedSettings(controller: controller),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (!active)
                OutlinedButton.icon(
                  onPressed: controller.canStart
                      ? () => controller.start(blockId)
                      : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(restart ? 'Начать сначала' : 'Начать ввод'),
                ),
              if (active && phase == AutomationPhase.countdown)
                TextButton(
                  onPressed: controller.cancelCountdown,
                  child: const Text('Отменить отсчёт'),
                ),
              if (active && phase == AutomationPhase.typing)
                TextButton(
                  onPressed: controller.pause,
                  child: const Text('Пауза'),
                ),
              if (active && phase == AutomationPhase.paused)
                OutlinedButton(
                  onPressed: controller.commandPending
                      ? null
                      : controller.resume,
                  child: const Text('Продолжить'),
                ),
              if (active)
                TextButton.icon(
                  onPressed: controller.stop,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Стоп'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Перед вводом — 5 секунд, чтобы выбрать поле. Для абзацев нужно многострочное поле.',
            style: TextStyle(color: Colors.white60, fontSize: 11),
          ),
          const Divider(),
        ],
      );
    },
  );
}

/// Kept outside the scroll view, including in Settings and long content views.
class AutomationStatusBar extends StatelessWidget {
  const AutomationStatusBar({
    super.key,
    required this.controller,
    required this.title,
    required this.onMessage,
  });
  final TextAutomationController controller;
  final String title;
  final ValueChanged<String> onMessage;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final state = controller.state;
      if (state.phase == AutomationPhase.idle &&
          controller.preparingBlock == null &&
          controller.failure == null) {
        return const SizedBox.shrink();
      }
      final message = controller.failure ?? state.message;
      return DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      controller.preparingBlock != null
                          ? 'Подготовка текста…'
                          : '${controller.failure != null ? 'Ошибка ввода' : state.label} · ${state.position}/${state.total}',
                      key: const Key('automationStatus'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (state.phase == AutomationPhase.countdown)
                    IconButton(
                      tooltip: 'Отменить отсчёт',
                      icon: const Icon(Icons.close, size: 17),
                      visualDensity: VisualDensity.compact,
                      onPressed: controller.cancelCountdown,
                    ),
                  if (state.phase == AutomationPhase.typing)
                    IconButton(
                      tooltip: 'Пауза ввода',
                      icon: const Icon(Icons.pause, size: 17),
                      visualDensity: VisualDensity.compact,
                      onPressed: controller.pause,
                    ),
                  if (state.phase == AutomationPhase.paused)
                    IconButton(
                      tooltip: 'Продолжить ввод',
                      icon: const Icon(Icons.play_arrow, size: 17),
                      visualDensity: VisualDensity.compact,
                      onPressed: controller.commandPending
                          ? null
                          : controller.resume,
                    ),
                  if (state.engaged || controller.commandPending)
                    IconButton(
                      tooltip: 'Остановить ввод',
                      icon: const Icon(Icons.stop, size: 17),
                      visualDensity: VisualDensity.compact,
                      onPressed: controller.stop,
                    ),
                ],
              ),
              if (message.isNotEmpty)
                InkWell(
                  onTap: () => onMessage('$title\n\n$message'),
                  child: Tooltip(
                    message: message,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
