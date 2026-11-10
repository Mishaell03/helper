import 'package:flutter/services.dart';
import 'auto_hide_settings.dart';

class Hotkey {
  const Hotkey(this.modifiers, this.key);

  factory Hotkey.fromMap(Map<Object?, Object?> map) =>
      Hotkey(map['modifiers'] as int, map['key'] as int);

  static const defaultToggle = Hotkey(6, 0x7b);
  static const defaultExit = Hotkey(6, 0x73);
  static const defaultStart = Hotkey(6, 0x75);
  static const defaultPause = Hotkey(6, 0x76);
  static const defaultStop = Hotkey(6, 0x77);
  static const defaultSlotToggle = Hotkey(6, 0x72);
  static const defaultSlotPrevious = Hotkey(6, 0x25);
  static const defaultSlotNext = Hotkey(6, 0x27);
  final int modifiers; // Win32 MOD_ALT=1, CONTROL=2, SHIFT=4, WIN=8.
  final int key; // Win32 virtual key, not a Flutter key ID.

  Map<String, int> toMap() => {'modifiers': modifiers, 'key': key};

  bool sameAs(Hotkey other) => modifiers == other.modifiers && key == other.key;

  String get label {
    final parts = <String>[
      if (modifiers & 2 != 0) 'Ctrl',
      if (modifiers & 1 != 0) 'Alt',
      if (modifiers & 4 != 0) 'Shift',
      if (modifiers & 8 != 0) 'Win',
    ];
    String? name;
    if (key >= 0x70 && key <= 0x87) {
      name = 'F${key - 0x6f}';
    } else if ((key >= 0x41 && key <= 0x5a) || (key >= 0x30 && key <= 0x39)) {
      name = String.fromCharCode(key);
    } else if (key >= 0x60 && key <= 0x69) {
      name = 'Цифр. ${key - 0x60}';
    } else {
      name = _keyNames[key];
    }
    parts.add(name ?? 'Клавиша 0x${key.toRadixString(16)}');
    return parts.join(' + ');
  }

  static const _keyNames = <int, String>{
    8: 'Забой',
    9: 'Табуляция',
    13: 'Ввод',
    32: 'Пробел',
    33: 'Страница вверх',
    34: 'Страница вниз',
    35: 'Конец',
    36: 'Начало',
    37: '←',
    38: '↑',
    39: '→',
    40: '↓',
    45: 'Вставка',
    46: 'Удаление',
    106: 'Цифр. *',
    107: 'Цифр. +',
    109: 'Цифр. -',
    110: 'Цифр. .',
    111: 'Цифр. /',
    186: ';',
    187: '=',
    188: ',',
    189: '-',
    190: '.',
    191: '/',
    192: '`',
    219: '[',
    220: '\\',
    221: ']',
    222: "'",
  };

  /// Physical positions map to Win32 VKs (including with non-Latin layouts).
  static Hotkey? fromEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final usage = event.physicalKey.usbHidUsage;
    int? key;
    if (usage >= 0x70004 && usage <= 0x7001d) {
      key = 0x41 + usage - 0x70004;
    } else if (usage >= 0x7001e && usage <= 0x70026) {
      key = 0x31 + usage - 0x7001e;
    } else if (usage == 0x70027) {
      key = 0x30;
    } else if (usage >= 0x7003a && usage <= 0x70045) {
      key = 0x70 + usage - 0x7003a;
    } else if (usage >= 0x70068 && usage <= 0x70073) {
      key = 0x7c + usage - 0x70068;
    } else if (usage >= 0x70059 && usage <= 0x70061) {
      key = 0x61 + usage - 0x70059;
    } else {
      key = _physicalKeys[usage];
    }
    if (key == null) return null;
    final keyboard = HardwareKeyboard.instance;
    final modifiers =
        (keyboard.isAltPressed ? 1 : 0) |
        (keyboard.isControlPressed ? 2 : 0) |
        (keyboard.isShiftPressed ? 4 : 0) |
        (keyboard.isMetaPressed ? 8 : 0);
    return Hotkey(modifiers, key);
  }

  static const _physicalKeys = <int, int>{
    0x70028: 13,
    0x7002a: 8,
    0x7002b: 9,
    0x7002c: 32,
    0x7002d: 189,
    0x7002e: 187,
    0x7002f: 219,
    0x70030: 221,
    0x70031: 220,
    0x70033: 186,
    0x70034: 222,
    0x70035: 192,
    0x70036: 188,
    0x70037: 190,
    0x70038: 191,
    0x70049: 45,
    0x7004a: 36,
    0x7004b: 33,
    0x7004c: 46,
    0x7004d: 35,
    0x7004e: 34,
    0x7004f: 39,
    0x70050: 37,
    0x70051: 40,
    0x70052: 38,
    0x70054: 111,
    0x70055: 106,
    0x70056: 109,
    0x70057: 107,
    0x70058: 13,
    0x70062: 96,
    0x70063: 110,
    0x70064: 226,
  };
}

