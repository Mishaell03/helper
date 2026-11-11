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
OSVERSIONINFOW WindowsVersion() {
  using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  const HMODULE module = GetModuleHandleW(L"ntdll.dll");
  if (!module) return {};
  const auto get_version = reinterpret_cast<RtlGetVersion>(GetProcAddress(module, "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  return get_version && get_version(&version) == 0 ? version : OSVERSIONINFOW{};
}
}  // namespace

DWORD CaptureWindowsBuild() {
  static const auto version = WindowsVersion();
  return version.dwBuildNumber;
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
  const auto version = WindowsVersion();
  trace << "Helper capture diagnostics v5; app=" << FLUTTER_VERSION
        << "; windows_version=" << version.dwMajorVersion << '.' << version.dwMinorVersion
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
  DWORD owner = 0;
  const DWORD thread = GetWindowThreadProcessId(window, &owner);
  DWORD affinity = 0;
  SetLastError(ERROR_SUCCESS);
  const BOOL affinity_ok = GetWindowDisplayAffinity(window, &affinity);
  const DWORD affinity_error = affinity_ok ? ERROR_SUCCESS : GetLastError();
  DWORD cloaked = 0;
  BOOL composition = FALSE;
  const HRESULT composition_result = DwmIsCompositionEnabled(&composition);
  const HRESULT cloak_result = DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  std::ostringstream record;
  record << GetTickCount64() << " event=" << event
         << " hwnd=" << window << " hidden=" << hidden << " parked=" << parked
         << " valid=" << IsWindow(window)
         << " owner_pid=" << owner << " thread=" << thread
         << " own_process=" << (owner == GetCurrentProcessId())
         << " top_level=" << (window && GetAncestor(window, GA_ROOT) == window)
         << " composition=" << composition << " composition_hr=" << static_cast<long>(composition_result)
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

std::string CaptureErrorMessage(DWORD error) {
  if (!error) return "no extended Win32 error supplied";
  wchar_t message[1024]{};
  const DWORD length = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, 0, message, 1024, nullptr);
  if (!length) return "system message unavailable";
  const int size = WideCharToMultiByte(CP_UTF8, 0, message, static_cast<int>(length),
                                      nullptr, 0, nullptr, nullptr);
  if (!size) return "system message unavailable";
  std::string text(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, message, static_cast<int>(length), text.data(), size, nullptr, nullptr);
  for (auto& c : text) if (c == '\r' || c == '\n') c = ' ';
  return text;
}

void TraceCaptureApi(const char* operation, HWND window, bool success, DWORD error, HRESULT result) {
  if (!trace_enabled.load()) return;
  std::ostringstream record;
  record << GetTickCount64() << " api=" << operation << " hwnd=" << window
         << " success=" << success << " win32=" << error
         << " hresult=0x" << std::hex << static_cast<unsigned long>(result) << std::dec;
  if (!success) {
    record << " message=" << CaptureErrorMessage(error ? error : static_cast<DWORD>(result));
  }
  std::lock_guard<std::mutex> lock(trace_mutex);
  trace << record.str() << '\n'; trace.flush();
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
