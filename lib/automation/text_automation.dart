import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../markdown/markdown_repository.dart';

enum AutomationPhase {
  idle,
  countdown,
  typing,
  paused,
  stopped,
  completed,
  error,
}

class AutomationState {
  const AutomationState({
    this.phase = AutomationPhase.idle,
    this.blockId = 0,
    this.position = 0,
    this.total = 0,
    this.countdown = 0,
    this.speed = 180,
    this.message = '',
    this.revision = 0,
    this.stopToken = 0,
  });

  factory AutomationState.fromMap(Map<Object?, Object?> map) => AutomationState(
    phase: AutomationPhase.values.firstWhere(
      (phase) => phase.name == map['phase'],
      orElse: () => AutomationPhase.error,
    ),
    blockId: map['blockId'] as int? ?? 0,
    position: map['position'] as int? ?? 0,
    total: map['total'] as int? ?? 0,
    countdown: map['countdown'] as int? ?? 0,
    speed: map['speed'] as int? ?? 180,
    message: map['message'] as String? ?? '',
    revision: map['revision'] as int? ?? 0,
    stopToken: map['stopToken'] as int? ?? 0,
  );

  final AutomationPhase phase;
  final int blockId;
  final int position;
  final int total;
  final int countdown;
  final int speed;
  final String message;
  final int revision;
  final int stopToken;

  bool get engaged =>
      phase == AutomationPhase.countdown ||
      phase == AutomationPhase.typing ||
      phase == AutomationPhase.paused;
  String get label => switch (phase) {
    AutomationPhase.idle => 'Готово к вводу',
    AutomationPhase.countdown => 'Начало через $countdown с',
    AutomationPhase.typing => 'Ввод текста',
    AutomationPhase.paused => 'Пауза',
    AutomationPhase.stopped => 'Остановлено',
    AutomationPhase.completed => 'Завершено',
    AutomationPhase.error => 'Ошибка ввода',
  };
}

abstract class AutomationBackend {
  void Function(AutomationState)? onState;
  void Function()? onStartRequested;
  Future<AutomationState> invoke(String command, [Object? arguments]);
  void dispose();
}

class Win32AutomationBackend extends AutomationBackend {
  Win32AutomationBackend() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') {
        onState?.call(
          AutomationState.fromMap(call.arguments as Map<Object?, Object?>),
        );
      } else if (call.method == 'startRequested') {
        onStartRequested?.call();
      }
    });
  }
  static const _channel = MethodChannel('helper/automation');
  @override
  Future<AutomationState> invoke(String command, [Object? arguments]) async =>
      AutomationState.fromMap(
        (await _channel.invokeMapMethod<Object?, Object?>(command, arguments))!,
      );
  @override
  void dispose() => _channel.setMethodCallHandler(null);
}

class TextAutomationController extends ChangeNotifier {
  TextAutomationController(this.repository, {AutomationBackend? backend})
    : _backend = backend ?? Win32AutomationBackend() {
    _backend.onState = _apply;
    _backend.onStartRequested = () => onStartRequested?.call();
  }
  final MarkdownRepository repository;
  final AutomationBackend _backend;
  AutomationState state = const AutomationState();
  bool ready = false;
  bool commandPending = false;
  int speed = 180;
  int? preparingBlock;
  String? failure;
  VoidCallback? onStartRequested;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _speedTail = Future.value();
  int _speedGeneration = 0;
  int _pendingSpeedRequests = 0;
  bool get savingPreferences => _pendingSpeedRequests != 0;

  bool protects(int id) =>
      preparingBlock == id || state.engaged && state.blockId == id;
  bool get canStart => ready && !commandPending && !state.engaged;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _apply(AutomationState next) {
    if (_disposed || next.revision < state.revision) return;
    if (next.stopToken > state.stopToken) {
      ++_generation;
      preparingBlock = null;
    }
    state = next;
    _notify();
  }

  Future<void> initialize() async {
    try {
      speed = await repository.typingSpeed();
      _apply(await _backend.invoke('getState'));
      if (_disposed) return;
      if (state.engaged) {
        speed = state.speed;
      } else {
        _apply(await _backend.invoke('setSpeed', speed));
      }
      ready = true;
    } catch (error) {
      failure = automationError(error);
    }
    _notify();
  }

  Future<void> start(int blockId) async {
    if (!canStart) return;
    final generation = ++_generation;
    commandPending = true;
    preparingBlock = blockId;
    failure = null;
    _notify();
    try {
      await _speedTail;
      if (_disposed || generation != _generation) return;
      // Always read the complete immutable source, never a truncated preview.
      final block = await repository.block(blockId);
      if (_disposed || generation != _generation) return;
      _apply(
        await _backend.invoke('start', {
          'blockId': blockId,
          'text': block.content,
          'speed': speed,
          'stopToken': state.stopToken,
        }),
      );
    } catch (error) {
      if (!_disposed && generation == _generation) {
        failure = automationError(error);
      }
    } finally {
      commandPending = false;
      preparingBlock = null;
      _notify();
    }
  }

  Future<void> _command(String command) async {
    failure = null;
    try {
      _apply(await _backend.invoke(command));
    } catch (error) {
      if (!_disposed) failure = automationError(error);
    }
    _notify();
  }

  Future<void> pause() => _command('pause');
  Future<void> resume() async {
    if (commandPending || state.phase != AutomationPhase.paused) return;
    commandPending = true;
    _notify();
    final generation = ++_generation;
    try {
      await _speedTail;
      if (_disposed || generation != _generation) return;
      await _command('resume');
    } finally {
      commandPending = false;
      _notify();
    }
  }

  Future<void> stop() {
    ++_generation;
    preparingBlock = null;
    return _command('stop');
  }

  Future<void> cancelCountdown() => _command('cancelCountdown');

  void previewSpeed(int value) {
    speed = value.clamp(30, 500);
    _notify();
  }

  Future<void> setSpeed(int value) {
    if (value < 30 || value > 500) {
      throw const FormatException(
        'Скорость должна быть от 30 до 500 символов в минуту.',
      );
    }
    speed = value;
    final generation = ++_speedGeneration;
    ++_pendingSpeedRequests;
    _notify();
    final operation = _speedTail.then((_) async {
      if (_disposed) {
        --_pendingSpeedRequests;
        return;
      }
      try {
        _apply(await _backend.invoke('setSpeed', value));
        await repository.setTypingSpeed(value);
        failure = null;
      } catch (error) {
        if (!_disposed) {
          failure = automationError(error);
          if (generation == _speedGeneration) speed = state.speed;
        }
      }
      --_pendingSpeedRequests;
      _notify();
    });
    _speedTail = operation;
    return operation;
  }

  Future<void> flushPreferences() => _speedTail;

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    // A Dart view may be disposed while Windows keeps the process alive.
    // Stop native timers/input observers before detaching the event handler.
    unawaited(
      _backend.invoke('stop').then<void>((_) {}, onError: (Object _) {}),
    );
    _backend.dispose();
    super.dispose();
  }
}

String automationError(Object error) {
  if (error is FormatException) return error.message;
  if (error is PlatformException && error.code == 'automation_error') {
    return error.message ?? 'Не удалось выполнить автоматический ввод.';
  }
  return 'Не удалось выполнить автоматический ввод или сохранить скорость. Проверьте локальное хранилище и перезапустите приложение.';
}
