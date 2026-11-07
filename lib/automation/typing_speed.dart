/// Characters per minute, shared by settings, persistence and automation UI.
abstract final class TypingSpeed {
  static const min = 300;
  static const max = 2000;
  static const normal = 1000;
  static const validationMessage =
      'Скорость должна быть от 300 до 2000 символов в минуту.';
}
