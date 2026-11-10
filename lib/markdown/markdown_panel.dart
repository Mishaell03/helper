import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../background_service.dart';
import '../hotkey_settings.dart';
import '../platform.dart';
import '../panel_theme.dart';
import '../transient_message.dart';
import '../window_resize_border.dart';
import '../automation/text_automation.dart';
import '../automation/automation_controls.dart';
import '../updates/update_settings.dart';
import 'block_card.dart';
import 'block_tap_region.dart';
import 'markdown_controller.dart';
import 'markdown_repository.dart';
import 'models.dart';
import 'block_display.dart';

enum _View { blocks, pinned, archive, settings }

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
  BlockDisplay? _display;
  int _displayPage = 0;
  int? _selected;
  bool _source = false;
  bool _loading = true;
  bool _picking = false;
  bool _confirmingImport = false;
  bool _opening = false;
  int _openGeneration = 0;
  bool _installingUpdate = false;
  bool _resettingData = false;
  int _preferencesRevision = 0;
  String? _loadError;
  Timer? _notificationTimer;
  bool _pointerInside = false;
  bool? _viewerEscapeEnabled;
  static const _cardExtent = BlockCard.extent;

  List<BlockSummary> get _blocks => (_controller?.blocks ?? [])
      .where((block) => block.archived == (_view == _View.archive))
      .where((block) => _view != _View.pinned || block.pinned)
      .toList();
  bool get _busy =>
      _loading ||
      _picking ||
      _opening ||
      _installingUpdate ||
      _resettingData ||
      (_controller?.busy ?? false);

  @override
  void initState() {
    super.initState();
    if (isWindows) {
      BackgroundService.instance.onWarning = _notify;
      BackgroundService.instance.onNavigateSlot = _navigateSlot;
      BackgroundService.instance.onCloseViewer = _closeViewer;
    }
    _initialize();
    if (isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkHotkeys());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncViewerEscape();
  }

  void _syncViewerEscape() {
    if (!isWindows || !mounted) return;
    final enabled =
        _opened != null &&
        _pointerInside &&
        ModalRoute.of(context)?.isCurrent == true;
    if (_viewerEscapeEnabled == enabled) return;
    _viewerEscapeEnabled = enabled;
    unawaited(
      BackgroundService.instance.setViewerEscapeEnabled(enabled).catchError((
        Object error,
      ) {
        if (mounted) _notify(backgroundError(error));
      }),
    );
  }

  void _closeViewer() {
    if (!mounted ||
        _opened == null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _back();
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
        _automation!.onStartRequested = () => _startSelected(fromHotkey: true);
        _automation!.onArchived = controller.load;
        _automation!.onArchiveError = _notify;
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

  Future<void> _startSelected({bool fromHotkey = false}) async {
    final id = _opened?.id ?? _selected;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (_busy || id == null) {
      _notify(
        'Сначала выберите текстовый блок и дождитесь завершения операции.',
      );
      return;
    }
    await _startBlock(id, fromHotkey: fromHotkey);
  }

  Future<void> _exitApplication() => _run(() async {
    await _automation?.stop();
    await _automation?.flushArchive();
    await _automation?.flushPreferences();
    await BackgroundService.instance.exit();
  });

  Future<void> _startBlock(int id, {bool fromHotkey = false}) async {
    if (_installingUpdate) return;
    if (_automation == null) return;
    if (!_automation!.canStart) {
      _notify(
        'Сначала остановите текущий ввод или продолжите его с сохранённой позиции.',
      );
      return;
    }
    await _automation!.start(id, fromHotkey: fromHotkey);
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

  Future<void> _installUpdate(Future<void> Function() launch) async {
    if (_busy) {
      throw const FormatException(
        'Сначала завершите импорт или открытие файла. Обновление пока не начато.',
      );
    }
    setState(() => _installingUpdate = true);
    try {
      await _automation?.stop();
      if (_automation?.state.engaged == true || _automation?.failure != null) {
        throw FormatException(
          _automation?.failure ?? 'Не удалось остановить автоматический ввод.',
        );
      }
      await _automation?.flushPreferences();
      await _automation?.flushArchive();
      await launch();
      await BackgroundService.instance.exit();
    } finally {
      if (mounted) setState(() => _installingUpdate = false);
    }
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
      if (_opened != null &&
          !_controller!.blocks.any((block) => block.id == _opened!.id)) {
        _opened = null;
      }
      if (_opened == null &&
          !_opening &&
          !blocks.any((block) => block.id == _selected)) {
        _updateSelection(blocks.firstOrNull, notify: !_loading);
      }
    });
    _syncViewerEscape();
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
    _notificationTimer?.cancel();
    final keepStopVisible =
        _automation?.state.engaged == true ||
        _automation?.commandPending == true;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: keepStopVisible ? SnackBarBehavior.floating : null,
        margin: keepStopVisible ? const EdgeInsets.fromLTRB(8, 0, 8, 76) : null,
        content: Text(message),
        duration: TransientMessage.duration,
        action: SnackBarAction(
          label: 'Закрыть',
          onPressed: () {
            _notificationTimer?.cancel();
            messenger.hideCurrentSnackBar();
          },
        ),
      ),
    );
    // SnackBar's own timeout can pause for accessibility actions or hovering.
    _notificationTimer = Timer(
      TransientMessage.duration,
      messenger.removeCurrentSnackBar,
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
    ++_openGeneration;
    setState(() {
      _opening = false;
      _view = view;
      _opened = null;
      _display = null;
      if (tab != null) _tab = tab;
    });
    _syncViewerEscape();
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
          builder: (context) => TransientMessage(
            identity: report,
            onExpired: () =>
                Navigator.of(context).removeRoute(ModalRoute.of(context)!),
            child: AlertDialog(
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

  Future<void> _open(BlockSummary block, {bool requestFocus = true}) async {
    if (_busy || _controller == null) return;
    final generation = ++_openGeneration;
    setState(() {
      _updateSelection(block);
      _opening = true;
    });
    _reportBlockStage(1, block.id);
    await _run(() async {
      try {
        final full = await _controller!.repository
            .block(block.id)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw const FormatException(
                'Чтение блока заняло слишком долго. Попробуйте открыть его снова.',
              ),
            );
        if (!mounted || generation != _openGeneration) return;
        _reportBlockStage(2, block.id, length: full.content.length);
        final display = await prepareBlockDisplay(full.content, full.source)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw const FormatException(
                'Подготовка просмотра заняла слишком долго. Исходный текст сохранён.',
              ),
            );
        if (!mounted || generation != _openGeneration) return;
        setState(() {
          _opened = full;
          _display = display;
          _displayPage = 0;
          _source = false;
        });
        _syncViewerEscape();
        _reportBlockStage(3, block.id, length: full.content.length);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              generation == _openGeneration &&
              _opened?.id == block.id) {
            _reportBlockStage(4, block.id);
          }
        });
        if (requestFocus) _focus.requestFocus();
      } catch (_) {
        if (mounted && generation == _openGeneration) {
          _reportBlockStage(5, block.id);
          rethrow;
        }
      }
    });
    if (mounted && generation == _openGeneration) {
      setState(() => _opening = false);
      _changed();
    }
  }

  void _reportBlockStage(int stage, int id, {int length = 0}) {
    if (!isWindows) return;
    unawaited(
      BackgroundService.instance
          .reportBlockStage(stage, id, length: length)
          .catchError((Object _) {}),
    );
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
    ++_openGeneration;
    if (_opened != null || _opening) {
      setState(() {
        _opening = false;
        _opened = null;
        _display = null;
      });
      _changed();
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
        (_opened != null || _opening || _view != _View.blocks)) {
      if (event is KeyDownEvent) _back();
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
      _selectRelative(delta);
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

  BlockSummary? _selectRelative(int delta) {
    final blocks = _blocks;
    if (blocks.isEmpty) return null;
    final index = blocks.indexWhere((block) => block.id == _selected);
    final next =
        blocks[index < 0
            ? (delta < 0 ? blocks.length - 1 : 0)
            : (index + delta) % blocks.length];
    setState(() => _updateSelection(next));
    return next;
  }

  void _navigateSlot(int delta) {
    if (!mounted || _busy || ModalRoute.of(context)?.isCurrent != true) return;
    final next = _selectRelative(delta);
    if (next == null) return;
    if (_opened != null) {
      if (_opened!.id != next.id) unawaited(_open(next, requestFocus: false));
    } else if (_view != _View.settings) {
      _ensureSelectionVisible();
    }
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
      _controller!.blocks.where(
        (block) => all || (!block.pinned && !block.archived),
      ),
    )) {
      return;
    }
    if (!await _confirm(
      all ? 'Удалить всё содержимое?' : 'Очистить незакреплённое?',
      all
          ? 'Все импортированные файлы и блоки, включая закреплённые и архивные, будут удалены. Это действие нельзя отменить.'
          : 'Незакреплённые блоки вне архива будут удалены. Закреплённые и архивные блоки и их исходные файлы останутся.',
    )) {
      return;
    }
    if (!mounted) return;
    if (_guardDelete(
      _controller!.blocks.where(
        (block) => all || (!block.pinned && !block.archived),
      ),
    )) {
      return;
    }
    await _run(all ? _controller!.clearEverything : _controller!.clearUnpinned);
  }

  Future<void> _resetApplicationData() async {
    if (_busy || _controller == null) return;
    if (!await _confirm(
      'Удалить все данные приложения?',
      'Все импортированные файлы и блоки, включая закреплённые, архив и отметки ввода, будут удалены. '
          'Настройки, скорость, горячие клавиши и позиция подсказки будут сброшены, автозапуск отключён. '
          'Исходные файлы на диске останутся. Это действие нельзя отменить.',
    )) {
      return;
    }
    if (!mounted || _busy) return;
    setState(() => _resettingData = true);
    await _run(() async {
      try {
        if (isWindows) await BackgroundService.instance.setDataResetting(true);
        await _automation?.stop();
        if (_automation?.state.engaged == true ||
            _automation?.failure != null) {
          throw FormatException(
            _automation?.failure ??
                'Не удалось остановить автоматический ввод.',
          );
        }
        await _automation?.flushPreferences();
        await _automation?.flushArchive();
        if (isWindows) {
          await BackgroundService.instance.resetApplicationSettings();
        }
        await _controller!.resetApplicationData();
        await _automation?.initialize();
        if (_automation?.failure != null) {
          throw FormatException(_automation!.failure!);
        }
        if (!mounted) return;
        setState(() {
          ++_preferencesRevision;
          _opened = null;
          _display = null;
        });
        _notify('Данные приложения удалены. Настройки сброшены.');
      } catch (error) {
        final message =
            error is PlatformException || error is MissingPluginException
            ? backgroundError(error)
            : markdownError(error);
        throw FormatException(
          'Сброс не завершён. Часть данных или настроек могла быть удалена. $message',
        );
      } finally {
        try {
          if (isWindows) {
            await BackgroundService.instance.setDataResetting(false);
          }
        } finally {
          if (mounted) setState(() => _resettingData = false);
        }
      }
    });
  }

  Future<void> _deleteFile(ImportedFile file) async {
    if (_guardDelete(
      _controller!.blocks.where((block) => block.fileId == file.id),
    )) {
      return;
    }
    if (!await _confirm(
      'Удалить импортированный файл?',
      '«${file.filename}»: будут удалены все его блоки, в том числе закреплённые и архивные. Другие импорты не изменятся. Исходный файл на диске останется.',
    )) {
      return;
    }
    if (mounted) await _run(() => _controller!.deleteFile(file.id));
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    ++_openGeneration;
    if (isWindows) {
      BackgroundService.instance.onWarning = null;
      BackgroundService.instance.onNavigateSlot = null;
      BackgroundService.instance.onCloseViewer = null;
      if (_viewerEscapeEnabled == true) {
        unawaited(
          BackgroundService.instance
              .setViewerEscapeEnabled(false)
              .catchError((Object _) {}),
        );
      }
    }
    _controller?.removeListener(_changed);
    _automation?.removeListener(_automationChanged);
    if (_automation != null) _automation!.onStartRequested = null;
    if (_automation != null) {
      _automation!.onArchived = null;
      _automation!.onArchiveError = null;
    }
    if (widget.automation == null) _automation?.dispose();
    if (widget.controller == null && _controller != null) {
      _controller!.dispose();
      final repository = _controller!.repository;
      unawaited(
        (_automation?.flushArchive() ?? Future<void>.value()).then(
          (_) => repository.close(),
        ),
      );
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
                    _resettingData ||
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
            child: MouseRegion(
              onEnter: (_) {
                _pointerInside = true;
                _syncViewerEscape();
              },
              onExit: (_) {
                _pointerInside = false;
                _syncViewerEscape();
              },
              child: panel,
            ),
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
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
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
        _icon(
          Icons.archive_outlined,
          'Архив',
          () => _navigate(_View.archive),
          selected: _view == _View.archive,
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
          TransientMessage(
            identity: _loadError,
            child: Text(_loadError!, textAlign: TextAlign.center),
          ),
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
              Text(
                _view == _View.archive
                    ? 'Архив'
                    : _view == _View.pinned
                    ? 'Закреплённое'
                    : 'Блоки',
              ),
              const Spacer(),
              if (_view != _View.archive)
                TextButton(
                  onPressed:
                      _busy ||
                          !_controller!.blocks.any(
                            (block) => !block.pinned && !block.archived,
                          )
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
                      _view == _View.archive
                          ? 'Архив пуст.'
                          : _view == _View.pinned
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

  void _selectSlot(BlockSummary block) {
    if (_busy) return;
    setState(() => _updateSelection(block));
    _focus.requestFocus();
  }

  void _updateSelection(BlockSummary? block, {bool notify = true}) {
    if (_selected == block?.id) return;
    _selected = block?.id;
    if (notify && isWindows) {
      unawaited(
        BackgroundService.instance
            .selectedBlockChanged(block?.id, block?.title ?? '')
            .catchError((Object error) {
              if (mounted) _notify(backgroundError(error));
            }),
      );
    }
  }

  Widget _card(BlockSummary block) => BlockCard(
    key: ValueKey('block-${block.id}'),
    block: block,
    selected: _selected == block.id,
    showDescriptions: _controller!.showDescriptions,
    enabled: !_busy,
    onSelect: () => _selectSlot(block),
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
        case BlockAction.archive:
          _run(() => _controller!.setArchived(block.id, !block.archived));
        case BlockAction.delete:
          _deleteBlock(block);
        case BlockAction.type:
          _startBlock(block.id);
      }
    },
  );

  Widget _fullContent() {
    final block = _opened!;
    final pages = _source ? _display!.source : _display!.content;
    final page = _displayPage.clamp(0, pages.length - 1);
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
                () => setState(() {
                  _source = !_source;
                  _displayPage = 0;
                }),
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
            key: ValueKey('content-${block.id}-$_source-$page'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_source) ...[
                  Text(
                    block.displayTitle.length > 512
                        ? '${block.displayTitle.substring(0, 512)}…'
                        : block.displayTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (block.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      block.description.length > 2048
                          ? '${block.description.substring(0, 2048)}…'
                          : block.description,
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
                SelectionArea(
                  child: Text(
                    pages[page],
                    key: const Key('fullBlockContent'),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (pages.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Предыдущая страница текста',
                  onPressed: page > 0
                      ? () => setState(() => _displayPage = page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    'Страница ${page + 1}/${pages.length}\nКопирование и ввод — весь текст',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                IconButton(
                  tooltip: 'Следующая страница текста',
                  onPressed: page + 1 < pages.length
                      ? () => setState(() => _displayPage = page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
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
                    (block) => block.fileId == file.id && !block.archived,
                  );
                  return ExpansionTile(
                    key: PageStorageKey('file-${file.id}'),
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
                        BlockTapRegion(
                          key: ValueKey('file-block-${block.id}'),
                          enabled: !_busy,
                          selected: _selected == block.id,
                          onSelect: () => _selectSlot(block),
                          onOpen: () => _open(block),
                          child: ListTile(
                            dense: true,
                            selected: _selected == block.id,
                            title: Text(
                              block.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            leading: Icon(
                              block.pinned ? Icons.push_pin : Icons.notes,
                              size: 14,
                            ),
                          ),
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
              onPressed:
                  _busy ||
                      !_controller!.blocks.any(
                        (block) => !block.pinned && !block.archived,
                      )
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
    key: const Key('preferencesList'),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    children: [
      if (_automation != null)
        AbsorbPointer(
          absorbing: _busy,
          child: TypingSpeedSettings(controller: _automation!, enabled: !_busy),
        ),
      const SizedBox(height: 12),
      AbsorbPointer(
        absorbing: _busy,
        child: Column(
          key: const Key('preferencesSwitches'),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Показывать описания'),
              value: _controller!.showDescriptions,
              onChanged: _busy
                  ? null
                  : (value) =>
                        _run(() => _controller!.setShowDescriptions(value)),
            ),
            if (isWindows)
              HotkeySettings(
                key: ValueKey('preferencesSection-$_preferencesRevision'),
                embedded: true,
                preferencesOnly: true,
                scrollable: false,
              ),
          ],
        ),
      ),
      if (isWindows) ...[
        UpdateSettings(enabled: !_busy, install: _installUpdate),
        TextButton.icon(
          onPressed: _busy ? null : _exitApplication,
          icon: const Icon(Icons.logout, size: 16),
          label: const Text('Выйти из приложения'),
        ),
      ],
      const Divider(),
      TextButton(
        onPressed: _busy ? null : _resetApplicationData,
        child: const Text('Удалить все данные приложения'),
      ),
    ],
  );
}
