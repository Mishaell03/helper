import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../background_service.dart';
import '../hotkey_settings.dart';
import '../platform.dart';
import '../panel_theme.dart';
import '../window_resize_border.dart';
import '../automation/text_automation.dart';
import '../automation/automation_controls.dart';
import 'block_card.dart';
import 'markdown_controller.dart';
import 'markdown_repository.dart';
import 'models.dart';

enum _View { blocks, pinned, settings }

enum _SettingsTab { files, hotkeys, preferences }

/// Every view is Flutter content inside the same capture-excluded native HWND.
class MarkdownPanel extends StatefulWidget {
  const MarkdownPanel({
    super.key,
    this.controller,
    this.pickFiles,
    this.automation,
  });

  final MarkdownController? controller;
  final Future<List<String>> Function()? pickFiles;
  final TextAutomationController? automation;

  @override
  State<MarkdownPanel> createState() => _MarkdownPanelState();
}

class _MarkdownPanelState extends State<MarkdownPanel> {
  final _focus = FocusNode(debugLabel: 'Блоки');
  final _scroll = ScrollController();
  MarkdownController? _controller;
  TextAutomationController? _automation;
  _View _view = _View.blocks;
  _SettingsTab _tab = _SettingsTab.files;
  ContentBlock? _opened;
  int? _selected;
  bool _source = false;
  bool _loading = true;
  bool _picking = false;
  bool _confirmingImport = false;
  bool _opening = false;
  String? _loadError;
  static const _cardExtent = BlockCard.extent;

  List<BlockSummary> get _blocks => (_controller?.blocks ?? [])
      .where((block) => _view != _View.pinned || block.pinned)
      .toList();
  bool get _busy =>
      _loading || _picking || _opening || (_controller?.busy ?? false);

