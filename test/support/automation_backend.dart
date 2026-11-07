import 'dart:async';

import 'package:flutter/services.dart';
import 'package:helper/automation/text_automation.dart';

// Only the platform boundary is replaced. No synthetic timer is used by the
// application; tests explicitly deliver snapshots to check Dart/UI behavior.
class TestAutomationBackend extends AutomationBackend {
  final calls = <(String, Object?)>[];
  Map<String, Object?> data = {
    'phase': 'idle',
    'blockId': 0,
    'position': 0,
    'total': 0,
    'countdown': 0,
    'speed': 1000,
    'revision': 0,
    'stopToken': 0,
    'message': '',
  };
  bool emergencyAvailable = true;
  bool speedFailure = false;
  bool disposed = false;
  Completer<void>? startGate;
  Completer<void>? startEntered;
  String? receivedText;
  bool resuming = false;

  void emit(
    AutomationPhase phase, {
    int? position,
    int? revision,
    int? stopToken,
    String? message,
  }) {
    data['phase'] = phase.name;
    data['revision'] = revision ?? (data['revision'] as int) + 1;
    if (position != null) data['position'] = position;
    if (stopToken != null) data['stopToken'] = stopToken;
    if (message != null) data['message'] = message;
    onState?.call(AutomationState.fromMap({...data}));
  }

  @override
  Future<AutomationState> invoke(String command, [Object? arguments]) async {
    calls.add((command, arguments));
    switch (command) {
      case 'getState':
        break;
      case 'setSpeed':
        if (speedFailure) {
          throw PlatformException(
            code: 'automation_error',
            message: 'Скорость не применена.',
          );
        }
        data['speed'] = arguments as int;
        emit(AutomationPhase.values.byName(data['phase'] as String));
      case 'start':
        final args = arguments as Map<String, Object?>;
        if (startEntered != null && !startEntered!.isCompleted) {
          startEntered!.complete();
        }
        if (startGate != null) await startGate!.future;
        if (args['stopToken'] != data['stopToken']) {
          throw PlatformException(
            code: 'automation_error',
            message: 'Запуск отменён командой остановки.',
          );
        }
        if (!emergencyAvailable) {
          throw PlatformException(
            code: 'automation_error',
            message: 'Не зарегистрирована клавиша остановки.',
          );
        }
        receivedText = args['text'] as String;
        data['blockId'] = args['blockId'];
        data['speed'] = args['speed'];
        data['position'] = 0;
        data['total'] = receivedText!.runes.length;
        data['countdown'] = 5;
        resuming = false;
        emit(AutomationPhase.countdown);
      case 'pause':
        emit(AutomationPhase.paused);
      case 'resume':
        resuming = true;
        data['countdown'] = 5;
        emit(AutomationPhase.countdown);
      case 'cancelCountdown':
        if (!resuming) data['stopToken'] = (data['stopToken'] as int) + 1;
        emit(resuming ? AutomationPhase.paused : AutomationPhase.stopped);
      case 'stop':
        data['stopToken'] = (data['stopToken'] as int) + 1;
        data['countdown'] = 0;
        emit(AutomationPhase.stopped);
      default:
        throw MissingPluginException(command);
    }
    return AutomationState.fromMap({...data});
  }

  @override
  void dispose() {
    disposed = true;
    onState = null;
    onStartRequested = null;
  }
}
