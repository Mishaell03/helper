#include "capture_diagnostics.h"

#include <dwmapi.h>
#include <shlobj.h>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <atomic>
#include <sstream>

namespace {
std::ofstream trace;
std::mutex trace_mutex;
std::atomic<bool> trace_enabled{false};
DWORD WindowsBuild() {
  using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  const HMODULE module = GetModuleHandleW(L"ntdll.dll");
  if (!module) return 0;
  const auto get_version = reinterpret_cast<RtlGetVersion>(GetProcAddress(module, "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  return get_version && get_version(&version) == 0 ? version.dwBuildNumber : 0;
}
}  // namespace

DWORD CaptureWindowsBuild() {
  static const DWORD build = WindowsBuild();
  return build;
}

bool UseStableCaptureSurface() {
  const DWORD build = CaptureWindowsBuild();
  // Win10 supports affinity, but hide/show can turn a protected Flutter surface
  // into a black captured rectangle. Avoid that transition, not the protection.
  return build >= 19041 && build < 22000;
}

void InitializeCaptureDiagnostics(bool enabled) {
  if (!enabled) return;
  std::lock_guard<std::mutex> lock(trace_mutex);
  if (trace.is_open()) return;
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) return;
  std::filesystem::path directory = std::filesystem::path(local) / L"Helper" / L"Diagnostics";
  CoTaskMemFree(local);
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return;
  SYSTEMTIME time{};
  GetLocalTime(&time);
  wchar_t name[100]{};
  swprintf_s(name, L"capture-%04u%02u%02u-%02u%02u%02u-%lu.log",
      static_cast<unsigned>(time.wYear), static_cast<unsigned>(time.wMonth),
      static_cast<unsigned>(time.wDay), static_cast<unsigned>(time.wHour),
      static_cast<unsigned>(time.wMinute), static_cast<unsigned>(time.wSecond),
      GetCurrentProcessId());
  trace.open(directory / name, std::ios::out | std::ios::trunc);
  if (!trace) return;
  trace << "Helper capture diagnostics v3; app=" << FLUTTER_VERSION
        << "; windows_build=" << CaptureWindowsBuild()
        << "; stable_surface=" << UseStableCaptureSurface()
        << "; pid=" << GetCurrentProcessId() << '\n';
  trace << "No text, screenshots or keyboard contents are collected.\n";
  trace.flush();
  trace_enabled.store(true);
}

void TraceCapture(const char* event, HWND window, bool hidden, bool parked, DWORD error) {
  if (!trace_enabled.load()) return;
  RECT rectangle{};
  GetWindowRect(window, &rectangle);
  DWORD affinity = 0;
  SetLastError(ERROR_SUCCESS);
  const BOOL affinity_ok = GetWindowDisplayAffinity(window, &affinity);
  const DWORD affinity_error = affinity_ok ? ERROR_SUCCESS : GetLastError();
  DWORD cloaked = 0;
  const HRESULT cloak_result = DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  std::ostringstream record;
  record << GetTickCount64() << " event=" << event
        << " hwnd=" << window << " hidden=" << hidden << " parked=" << parked
        << " visible=" << IsWindowVisible(window) << " iconic=" << IsIconic(window)
        << " foreground=" << (GetForegroundWindow() == window)
        << " rect=" << rectangle.left << ',' << rectangle.top << ',' << rectangle.right << ',' << rectangle.bottom
        << " style=0x" << std::hex << GetWindowLongPtr(window, GWL_STYLE)
        << " exstyle=0x" << GetWindowLongPtr(window, GWL_EXSTYLE)
        << " affinity=0x" << affinity << std::dec
        << " affinity_ok=" << affinity_ok << " affinity_error=" << affinity_error
        << " cloak_hr=" << static_cast<long>(cloak_result) << " cloaked=" << cloaked
        << " error=" << error << '\n';
  std::lock_guard<std::mutex> lock(trace_mutex);
  trace << record.str(); trace.flush();
}

void TraceCaptureFailure(const std::string& message) {
  if (!trace_enabled.load()) return;
  std::lock_guard<std::mutex> lock(trace_mutex);
  trace << GetTickCount64() << " failure=" << message << '\n';
  trace.flush();
}

void TraceCaptureNote(const std::string& message) {
  if (!trace_enabled.load()) return;
  std::lock_guard<std::mutex> lock(trace_mutex);
  trace << GetTickCount64() << " note=" << message << '\n';
  trace.flush();
}
