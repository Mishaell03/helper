#include "update_launcher.h"

#include <vector>

namespace {
std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : value) {
    if (c == L'\\') { ++slashes; continue; }
    if (c == L'\"') result.append(slashes * 2 + 1, L'\\');
    else result.append(slashes, L'\\');
    result += c;
    slashes = 0;
  }
  result.append(slashes * 2, L'\\');
  return result + L'\"';
}
}  // namespace

bool LaunchUpdateHelper(const std::wstring& work_directory,
                        const std::wstring& log_path, std::string* error,
                        HANDLE* process_handle) {
  if (work_directory.empty() || log_path.empty() ||
      GetFileAttributesW((work_directory + L"\\update.ps1").c_str()) == INVALID_FILE_ATTRIBUTES) {
    *error = "Не найден подготовленный сценарий обновления.";
    return false;
  }
  wchar_t system[MAX_PATH]{};
  const UINT length = GetSystemDirectoryW(system, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    *error = "Не удалось определить системный каталог Windows.";
    return false;
  }
  const std::wstring powershell = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::vector<wchar_t> executable(32768);
  const DWORD size = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (size == 0 || size >= executable.size()) {
    *error = "Не удалось определить папку установленного приложения.";
    return false;
  }
  const std::wstring current(executable.data(), size);
  const std::wstring install = current.substr(0, current.find_last_of(L"\\/"));
  std::wstring command = Quote(powershell) +
      L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
      Quote(work_directory + L"\\update.ps1") + L" -Mode Apply -WorkDir " +
      Quote(work_directory) + L" -InstallDir " + Quote(install) +
      L" -AppProcessId " + std::to_wstring(GetCurrentProcessId()) +
      L" -LogPath " + Quote(log_path);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW, nullptr, work_directory.c_str(), &startup, &process)) {
    *error = "Не удалось запустить отдельный процесс обновления (Win32 " +
        std::to_string(GetLastError()) + "). Приложение не будет закрыто.";
    return false;
  }
  CloseHandle(process.hThread);
  if (process_handle) *process_handle = process.hProcess;
  else CloseHandle(process.hProcess);
  return true;
}