enum HotkeyAction {
  toggle('Показать / скрыть приложение', Hotkey.defaultToggle),
  exit('Полностью выйти из приложения', Hotkey.defaultExit),
  start('Начать автоматический ввод', Hotkey.defaultStart),
  pause('Пауза / продолжение ввода', Hotkey.defaultPause),
  stop('Остановить ввод (аварийная остановка)', Hotkey.defaultStop),
  slotToggle(
    'Включить / выключить навигацию по блокам',
    Hotkey.defaultSlotToggle,
  ),
  slotPrevious('Предыдущий блок', Hotkey.defaultSlotPrevious),
  slotNext('Следующий блок', Hotkey.defaultSlotNext);

  const HotkeyAction(this.label, this.defaultKey);
  final String label;
  final Hotkey defaultKey;
}

class BackgroundSettings {
  BackgroundSettings.fromMap(Map<Object?, Object?> map)
    : toggle = Hotkey.fromMap(map['toggle'] as Map<Object?, Object?>),
      exit = Hotkey.fromMap(map['exit'] as Map<Object?, Object?>),
      start = map['start'] == null
          ? Hotkey.defaultStart
          : Hotkey.fromMap(map['start'] as Map<Object?, Object?>),
      pause = map['pause'] == null
          ? Hotkey.defaultPause
          : Hotkey.fromMap(map['pause'] as Map<Object?, Object?>),
      stop = map['stop'] == null
          ? Hotkey.defaultStop
          : Hotkey.fromMap(map['stop'] as Map<Object?, Object?>),
      slotToggle = map['slotToggle'] == null
          ? Hotkey.defaultSlotToggle
          : Hotkey.fromMap(map['slotToggle'] as Map<Object?, Object?>),
      slotPrevious = map['slotPrevious'] == null
          ? Hotkey.defaultSlotPrevious
          : Hotkey.fromMap(map['slotPrevious'] as Map<Object?, Object?>),
      slotNext = map['slotNext'] == null
          ? Hotkey.defaultSlotNext
          : Hotkey.fromMap(map['slotNext'] as Map<Object?, Object?>),
      active = map['active'] as bool,
      warning = map['warning'] as String,
      autostart = map['autostart'] as bool,
      startHidden = map['startHidden'] as bool,
      slotNotificationEnabled = map['slotNotificationEnabled'] as bool? ?? true,
      normalAutoHide = AutoHideOption.fromMap(map['normalAutoHide'], 10),
      viewerAutoHide = AutoHideOption.fromMap(map['viewerAutoHide'], 30);

  final Hotkey toggle;
  final Hotkey exit;
  final Hotkey start;
  final Hotkey pause;
  final Hotkey stop;
  final Hotkey slotToggle;
  final Hotkey slotPrevious;
  final Hotkey slotNext;
  Hotkey hotkey(HotkeyAction action) => switch (action) {
    HotkeyAction.toggle => toggle,
    HotkeyAction.exit => exit,
    HotkeyAction.start => start,
    HotkeyAction.pause => pause,
    HotkeyAction.stop => stop,
    HotkeyAction.slotToggle => slotToggle,
    HotkeyAction.slotPrevious => slotPrevious,
    HotkeyAction.slotNext => slotNext,
  };
  final bool active;
  final String warning;
  final bool autostart;
  final bool startHidden;
  final bool slotNotificationEnabled;
  final AutoHideOption normalAutoHide;
  final AutoHideOption viewerAutoHide;
}

