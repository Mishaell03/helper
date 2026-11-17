import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'migration_controller.dart';
import '../text_input_activation.dart';

class MigrationPanel extends StatefulWidget {
  const MigrationPanel({super.key, required this.controller, this.onImportSql});
  final MigrationController controller;
  final Future<void> Function(String)? onImportSql;

  @override
  State<MigrationPanel> createState() => _MigrationPanelState();
}

class _MigrationPanelState extends State<MigrationPanel> {
  final _excel = TextEditingController();
  final _ddl = TextEditingController();
  final _sqlFile = TextEditingController();
  final _destination = TextEditingController();
  bool _gpu = true;
  bool _moveExcel = false;
  bool _saveSql = false;
  bool _starting = false;
  bool _sqlFromFile = false;
  bool _processing = false;
  String _savedLocations = '';

  @override
  void dispose() {
    for (final controller in [_excel, _ddl, _sqlFile, _destination]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _starting = true;
      _savedLocations = '';
    });
    try {
      await widget.controller.generate(
        excelDirectory: _excel.text,
        ddl: _ddl.text,
        sqlFile: _sqlFromFile ? _sqlFile.text : null,
        useGpu: _gpu,
      );
      if (mounted &&
          widget.controller.excel != null &&
          (_moveExcel || _saveSql)) {
        await _save();
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _save() async {
    setState(() => _processing = true);
    try {
      final locations = <String>[];
      if (_saveSql) {
        final folder = await widget.controller.save(
          saveExcel: false,
          saveSql: true,
          destination: _destination.text,
        );
        locations.add('SQL сохранён: $folder');
      }
      if (_moveExcel && !widget.controller.excelMoved) {
        final file = await widget.controller.moveExcel(_destination.text);
        locations.add('Excel перемещён: $file');
      }
      if (mounted && locations.isNotEmpty) {
        setState(() => _savedLocations = locations.join('\n'));
      }
    } catch (error) {
      await _showError(error);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _importSql() async {
    try {
      await widget.controller.importSql(widget.onImportSql!);
    } catch (error) {
      await _showError(error);
    }
  }

  Future<void> _showError(Object error) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Не удалось обработать результат'),
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final busy = controller.busy || _starting || _processing;
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Excel → SQL',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextInputActivation(
            child: TextField(
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
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<bool>(
            initialValue: _sqlFromFile,
            decoration: const InputDecoration(labelText: 'Источник SQL'),
            items: const [
              DropdownMenuItem(value: false, child: Text('Ввести SQL')),
              DropdownMenuItem(value: true, child: Text('Файл или папка SQL')),
            ],
            onChanged: busy
                ? null
                : (value) => setState(() => _sqlFromFile = value ?? false),
          ),
          const SizedBox(height: 8),
          if (_sqlFromFile)
            TextInputActivation(
              child: TextField(
                controller: _sqlFile,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Путь к файлу .sql или папке',
                  helperText:
                      'Из папки берутся все .sql без вложенных каталогов.',
                ),
              ),
            )
          else
            TextInputActivation(
              child: TextField(
                controller: _ddl,
                enabled: !busy,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'SQL Server: CREATE TABLE …',
                ),
              ),
            ),
          const SizedBox(height: 8),
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
            title: const Text('Переместить готовый Excel'),
            subtitle: const Text(
              'Автоматически после генерации. Исходные книги остаются на месте.',
            ),
            value: _moveExcel,
            onChanged: busy
                ? null
                : (value) => setState(() => _moveExcel = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Сохранить SQL'),
            value: _saveSql,
            onChanged: busy
                ? null
                : (value) => setState(() => _saveSql = value),
          ),
          if (_moveExcel || _saveSql)
            TextInputActivation(
              child: TextField(
                controller: _destination,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Каталог назначения',
                  hintText: 'Пусто — рабочий стол',
                ),
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
              if (controller.excel != null &&
                  ((_moveExcel && !controller.excelMoved) || _saveSql))
                TextButton(
                  onPressed: busy ? null : _save,
                  child: const Text('Сохранить / переместить'),
                ),
              if (controller.sql != null && widget.onImportSql != null)
                TextButton.icon(
                  onPressed: busy || controller.sqlImported ? null : _importSql,
                  icon: Icon(
                    controller.sqlImported ? Icons.check : Icons.library_add,
                    size: 16,
                  ),
                  label: Text(
                    controller.sqlImported
                        ? 'SQL уже в библиотеке'
                        : 'Добавить SQL в библиотеку',
                  ),
                ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          SelectableText(controller.status),
          if (_savedLocations.isNotEmpty) SelectableText(_savedLocations),
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
