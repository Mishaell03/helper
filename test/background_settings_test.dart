import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/background_service.dart';
import 'package:helper/hotkey_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('helper/background');
  var toggle = Hotkey.defaultToggle;
  var exit = Hotkey.defaultExit;
  var autostart = false;
  var conflict = false;
  var autostartFailure = false;
  var recording = false;
  var saves = 0;

  Map<String, Object> state() => {
    'toggle': toggle.toMap(),
    'exit': exit.toMap(),
    'active': true,
    'warning': '',
    'autostart': autostart,
    'startHidden': false,
  };

  setUp(() {
    toggle = Hotkey.defaultToggle;
    exit = Hotkey.defaultExit;
    autostart = false;
    conflict = false;
    autostartFailure = false;
    recording = false;
    saves = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getSettings':
            case 'prepareWindow':
              return state();
            case 'setRecording':
              recording = call.arguments as bool;
              return null;
            case 'saveSettings':
              saves++;
              if (conflict) {
                throw PlatformException(
                  code: 'hotkey_error',
                  message: 'Сочетание занято. Выберите другое.',
                );
              }
              final args = call.arguments as Map<Object?, Object?>;
              toggle = Hotkey.fromMap(args['toggle'] as Map<Object?, Object?>);
              exit = Hotkey.fromMap(args['exit'] as Map<Object?, Object?>);
              return state();
            case 'setAutostart':
              if (autostartFailure) {
                throw PlatformException(
                  code: 'autostart_error',
                  message: 'Не удалось включить автозапуск.',
                );
              }
              autostart = call.arguments as bool;
              return state();
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ru'),
        supportedLocales: [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: HotkeySettings(),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('Новые значения по умолчанию используют F12 и F4', () {
    expect(Hotkey.defaultToggle.label, 'Ctrl + Shift + F12');
    expect(Hotkey.defaultExit.label, 'Ctrl + Shift + F4');
    expect(Hotkey.defaultExit.toMap(), {'modifiers': 6, 'key': 0x73});
  });

  test('Одинаковые сочетания и отсутствие модификаторов отклоняются', () async {
    final service = BackgroundService.instance;
    await expectLater(
      service.save(Hotkey.defaultToggle, Hotkey.defaultToggle),
      throwsFormatException,
    );
    await expectLater(
      service.save(const Hotkey(0, 0x73), Hotkey.defaultToggle),
      throwsFormatException,
    );
    expect(saves, 0);
  });

  testWidgets('Русские настройки и текущие сочетания', (tester) async {
    await open(tester);
    expect(find.text('Настройки приложения'), findsOneWidget);
    expect(find.text('Ctrl + Shift + F12'), findsOneWidget);
    expect(find.text('Ctrl + Shift + F4'), findsOneWidget);
    expect(find.text('Запускать вместе с Windows'), findsOneWidget);
    expect(find.text('Hotkey Settings'), findsNothing);
  });

  testWidgets('Сохранение и конфликт отображаются по-русски', (tester) async {
    await open(tester);
    conflict = true;
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Сочетание занято. Выберите другое.'), findsOneWidget);
    expect(toggle.sameAs(Hotkey.defaultToggle), isTrue);
    conflict = false;
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(
      find.text('Сохранено. Глобальные горячие клавиши действуют.'),
      findsOneWidget,
    );
  });

  testWidgets('Восстановление значений по умолчанию применяется сразу', (
    tester,
  ) async {
    toggle = const Hotkey(3, 0x78);
    exit = const Hotkey(3, 0x79);
    await open(tester);
    final button = find.text('Восстановить настройки по умолчанию');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(toggle.sameAs(Hotkey.defaultToggle), isTrue);
    expect(exit.sameAs(Hotkey.defaultExit), isTrue);
  });

  testWidgets(
    'Автозапуск сохраняется через канал; при ошибке переключатель не меняется',
    (tester) async {
      await open(tester);
      await tester.ensureVisible(find.byType(SwitchListTile));
      autostartFailure = true;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(find.text('Не удалось включить автозапуск.'), findsOneWidget);
      autostartFailure = false;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(autostart, isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(autostart, isFalse);
    },
  );

  testWidgets('Запись комбинации клавиатурой и завершение записи', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Ctrl + Shift + F12'));
    await tester.pumpAndSettle();
    expect(recording, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Ctrl + Shift + F8'), findsOneWidget);
    await tester.tap(find.text('Использовать'));
    await tester.pumpAndSettle();
    expect(recording, isFalse);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(toggle.sameAs(const Hotkey(6, 0x77)), isTrue);
  });

  testWidgets('Запись поддерживает Alt и Win; отмена оставляет назначения', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Ctrl + Shift + F12'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f24, platform: 'windows');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text('Alt + Win + F24'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(recording, isFalse);
    expect(find.text('Ctrl + Shift + F12'), findsOneWidget);
    expect(saves, 0);
  });

  testWidgets(
    'Окно и настройки помещаются в минимальный размер 360 × 300',
    (tester) async {
      tester.view.physicalSize = const Size(360, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await open(tester);
      expect(find.text('Запускать вместе с Windows'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Зарегистрированное сочетание записывается через событие Win32', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Ctrl + Shift + F4'));
    await tester.pumpAndSettle();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('recorded', Hotkey.defaultToggle.toMap()),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Использовать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(
      find.text('Для двух действий нужны разные сочетания клавиш.'),
      findsOneWidget,
    );
    expect(saves, 0);
    expect(recording, isFalse);
  });
}
