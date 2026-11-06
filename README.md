# helper

A new Flutter project.

## Прозрачное окно Windows

На Windows фон окна полностью прозрачный, стандартная рамка и тень отключены,
а окно закреплено поверх остальных обычных окон. Панели имеют скругление 20 px
и непрозрачность фона 50%; текст и кнопки остаются непрозрачными.
Перетаскивание — за заголовок Helper; справа — сворачивание и закрытие.

Запуск на Windows (Windows 10 1803+ / Windows 11):

```sh
flutter pub get
flutter run -d windows
```

Для сборки нужен Visual Studio с компонентами Desktop development with C++.
Настройки нативного окна применяются только на Windows. После изменения плагинов
или Windows runner требуется полный перезапуск, а не hot reload.

### Исключение из захвата экрана (OBS)

До показа окна Windows runner автоматически устанавливает
`SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` для главного окна.
Локально Helper остаётся видимым и поверх других окон, но совместимые API
захвата исключают его из изображения. При ошибке Win32 её код выводится в stderr;
приложение продолжает работу, но исключение из захвата не гарантируется.

- Для полноценного исключения нужна Windows 10 версии 2004+ или Windows 11.
  На более старых версиях вместо окна может записываться чёрная область.
- В OBS проверьте результат отдельно для используемого источника и метода
  захвата (например, Windows Graphics Capture). Это не универсальная защита:
  другие методы, плагины или внешняя камера могут захватить окно.
- Перед демонстрацией сделайте пробную запись с Helper поверх другого окна
  и проверьте именно запись. Не полагайтесь на этот механизм для защиты секретов.
- После изменения C++ выполните полную пересборку на Windows:
  `flutter build windows` или остановите приложение и запустите
  `flutter run -d windows` заново.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