  @override
  void initState() {
    super.initState();
    if (isWindows) BackgroundService.instance.onWarning = _notify;
    _initialize();
    if (isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkHotkeys());
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    MarkdownController? controller;
    try {
      controller =
          widget.controller ??
          MarkdownController(await MarkdownRepository.open());
      await controller.load();
      if (!mounted) {
        if (widget.controller == null) {
          controller.dispose();
          await controller.repository.close();
        }
        return;
      }
      _controller = controller;
      controller.addListener(_changed);
      _changed();
      if (isWindows || widget.automation != null) {
        _automation =
            widget.automation ??
            TextAutomationController(controller.repository);
        _automation!.onStartRequested = _startSelected;
        _automation!.addListener(_automationChanged);
        await _automation!.initialize();
      }
    } catch (error) {
      if (widget.controller == null && controller != null) {
        controller.dispose();
        await controller.repository.close();
      }
      if (mounted) setState(() => _loadError = markdownError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _automationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startSelected() async {
    final id = _opened?.id ?? _selected;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (_busy || id == null) {
      _notify(
        'Сначала выберите текстовый блок и дождитесь завершения операции.',
      );
      return;
    }
    await _startBlock(id);
  }

  Future<void> _exitApplication() => _run(() async {
    await _automation?.stop();
    await _automation?.flushPreferences();
    await BackgroundService.instance.exit();
  });

  Future<void> _startBlock(int id) async {
    if (_automation == null) return;
    if (!_automation!.canStart) {
      _notify(
        'Сначала остановите текущий ввод или продолжите его с сохранённой позиции.',
      );
      return;
    }
    await _automation!.start(id);
  }

  bool _guardDelete(Iterable<BlockSummary> blocks) {
    if (blocks.any((block) => _automation?.protects(block.id) ?? false)) {
      _notify(
        'Сначала остановите автоматический ввод этого блока. Его текст и позиция пока сохранены.',
      );
      return true;
    }
    return false;
  }

  Future<void> _deleteBlock(BlockSummary block) async {
    if (!_guardDelete([block])) {
      await _run(() => _controller!.deleteBlock(block.id));
    }
  }

  void _changed() {
    if (!mounted) return;
    final blocks = _blocks;
    setState(() {
      if (!blocks.any((block) => block.id == _selected)) {
        _selected = blocks.isEmpty ? null : blocks.first.id;
      }
      if (_opened != null &&
          !_controller!.blocks.any((block) => block.id == _opened!.id)) {
        _opened = null;
      }
    });
  }

  Future<void> _checkHotkeys() async {
    try {
      final settings = await BackgroundService.instance.getSettings();
      if (!mounted) return;
      if (!settings.active || settings.warning.isNotEmpty) {
        _navigate(_View.settings, tab: _SettingsTab.hotkeys);
        if (settings.warning.isNotEmpty) {
          _notify('Проверьте предупреждения в настройках горячих клавиш.');
        }
      }
    } catch (error) {
      _notify(backgroundError(error));
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final keepStopVisible =
        _automation?.state.engaged == true ||
        _automation?.commandPending == true;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: keepStopVisible ? SnackBarBehavior.floating : null,
        margin: keepStopVisible ? const EdgeInsets.fromLTRB(8, 0, 8, 76) : null,
        content: Text(message),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Закрыть',
          onPressed: messenger.hideCurrentSnackBar,
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      _notify(
        error is PlatformException || error is MissingPluginException
            ? backgroundError(error)
            : markdownError(error),
      );
    }
  }

  void _navigate(_View view, {_SettingsTab? tab}) {
    setState(() {
      _view = view;
      _opened = null;
      if (tab != null) _tab = tab;
    });
    _changed();
    _focus.requestFocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _import() async {
    if (_busy || _controller == null) return;
    setState(() {
      _picking = true;
      _confirmingImport = true;
    });
    await _run(() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Импорт во время демонстрации'),
          content: const Text(
            'Если сейчас включена демонстрация экрана или запись, окно выбора '
            'файла, имена файлов и пути могут быть видны другим участникам. '
            'Защита окна приложения не распространяется на системное окно '
            'выбора файлов. При необходимости остановите демонстрацию перед '
            'импортом. Продолжить?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Продолжить импорт'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirmingImport = false);
      if (confirmed != true) return;
      if (widget.pickFiles == null && !isWindows) {
        throw const FormatException(
          'Выбор файлов доступен в приложении для Windows.',
        );
      }
      final paths =
          await (widget.pickFiles ??
              BackgroundService.instance.pickMarkdownFiles)();
      if (paths.isEmpty || !mounted) return;
      final report = await _controller!.importPaths(paths);
      if (!mounted) return;
      setState(() => _picking = false);
      _navigate(_View.blocks);
      if (report.errors.isEmpty) {
        _notify('Добавлено блоков: ${report.blocks}.');
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('Результат импорта'),
            content: Text(
              'Добавлено блоков: ${report.blocks}.\n\n${report.errors.join('\n\n')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Понятно'),
              ),
            ],
          ),
        );
      }
    });
    if (mounted) {
      setState(() {
        _picking = false;
        _confirmingImport = false;
      });
    }
  }

  Future<void> _open(BlockSummary block) async {
    if (_busy || _controller == null) return;
    setState(() {
      _selected = block.id;
      _opening = true;
    });
    await _run(() async {
      final full = await _controller!.repository.block(block.id);
      if (!mounted) return;
      setState(() {
        _opened = full;
        _source = false;
      });
      _focus.requestFocus();
    });
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _copy(BlockSummary block, {bool source = false}) =>
      _run(() async {
        final full = block is ContentBlock
            ? block
            : await _controller!.repository.block(block.id);
        await Clipboard.setData(
          ClipboardData(text: source ? full.source : full.content),
        );
        _notify(
          source ? 'Исходный текст скопирован.' : 'Содержимое скопировано.',
        );
      });

  void _back() {
    if (_opened != null) {
      setState(() => _opened = null);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureSelectionVisible(),
      );
    } else {
      _navigate(_View.blocks);
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_opened != null || _view != _View.blocks)) {
      _back();
      return KeyEventResult.handled;
    }
    if (_opened != null || _view == _View.settings || _busy) {
      return KeyEventResult.ignored;
    }
    final blocks = _blocks;
    if (blocks.isEmpty) return KeyEventResult.ignored;
    final index = blocks.indexWhere((block) => block.id == _selected);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = (index + delta).clamp(0, blocks.length - 1);
      setState(() => _selected = blocks[next].id);
      _focus.requestFocus();
      _ensureSelectionVisible();
      return KeyEventResult.handled;
    }
    if (index < 0) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _focus.hasPrimaryFocus) {
      _open(blocks[index]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed) {
      _copy(blocks[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _ensureSelectionVisible() {
    if (!mounted || !_scroll.hasClients) return;
    final index = _blocks.indexWhere((block) => block.id == _selected);
    if (index < 0) return;
    final top = index * _cardExtent;
    final bottom = top + _cardExtent;
    final position = _scroll.position;
    final target = top < position.pixels
        ? top
        : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension
        : position.pixels;
    _scroll.animateTo(
      target.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _clear({bool all = false}) async {
    if (_busy || _controller == null) return;
    if (_guardDelete(
      _controller!.blocks.where((block) => all || !block.pinned),
    )) {
      return;
    }
    if (!await _confirm(
      all ? 'Удалить всё содержимое?' : 'Очистить незакреплённое?',
      all
          ? 'Все импортированные файлы и блоки, включая закреплённые, будут удалены. Это действие нельзя отменить.'
          : 'Незакреплённые блоки будут удалены. Закреплённые блоки и их исходные файлы останутся.',
    )) {
      return;
    }
    if (!mounted) return;
    if (_guardDelete(
      _controller!.blocks.where((block) => all || !block.pinned),
    )) {
      return;
    }
    await _run(all ? _controller!.clearEverything : _controller!.clearUnpinned);
  }

  Future<void> _deleteFile(ImportedFile file) async {
    if (_guardDelete(
      _controller!.blocks.where((block) => block.fileId == file.id),
    )) {
      return;
    }
    if (!await _confirm(
      'Удалить импортированный файл?',
      '«${file.filename}»: будут удалены все его блоки, в том числе закреплённые. Другие импорты не изменятся. Исходный файл на диске останется.',
    )) {
      return;
    }
    if (mounted) await _run(() => _controller!.deleteFile(file.id));
  }

  @override
  void dispose() {
    if (isWindows) BackgroundService.instance.onWarning = null;
    _controller?.removeListener(_changed);
    _automation?.removeListener(_automationChanged);
    if (_automation != null) _automation!.onStartRequested = null;
    if (widget.automation == null) _automation?.dispose();
    if (widget.controller == null && _controller != null) {
      _controller!.dispose();
      unawaited(_controller!.repository.close());
    }
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panel = Scaffold(
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            color: PanelStyle.surface,
            shape: PanelStyle.shape,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _windowHandle(),
                if (_opened == null) _toolbar(),
                if (_loading ||
                    (_picking && !_confirmingImport) ||
                    _opening ||
                    (_controller?.busy ?? false))
                  const LinearProgressIndicator(minHeight: 1),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _loadError != null
                      ? _errorView()
                      : _opened != null
                      ? _fullContent()
                      : _view == _View.settings
                      ? _settings()
                      : _blockList(),
                ),
                if (_automation != null)
                  AutomationStatusBar(
                    controller: _automation!,
                    title:
                        _controller!.blocks
                            .where(
                              (block) => block.id == _automation!.state.blockId,
                            )
                            .firstOrNull
                            ?.displayTitle ??
                        'Автоматический ввод',
                    onMessage: (message) => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        scrollable: true,
                        title: const Text('Состояние ввода'),
                        content: Text(message),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Закрыть'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return isWindows
        ? WindowResizeBorder(
            onResize: (edge) => _run(() => windowManager.startResizing(edge)),
            onVerticalMaximize: () =>
                _run(() => windowManager.maximize(vertically: true)),
            child: panel,
          )
        : panel;
  }

  Widget _windowHandle() => SizedBox(
    height: 30,
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: isWindows
                ? (_) => _run(windowManager.startDragging)
                : null,
            child: Center(
              child: Container(
                width: 30,
                height: 3,
                decoration: BoxDecoration(
                  color: Colors.white38,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        if (isWindows)
          Align(
            alignment: Alignment.centerRight,
            child: _icon(
              Icons.close,
              'Скрыть приложение',
              () => _run(BackgroundService.instance.hide),
            ),
          ),
      ],
    ),
  );

  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool selected = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: 18,
    constraints: const BoxConstraints.tightFor(width: 38, height: 34),
    padding: EdgeInsets.zero,
    icon: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: selected ? Colors.white : Colors.white70),
        const SizedBox(height: 4),
        Container(
          height: 2,
          width: 14,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF8792A4) : Colors.transparent,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    ),
  );

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
    child: Row(
      children: [
        _icon(
          Icons.content_paste_outlined,
          'Все блоки',
          () => _navigate(_View.blocks),
          selected: _view == _View.blocks,
        ),
        _icon(
          Icons.push_pin_outlined,
          'Закреплённые',
          () => _navigate(_View.pinned),
          selected: _view == _View.pinned,
        ),
        _icon(
          Icons.folder_outlined,
          'Импортированные файлы',
          () => _navigate(_View.settings, tab: _SettingsTab.files),
          selected: _view == _View.settings && _tab == _SettingsTab.files,
        ),
        const Spacer(),
        if (_automation != null)
          _icon(
            Icons.play_arrow,
            'Начать ввод выбранного блока (через 5 с)',
            !_busy && _selected != null && _automation!.canStart
                ? _startSelected
                : null,
          ),
        _icon(Icons.add, 'Импортировать .md или .txt', _busy ? null : _import),
        _icon(
          Icons.settings_outlined,
          'Настройки',
          () => _navigate(_View.settings, tab: _SettingsTab.preferences),
          selected: _view == _View.settings && _tab != _SettingsTab.files,
        ),
      ],
    ),
  );

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_loadError!, textAlign: TextAlign.center),
          TextButton(onPressed: _initialize, child: const Text('Повторить')),
        ],
      ),
    ),
  );

  Widget _blockList() {
    final blocks = _blocks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(_view == _View.pinned ? 'Закреплённое' : 'Блоки'),
              const Spacer(),
              TextButton(
                onPressed:
                    _busy || !_controller!.blocks.any((block) => !block.pinned)
                    ? null
                    : () => _clear(),
                child: const Text('Очистить'),
              ),
            ],
          ),
        ),
        Expanded(
          child: blocks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _view == _View.pinned
                          ? 'Нет закреплённых блоков.'
                          : 'Добавьте файл .md или .txt\nс помощью кнопки +.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    key: const PageStorageKey('markdownBlocks'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    itemExtent: _cardExtent,
                    itemCount: blocks.length,
                    itemBuilder: (_, index) => _card(blocks[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _card(BlockSummary block) => BlockCard(
    key: ValueKey('block-${block.id}'),
    block: block,
    selected: _selected == block.id,
    showDescriptions: _controller!.showDescriptions,
    enabled: !_busy,
    onOpen: () => _open(block),
    canAutomate: _automation != null,
    onStop: _automation?.protects(block.id) == true ? _automation!.stop : null,
    automationStatus: _automation?.protects(block.id) == true
        ? _automation!.preparingBlock == block.id
              ? 'Подготовка текста…'
              : '${_automation!.state.label} · ${_automation!.state.position}/${_automation!.state.total}'
        : null,
    onAction: (action) {
      switch (action) {
        case BlockAction.copy:
          _copy(block);
        case BlockAction.pin:
          _run(() => _controller!.pin(block));
        case BlockAction.delete:
          _deleteBlock(block);
        case BlockAction.type:
          _startBlock(block.id);
      }
    },
  );

  Widget _fullContent() {
    final block = _opened!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              _icon(Icons.arrow_back, 'Назад (Esc)', _back),
              const Spacer(),
              _icon(
                Icons.code,
                _source ? 'Показать содержимое' : 'Показать исходный блок',
                () => setState(() => _source = !_source),
                selected: _source,
              ),
              TextButton.icon(
                onPressed: () => _copy(block, source: _source),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Копировать'),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('content-${block.id}-$_source'),
            padding: const EdgeInsets.all(16),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_source) ...[
                    Text(
                      block.displayTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (block.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        block.description,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                  if (_automation != null)
                    AutomationControls(
                      controller: _automation!,
                      blockId: block.id,
                    ),
                  Text(
                    _source ? block.source : block.content,
                    key: const Key('fullBlockContent'),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _settings() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _icon(Icons.arrow_back, 'Назад (Esc)', _back),
            const Text('Настройки'),
            const Spacer(),
            _icon(
              Icons.folder_outlined,
              'Импортированные файлы',
              () => setState(() => _tab = _SettingsTab.files),
              selected: _tab == _SettingsTab.files,
            ),
            _icon(
              Icons.keyboard_outlined,
              'Горячие клавиши',
              () => setState(() => _tab = _SettingsTab.hotkeys),
              selected: _tab == _SettingsTab.hotkeys,
            ),
            _icon(
              Icons.tune,
              'Параметры приложения',
              () => setState(() => _tab = _SettingsTab.preferences),
              selected: _tab == _SettingsTab.preferences,
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: switch (_tab) {
          _SettingsTab.files => _importedFiles(),
          _SettingsTab.hotkeys =>
            isWindows
                ? const HotkeySettings(
                    key: ValueKey('hotkeySection'),
                    embedded: true,
                  )
                : const Center(
                    child: Text(
                      'Глобальные горячие клавиши доступны в Windows.',
                    ),
                  ),
          _SettingsTab.preferences => _preferences(),
        },
      ),
    ],
  );

  Widget _importedFiles() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Импортированные файлы',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ),
      Expanded(
        child: _controller!.files.isEmpty
            ? const Center(child: Text('Файлы пока не импортированы.'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _controller!.files.length,
                itemBuilder: (_, index) {
                  final file = _controller!.files[index];
                  final date = MaterialLocalizations.of(
                    context,
                  ).formatShortDate(file.importedAt.toLocal());
                  final time = MaterialLocalizations.of(context)
                      .formatTimeOfDay(
                        TimeOfDay.fromDateTime(file.importedAt.toLocal()),
                        alwaysUse24HourFormat: true,
                      );
                  final blocks = _controller!.blocks.where(
                    (block) => block.fileId == file.id,
                  );
                  return ExpansionTile(
                    key: ValueKey('file-${file.id}'),
                    dense: true,
                    title: Text(
                      file.filename,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '$date, $time\nБлоков: ${file.remainingBlockCount} из ${file.originalBlockCount}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Удалить файл',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: _busy ? null : () => _deleteFile(file),
                    ),
                    children: [
                      for (final block in blocks)
                        ListTile(
                          dense: true,
                          title: Text(
                            block.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          leading: Icon(
                            block.pinned ? Icons.push_pin : Icons.notes,
                            size: 14,
                          ),
                          onTap: () => _open(block),
                        ),
                    ],
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          children: [
            TextButton(
              onPressed: _busy || _controller!.blocks.isEmpty
                  ? null
                  : () => _clear(),
              child: const Text('Очистить незакреплённое'),
            ),
            TextButton(
              onPressed: _busy || _controller!.files.isEmpty
                  ? null
                  : () => _clear(all: true),
              child: const Text('Удалить всё, включая закреплённое'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _preferences() => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    children: [
      SwitchListTile(
        dense: true,
        title: const Text('Показывать описания'),
        value: _controller!.showDescriptions,
        onChanged: _busy
            ? null
            : (value) => _run(() => _controller!.setShowDescriptions(value)),
      ),
      if (_automation != null) TypingSpeedSettings(controller: _automation!),
      if (isWindows) ...[
        const HotkeySettings(
          key: ValueKey('preferencesSection'),
          embedded: true,
          preferencesOnly: true,
          scrollable: false,
        ),
        TextButton.icon(
          onPressed: _exitApplication,
          icon: const Icon(Icons.logout, size: 16),
          label: const Text('Выйти из приложения'),
        ),
      ],
    ],
  );
}
