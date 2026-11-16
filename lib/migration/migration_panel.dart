import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'migration_controller.dart';

class MigrationPanel extends StatefulWidget {
  const MigrationPanel({super.key, required this.controller});
  final MigrationController controller;

  @override
  State<MigrationPanel> createState() => _MigrationPanelState();
}

class _MigrationPanelState extends State<MigrationPanel> {
  final _excel = TextEditingController();
  final _ddl = TextEditingController();
  final _destination = TextEditingController();
  final _decisions = TextEditingController();
  bool _gpu = true;
  bool _saveExcel = false;
  bool _saveSql = false;
  bool _starting = false;

  @override
  void dispose() {
    for (final controller in [_excel, _ddl, _destination, _decisions]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _starting = true);
    try {
      await widget.controller.generate(
        excelDirectory: _excel.text,
        ddl: _ddl.text,
        useGpu: _gpu,
        decisions: _decisions.text,
      );
      if (mounted &&
          widget.controller.excel != null &&
          (_saveExcel || _saveSql)) {
        await _save();
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _save() async {
    try {
      await widget.controller.save(
        saveExcel: _saveExcel,
        saveSql: _saveSql,
        destination: _destination.text,
      );
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Не удалось сохранить'),
          content: Text('$error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final busy = controller.busy || _starting;
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Excel → SQL',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _excel,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: 'Путь к папке с .xlsx',
              suffixIcon: IconButton(
                tooltip: 'Вставить путь из буфера',
                onPressed: busy
                    ? null
                    : () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (mounted && !controller.busy) {
                          _excel.text = data?.text ?? '';
                        }
                      },
                icon: const Icon(Icons.content_paste, size: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ddl,
            enabled: !busy,
            minLines: 5,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'SQL Server: CREATE TABLE …',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _decisions,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'JSON решений колонок (необязательно)',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('GPU / CUDA (1650 Ti)'),
            subtitle: const Text('Выключено — CPU. Без скрытого отката с GPU.'),
            value: _gpu,
            onChanged: busy ? null : (value) => setState(() => _gpu = value),
          ),
          const Text(
            'Оба результата создаются во временной папке. Исходные Excel не изменяются.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Сохранить Excel'),
            value: _saveExcel,
            onChanged: busy
                ? null
                : (value) => setState(() => _saveExcel = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Сохранить SQL'),
            value: _saveSql,
            onChanged: busy
                ? null
                : (value) => setState(() => _saveSql = value),
          ),
          if (_saveExcel || _saveSql)
            TextField(
              controller: _destination,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Каталог сохранения',
                hintText: 'Пусто — рабочий стол',
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : _generate,
                child: const Text('Создать Excel и SQL'),
              ),
              if (controller.canCancel)
                TextButton(
                  onPressed: controller.cancel,
                  child: const Text('Отменить'),
                ),
              if (controller.excel != null && (_saveExcel || _saveSql))
                TextButton(
                  onPressed: busy ? null : _save,
                  child: const Text('Сохранить выбранное'),
                ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          SelectableText(controller.status),
          if (controller.excel != null)
            SelectableText(
              'Excel: ${controller.excel!.path}\nSQL: ${controller.sql!.path}',
              style: const TextStyle(fontSize: 11),
            ),
        ],
      );
    },
  );
}
