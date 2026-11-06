import 'package:flutter/services.dart';

class Hotkey {
  const Hotkey(this.modifiers, this.key);

  factory Hotkey.fromMap(Map<Object?, Object?> map) =>
      Hotkey(map['modifiers'] as int, map['key'] as int);

  static const defaultToggle = Hotkey(6, 0x7b);
  static const defaultExit = Hotkey(6, 0x7a);
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
      name = 'Numpad ${key - 0x60}';
    } else {
      name = _keyNames[key];
    }
    parts.add(name ?? 'VK 0x${key.toRadixString(16)}');
    return parts.join(' + ');
  }

  static const _keyNames = <int, String>{
    8: 'Backspace',
    9: 'Tab',
    13: 'Enter',
    32: 'Space',
    33: 'Page Up',
    34: 'Page Down',
    35: 'End',
    36: 'Home',
    37: 'Left',
    38: 'Up',
    39: 'Right',
    40: 'Down',
    45: 'Insert',
    46: 'Delete',
    106: 'Numpad *',
    107: 'Numpad +',
    109: 'Numpad -',
    110: 'Numpad .',
    111: 'Numpad /',
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

class BackgroundSettings {
  BackgroundSettings.fromMap(Map<Object?, Object?> map)
    : toggle = Hotkey.fromMap(map['toggle'] as Map<Object?, Object?>),
      exit = Hotkey.fromMap(map['exit'] as Map<Object?, Object?>),
      active = map['active'] as bool,
      warning = map['warning'] as String;

  final Hotkey toggle;
  final Hotkey exit;
  final bool active;
  final String warning;
}

class BackgroundService {
  BackgroundService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'recorded') {
        onRecorded?.call(
          Hotkey.fromMap(call.arguments as Map<Object?, Object?>),
        );
      }
    });
  }

  static final instance = BackgroundService._();
  static const _channel = MethodChannel('helper/background');
  void Function(Hotkey)? onRecorded;

  Future<BackgroundSettings> getSettings() async => BackgroundSettings.fromMap(
    (await _channel.invokeMapMethod<Object?, Object?>('getSettings'))!,
  );

  Future<BackgroundSettings> save(Hotkey toggle, Hotkey exit) async {
    if (toggle.modifiers == 0 || exit.modifiers == 0) {
      throw const FormatException('Use at least one modifier key.');
    }
    if (toggle.sameAs(exit)) {
      throw const FormatException('The two shortcuts must be different.');
    }
    return BackgroundSettings.fromMap(
      (await _channel.invokeMapMethod<Object?, Object?>('saveSettings', {
        'toggle': toggle.toMap(),
        'exit': exit.toMap(),
      }))!,
    );
  }

  Future<void> setRecording(bool enabled) =>
      _channel.invokeMethod<void>('setRecording', enabled);
  Future<void> hide() => _channel.invokeMethod<void>('hide');
  Future<void> show() => _channel.invokeMethod<void>('show');
  Future<void> exit() => _channel.invokeMethod<void>('exit');
}