class BackgroundService {
  BackgroundService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'recorded') {
        onRecorded?.call(
          Hotkey.fromMap(call.arguments as Map<Object?, Object?>),
        );
      } else if (call.method == 'warning') {
        onWarning?.call(call.arguments as String);
      } else if (call.method == 'navigateSlot') {
        final delta = call.arguments;
        if (delta is int && (delta == -1 || delta == 1)) {
          onNavigateSlot?.call(delta);
        }
      } else if (call.method == 'closeViewer') {
        onCloseViewer?.call();
      }
    });
  }

  static final instance = BackgroundService._();
  static const _channel = MethodChannel('helper/background');
  void Function(Hotkey)? onRecorded;
  void Function(String)? onWarning;
  void Function(int)? onNavigateSlot;
  void Function()? onCloseViewer;

  Future<BackgroundSettings> getSettings() async => BackgroundSettings.fromMap(
    (await _channel.invokeMapMethod<Object?, Object?>('getSettings'))!,
  );

  Future<BackgroundSettings> save(
    Hotkey toggle,
    Hotkey exit, {
    Hotkey? start,
    Hotkey? pause,
    Hotkey? stop,
    Hotkey? slotToggle,
    Hotkey? slotPrevious,
    Hotkey? slotNext,
  }) async {
    final keys = [
      toggle,
      exit,
      ?start,
      ?pause,
      ?stop,
      ?slotToggle,
      ?slotPrevious,
      ?slotNext,
    ];
    if (keys.any((key) => key.modifiers == 0)) {
      throw const FormatException('Добавьте Ctrl, Alt, Shift или Win.');
    }
    for (var i = 0; i < keys.length; i++) {
      if (keys.take(i).any(keys[i].sameAs)) {
        throw const FormatException(
          'Для разных действий нужны разные сочетания клавиш.',
        );
      }
    }
    return BackgroundSettings.fromMap(
      (await _channel.invokeMapMethod<Object?, Object?>('saveSettings', {
        'toggle': toggle.toMap(),
        'exit': exit.toMap(),
        if (start != null) 'start': start.toMap(),
        if (pause != null) 'pause': pause.toMap(),
        if (stop != null) 'stop': stop.toMap(),
        if (slotToggle != null) 'slotToggle': slotToggle.toMap(),
        if (slotPrevious != null) 'slotPrevious': slotPrevious.toMap(),
        if (slotNext != null) 'slotNext': slotNext.toMap(),
      }))!,
    );
  }

  Future<void> setRecording(bool enabled) =>
      _channel.invokeMethod<void>('setRecording', enabled);
  Future<void> helperActivity() =>
      _channel.invokeMethod<void>('helperActivity');
  Future<void> setAutoHideContext({
    required bool viewer,
    required bool suspended,
  }) => _channel.invokeMethod<void>('setAutoHideContext', {
    'viewer': viewer,
    'suspended': suspended,
  });
  Future<void> setAutoHideModalOpen(bool value) =>
      _channel.invokeMethod<void>('setAutoHideModalOpen', value);
  Future<void> setAutoHidePointerHeld(bool value) =>
      _channel.invokeMethod<void>('setAutoHidePointerHeld', value);
  Future<BackgroundSettings> setAutoHideSettings(
    AutoHideOption normal,
    AutoHideOption viewer,
  ) async {
    if (!AutoHideOption.durations.contains(normal.seconds) ||
        !AutoHideOption.durations.contains(viewer.seconds)) {
      throw const FormatException(
        'Выберите время от 10 до 60 секунд с шагом 5 секунд.',
      );
    }
    return BackgroundSettings.fromMap(
      (await _channel.invokeMapMethod<Object?, Object?>('setAutoHideSettings', {
        'normalAutoHide': normal.toMap(),
        'viewerAutoHide': viewer.toMap(),
      }))!,
    );
  }

  Future<void> resetApplicationSettings() =>
      _channel.invokeMethod<void>('resetApplicationSettings');
  Future<void> setDataResetting(bool enabled) =>
      _channel.invokeMethod<void>('setDataResetting', enabled);
  Future<void> setViewerEscapeEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setViewerEscapeEnabled', enabled);
  Future<void> selectedBlockChanged(int? id, String name) =>
      _channel.invokeMethod<void>('selectedBlockChanged', {
        'id': id ?? 0,
        'name': name,
      });
  Future<BackgroundSettings> setSlotNotificationEnabled(bool enabled) async =>
      BackgroundSettings.fromMap(
        (await _channel.invokeMapMethod<Object?, Object?>(
          'setSlotNotificationEnabled',
          enabled,
        ))!,
      );
  Future<BackgroundSettings> prepareWindow() async =>
      BackgroundSettings.fromMap(
        (await _channel.invokeMapMethod<Object?, Object?>('prepareWindow'))!,
      );
  Future<BackgroundSettings> setAutostart(bool enabled) async =>
      BackgroundSettings.fromMap(
        (await _channel.invokeMapMethod<Object?, Object?>(
          'setAutostart',
          enabled,
        ))!,
      );
  Future<void> hide() => _channel.invokeMethod<void>('hide');
  Future<void> show() => _channel.invokeMethod<void>('show');
  Future<void> finishStartup() => _channel.invokeMethod<void>('finishStartup');
  Future<void> heartbeat() => _channel.invokeMethod<void>('heartbeat');
  Future<void> reportBlockStage(int stage, int blockId, {int length = 0}) =>
      _channel.invokeMethod<void>('blockStage', {
        'stage': stage,
        'blockId': blockId,
        'length': length,
      });
  Future<void> exit() => _channel.invokeMethod<void>('exit');
  Future<List<String>> pickMarkdownFiles() async =>
      (await _channel.invokeListMethod<String>('pickMarkdownFiles')) ?? [];
  Future<String> storageDirectory() async =>
      (await _channel.invokeMethod<String>('getStorageDirectory'))!;
}

String backgroundError(Object error) {
  if (error is FormatException) return error.message;
  if (error is PlatformException &&
      const {
        'invalid_hotkey',
        'hotkey_error',
        'invalid_argument',
        'autostart_error',
        'window_style_error',
        'import_error',
        'storage_error',
      }.contains(error.code)) {
    return error.message ?? 'Не удалось выполнить действие.';
  }
  return 'Не удалось выполнить действие. Перезапустите приложение и повторите попытку.';
}
