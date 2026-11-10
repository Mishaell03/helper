import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/background_service.dart';
import 'package:helper/main.dart';
import 'package:helper/panel_theme.dart';
import 'package:helper/markdown/markdown_controller.dart';
import 'package:helper/markdown/block_card.dart';
import 'package:helper/markdown/markdown_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MarkdownRepository repository;
  late MarkdownController controller;
  String? clipboard;
  var automationStarts = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('helper_ui_');
    repository = await MarkdownRepository.open(
      databasePath: '${directory.path}/test.sqlite3',
    );
    controller = MarkdownController(repository);
    clipboard = null;
    automationStarts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard =
                (call.arguments as Map<Object?, Object?>)['text'] as String;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('helper/automation'), (
          call,
        ) async {
          if (call.method == 'start') automationStarts++;
          if (const ['getState', 'setSpeed', 'stop'].contains(call.method)) {
            return {
              'phase': 'idle',
              'speed': 1000,
              'revision': 0,
              'stopToken': 0,
            };
          }
          throw MissingPluginException();
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('helper/background'), (
          call,
        ) async {
          if (call.method == 'getSettings') {
            return {
              'toggle': Hotkey.defaultToggle.toMap(),
              'exit': Hotkey.defaultExit.toMap(),
              'active': true,
              'warning': '',
              'autostart': false,
              'startHidden': false,
            };
          }
          return null;
        });
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('helper/automation'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('helper/background'),
          null,
        );
  });

  // SQLite and file parsing really run in isolates. Let real asynchronous I/O
  // finish before settling Flutter animations; do not replace the repository.
  Future<void> settle(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (!controller.busy &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    } while (DateTime.now().isBefore(deadline));
    fail('Асинхронная операция не завершилась.');
  }

  Future<File> file(WidgetTester tester, String name, String content) async =>
      (await tester.runAsync(() async {
        final result = File('${directory.path}/$name');
        await result.parent.create(recursive: true);
        await result.writeAsBytes(utf8.encode(content));
        return result;
      }))!;

  Future<void> open(
    WidgetTester tester, {
    List<String> paths = const [],
  }) async {
    await tester.pumpWidget(
      MyApp(controller: controller, pickFiles: () async => paths),
    );
    await settle(tester);
  }

  Future<void> importFiles(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Импортировать .md или .txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить импорт'));
    await settle(tester);
    if (find.text('Закрыть').evaluate().isNotEmpty) {
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> navigateSlot(WidgetTester tester, int delta) async {
    BackgroundService.instance.onNavigateSlot!(delta);
    await settle(tester);
  }

  int selectedSlot(WidgetTester tester) => tester
      .widgetList<BlockCard>(find.byType(BlockCard))
      .singleWhere((card) => card.selected)
      .block
      .id;

  testWidgets(
    'Глобальная навигация выбирает и открывает слоты без фокуса и запуска ввода',
    (tester) async {
      final input = await file(
        tester,
        'slots.txt',
        '# Один\n\nПервый\n---\n# Два\n\nВторой\n---\n# Три\n\nТретий\n',
      );
      await open(tester, paths: [input.path]);
      await navigateSlot(tester, 1); // Empty list.
      await importFiles(tester);
      final ids = controller.blocks.map((block) => block.id).toList();
      await navigateSlot(tester, -1);
      expect(selectedSlot(tester), ids.first);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      await navigateSlot(tester, 1);
      expect(selectedSlot(tester), ids[1]);
      expect(FocusManager.instance.primaryFocus, same(focus));
      await tester.tap(find.byTooltip('Импортировать .md или .txt'));
      await tester.pumpAndSettle();
      await navigateSlot(tester, 1); // Do not change selection behind a modal.
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect(selectedSlot(tester), ids[1]);
      await tester.tap(find.text('Два'));
      await settle(tester);
      await navigateSlot(tester, 1);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        '\nТретий\n',
      );
      await navigateSlot(tester, 1); // Clamp, do not wrap.
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        '\nТретий\n',
      );
      await navigateSlot(tester, -1);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        '\nВторой\n',
      );
      expect(automationStarts, 0);
      await tester.pumpWidget(const SizedBox());
      expect(BackgroundService.instance.onNavigateSlot, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Глобальная навигация сохраняет порядок и фильтр закреплённых слотов',
    (tester) async {
      final input = await file(
        tester,
        'pinned-slots.txt',
        '# Один\n\nПервый\n---\n# Два\n\nВторой\n---\n# Три\n\nТретий\n',
      );
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      final first = controller.blocks.first;
      final last = controller.blocks.last;
      await tester.tap(find.byTooltip('Закрепить').first);
      await settle(tester);
      await tester.tap(find.byTooltip('Закрепить').last);
      await settle(tester);
      await tester.tap(find.byTooltip('Закреплённые'));
      await settle(tester);
      await navigateSlot(tester, 1);
      expect(selectedSlot(tester), last.id);
      await navigateSlot(tester, 1);
      expect(selectedSlot(tester), last.id);
      await navigateSlot(tester, -1);
      expect(selectedSlot(tester), first.id);
      expect(automationStarts, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Пустая прозрачная панель без названия приложения', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Помощник'), findsNothing);
    expect(find.textContaining('Добавьте файл .md'), findsOneWidget);
    final context = tester.element(find.byType(Scaffold));
    expect(Theme.of(context).scaffoldBackgroundColor, Colors.transparent);
    final panel = tester
        .widgetList<Material>(find.byType(Material))
        .firstWhere((material) => material.color?.a == 0.5);
    expect(
      (panel.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
    );
    expect(panel.clipBehavior, Clip.antiAlias);
  });

  testWidgets(
    'Кнопка импорта читает настоящий файл; полный текст и исходник копируются без изменений',
    (tester) async {
      const content =
          '# Заказ\r\n### Короткое описание\r\n\r\nПервый абзац.  \r\n\r\n**Второй абзац**\r\n';
      final input = await file(tester, 'заказы.md', content);
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      expect(find.text('Заказ'), findsOneWidget);
      expect(controller.files.single.originalBlockCount, 1);
      await tester.tap(find.text('Заказ'));
      await settle(tester);
      final body = tester.widget<Text>(
        find.byKey(const Key('fullBlockContent')),
      );
      expect(body.data, '\r\nПервый абзац.  \r\n\r\n**Второй абзац**\r\n');
      expect(find.byType(SelectionArea), findsOneWidget);
      await tester.tap(find.text('Копировать'));
      await settle(tester);
      expect(clipboard, body.data);
      await tester.tap(find.byTooltip('Показать исходный блок'));
      await settle(tester);
      await tester.tap(find.text('Копировать'));
      await settle(tester);
      expect(clipboard, content);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const Key('fullBlockContent')), findsNothing);
    },
  );

  testWidgets(
    'Стрелки выбирают карточку, Ctrl+C копирует выбранную, Enter открывает',
    (tester) async {
      final input = await file(
        tester,
        'клавиши.txt',
        '# Один\n\nПервый\n---\n# Два\n\nВторой\n',
      );
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final id = controller.blocks[1].id;
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(ValueKey('block-$id')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect((material.shape as RoundedRectangleBorder).side.width, 1.3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(clipboard, '\nВторой\n');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        '\nВторой\n',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        '\nПервый\n',
      );
    },
  );

  testWidgets(
    'Большой блок открывается постранично, копирование не обрезается',
    (tester) async {
      final body = '${'A' * 8192}${'B' * 8192}${'C' * 5000}';
      final source = '# Большой блок\n$body';
      final input = await file(tester, 'large.txt', source);
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      await tester.tap(find.text('Большой блок'));
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        'A' * 8192,
      );
      expect(find.textContaining('Страница 1/3'), findsOneWidget);
      await tester.tap(find.byTooltip('Следующая страница текста'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        'B' * 8192,
      );
      await tester.tap(find.text('Копировать'));
      await settle(tester);
      expect(clipboard, body);
      await tester.tap(find.byTooltip('Показать исходный блок'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Страница 1/3'), findsOneWidget);
      await tester.tap(find.text('Копировать'));
      await settle(tester);
      expect(clipboard, source);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.text('Большой блок'));
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
        'A' * 8192,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Закрепление и обычная очистка сохраняют закреплённый блок', (
    tester,
  ) async {
    final input = await file(
      tester,
      'закрепление.md',
      '# Сохранить\n\nОставить\n---\n# Удалить\n\nУбрать',
    );
    await open(tester, paths: [input.path]);
    await importFiles(tester);
    await tester.tap(find.byTooltip('Закрепить').first);
    await settle(tester);
    expect(controller.blocks.first.pinned, isTrue);
    await tester.tap(find.text('Очистить'));
    await settle(tester);
    await tester.tap(find.text('Отмена'));
    await settle(tester);
    expect(controller.blocks, hasLength(2));
    await tester.tap(find.text('Очистить'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Удалить'));
    await settle(tester);
    expect(controller.blocks.single.title, 'Сохранить');
    expect(controller.blocks.single.pinned, isTrue);
    await tester.tap(find.byTooltip('Закреплённые'));
    await settle(tester);
    expect(find.text('Сохранить'), findsOneWidget);
  });

  testWidgets(
    'Удаление импорта подтверждается и не затрагивает другой импорт с тем же именем',
    (tester) async {
      final a = await file(tester, 'a/общий.md', '# Импорт А\n\nПервый');
      final b = await file(tester, 'b/общий.md', '# Импорт Б\n\nВторой');
      await open(tester, paths: [a.path, b.path]);
      await importFiles(tester);
      await tester.tap(find.byTooltip('Закрепить').first);
      await settle(tester);
      final keptId = controller.blocks.first.id;
      await tester.tap(find.byTooltip('Импортированные файлы'));
      await settle(tester);
      expect(find.text('общий.md'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Удалить файл').last);
      await settle(tester);
      expect(find.text('Удалить импортированный файл?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Удалить'));
      await settle(tester);
      expect(controller.files, hasLength(1));
      expect(controller.blocks.single.id, keptId);
      expect(controller.blocks.single.pinned, isTrue);
      expect(await tester.runAsync(a.exists), isTrue);
      expect(await tester.runAsync(b.exists), isTrue);
    },
  );

  testWidgets(
    'Полная очистка явно удаляет закреплённое, предпочтения сохраняются',
    (tester) async {
      final input = await file(tester, 'всё.txt', '# Один\n\nТекст');
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      await tester.tap(find.byTooltip('Закрепить'));
      await settle(tester);
      await tester.tap(find.byTooltip('Настройки'));
      await settle(tester);
      await tester.tap(find.byType(Switch));
      await settle(tester);
      expect(controller.showDescriptions, isFalse);
      await tester.tap(find.byTooltip('Импортированные файлы').last);
      await settle(tester);
      await tester.tap(find.text('Удалить всё, включая закреплённое'));
      await settle(tester);
      expect(find.text('Удалить всё содержимое?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Удалить'));
      await settle(tester);
      expect(controller.blocks, isEmpty);
      expect(controller.files, isEmpty);
      expect(await tester.runAsync(repository.showDescriptions), isFalse);
    },
  );

  testWidgets('Прокрутка за выбранным блоком и длинные заголовки', (
    tester,
  ) async {
    final text = List.generate(
      30,
      (i) => '# Заголовок $i ${'длинный ' * 20}\n### Описание $i\n\nТекст $i',
    ).join('\n---\n');
    final input = await file(tester, 'много.md', text);
    await open(tester, paths: [input.path]);
    await importFiles(tester);
    for (var i = 0; i < 29; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('fullBlockContent'))).data,
      '\nТекст 29',
    );
    expect(find.textContaining('Заголовок 29'), findsOneWidget);
  });

  testWidgets(
    'Панель и настройки помещаются при минимальном размере Windows',
    (tester) async {
      tester.view.physicalSize = const Size(360, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final input = await file(
        tester,
        'очень длинное название импортированного файла.md',
        '# Заголовок\n### Описание\n\nТекст\n---\n# Второй\n\nТекст',
      );
      await open(tester, paths: [input.path]);
      await importFiles(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Заголовок'));
      await settle(tester);
      expect(find.byKey(const Key('fullBlockContent')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byTooltip('Настройки'));
      await settle(tester);
      expect(find.text('Запускать вместе с Windows'), findsOneWidget);
      await tester.tap(find.byTooltip('Импортированные файлы').last);
      await settle(tester);
      expect(find.textContaining('очень длинное название'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Горячие клавиши'));
      await settle(tester);
      expect(find.text('Ctrl + Shift + F12'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Меню карточки закрепляет, открепляет, копирует и удаляет блок', (
    tester,
  ) async {
    final input = await file(tester, 'меню.md', '# Меню\n\nПолный текст\n');
    await open(tester, paths: [input.path]);
    await importFiles(tester);
    Future<void> menu(String action) async {
      await tester.tap(find.byTooltip('Действия с блоком'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await settle(tester);
    }

    await menu('Закрепить');
    expect(controller.blocks.single.pinned, isTrue);
    await menu('Открепить');
    expect(controller.blocks.single.pinned, isFalse);
    await menu('Копировать');
    expect(clipboard, '\nПолный текст\n');
    await menu('Удалить');
    expect(controller.blocks, isEmpty);
    expect(controller.files, isEmpty);
  });

  testWidgets(
    'Ошибка одного файла не отменяет импорт остальных и видна в диалоге',
    (tester) async {
      final good = await file(tester, 'хороший.md', '# Импортирован\n\nТекст');
      final bad = await file(tester, 'ошибка.txt', '');
      await tester.runAsync(() => bad.writeAsBytes([0xff, 0xff]));
      await open(tester, paths: [good.path, bad.path]);
      await importFiles(tester);
      expect(find.text('Результат импорта'), findsOneWidget);
      expect(find.textContaining('ошибка.txt'), findsOneWidget);
      expect(controller.files, hasLength(1));
      await tester.tap(find.text('Понятно'));
      await settle(tester);
      expect(find.text('Импортирован'), findsOneWidget);
    },
  );

  testWidgets('Отмена выбора файла ничего не добавляет', (tester) async {
    await open(tester);
    await importFiles(tester);
    expect(controller.files, isEmpty);
    expect(controller.blocks, isEmpty);
  });

  testWidgets(
    'Предупреждение показывается до выбора файла; отмена не открывает выбор',
    (tester) async {
      var pickerCalls = 0;
      await tester.pumpWidget(
        MyApp(
          controller: controller,
          pickFiles: () async {
            pickerCalls++;
            return [];
          },
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('Импортировать .md или .txt'));
      await tester.pumpAndSettle();
      expect(find.text('Импорт во время демонстрации'), findsOneWidget);
      expect(find.textContaining('имена файлов и пути'), findsOneWidget);
      expect(pickerCalls, 0);
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect(pickerCalls, 0);
      expect(controller.files, isEmpty);
      await tester.tap(find.byTooltip('Импортировать .md или .txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить импорт'));
      await settle(tester);
      expect(pickerCalls, 1);
    },
  );

  testWidgets(
    'Подсказки, уведомления и диалоги используют тот же полупрозрачный фон',
    (tester) async {
      final input = await file(tester, 'оформление.md', '# Карточка\n\nТекст');
      await open(tester, paths: [input.path]);
      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.snackBarTheme.backgroundColor, PanelStyle.surface);
      expect(theme.popupMenuTheme.color, PanelStyle.surface);
      expect(theme.dialogTheme.backgroundColor, PanelStyle.surface);
      expect(theme.dialogTheme.barrierColor, Colors.transparent);
      final tooltipDecoration = theme.tooltipTheme.decoration! as BoxDecoration;
      expect(tooltipDecoration.color, PanelStyle.surface);
      expect(theme.tooltipTheme.textStyle!.color, Colors.white);
      expect(PanelStyle.surface.a, 0.5);

      tester
          .state<TooltipState>(
            find.byWidgetPredicate(
              (widget) => widget is Tooltip && widget.message == 'Настройки',
            ),
          )
          .ensureTooltipVisible();
      await tester.pumpAndSettle();
      expect(find.text('Настройки'), findsOneWidget);
      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .any(
              (box) =>
                  box.decoration is BoxDecoration &&
                  (box.decoration as BoxDecoration).color == PanelStyle.surface,
            ),
        isTrue,
      );
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Импортировать .md или .txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить импорт'));
      await settle(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        tester
            .widgetList<Material>(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.byType(Material),
              ),
            )
            .any(
              (material) =>
                  material.color == PanelStyle.surface &&
                  material.elevation == 0,
            ),
        isTrue,
      );
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Очистить'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Material>(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              ),
            )
            .any(
              (material) =>
                  material.color == PanelStyle.surface &&
                  material.elevation == 0,
            ),
        isTrue,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    },
  );
}
