#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <memory>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  using ScopedHandle = std::unique_ptr<void, decltype(&CloseHandle)>;
  auto command_line_arguments = GetCommandLineArguments();
  const bool start_hidden = std::find(command_line_arguments.begin(),
      command_line_arguments.end(), "--background") != command_line_arguments.end();
  ScopedHandle mutex(CreateMutexW(nullptr, FALSE,
      L"Local\\Helper.Background.7AE7E251-1623-4D03-AD49-401B9D0CA3B1"), CloseHandle);
  const DWORD mutex_error = GetLastError();
  if (!mutex) {
    MessageBoxW(nullptr, L"Не удалось проверить, запущено ли приложение.", L"Помощник", MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Помощник");
    if (!existing) existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Helper");
    if (!existing) existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"helper");
    if (existing && !start_hidden) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(existing, &process_id);
      AllowSetForegroundWindow(process_id);
      PostMessage(existing, kShowHelper, 0, 0);
    }
    return EXIT_SUCCESS;
  }

  // Descendants inherit job membership. No breakaway is allowed. When Helper
  // exits, Windows closes this handle and terminates any remaining children.
  ScopedHandle job(CreateJobObjectW(nullptr, nullptr), CloseHandle);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                                      &limits, sizeof(limits)) ||
      !AssignProcessToJobObject(job.get(), GetCurrentProcess())) {
    MessageBoxW(nullptr, L"Не удалось создать группу фоновых процессов приложения.",
                L"Помощник", MB_ICONERROR);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Помощник", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
