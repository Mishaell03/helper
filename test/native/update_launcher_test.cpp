// Windows-only integration: terminate a kill-on-close job and verify that the
// actual PowerShell updater launched by production code continues outside it.
#include "../../windows/runner/update_launcher.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace fs = std::filesystem;

bool WaitFile(const fs::path& file) {
  const ULONGLONG deadline = GetTickCount64() + 20000;
  while (GetTickCount64() < deadline) {
    if (fs::exists(file)) return true;
    Sleep(50);
  }
  return false;
}

int wmain(int argc, wchar_t** argv) {
  if (argc == 3 && std::wstring(argv[1]) == L"--launch") {
    const fs::path work(argv[2]);
    std::string error;
    if (!LaunchUpdateHelper(work.wstring(), (work / L"test.log").wstring(), &error)) {
      std::ofstream(work / L"launch-error.txt") << error;
      return 1;
    }
    Sleep(60000); // The orchestrator terminates only this job-owned parent.
    return 0;
  }

  const fs::path work = fs::temp_directory_path() /
      (L"helper_update_job space '\u0422\u0435\u0441\u0442_" +
       std::to_wstring(GetCurrentProcessId()) + L"_" + std::to_wstring(GetTickCount64()));
  assert(fs::create_directory(work));
  std::ofstream(work / L"update.ps1") <<
      "param($Mode,$WorkDir,$InstallDir,[int]$AppProcessId,$LogPath)\n"
      "$ErrorActionPreference='Stop'\n"
      "$p=Get-Process -Id $AppProcessId\n"
      "$null=$p.Handle\n"
      "[IO.File]::WriteAllText((Join-Path $WorkDir 'ready'),'ready')\n"
      "$p.WaitForExit()\n"
      "[IO.File]::WriteAllText((Join-Path $WorkDir 'survived'),'ok')\n";
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  assert(job);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
  assert(SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)));
  wchar_t executable[32768]{};
  assert(GetModuleFileNameW(nullptr, executable, 32768));
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --launch \"" + work.wstring() + L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION parent{};
  assert(CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
      CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &parent));
  if (!AssignProcessToJobObject(job, parent.hProcess)) {
    TerminateProcess(parent.hProcess, 1);
    CloseHandle(parent.hThread); CloseHandle(parent.hProcess); CloseHandle(job);
    std::cerr << "Test host does not allow nested job assignment.\n";
    return 1;
  }
  ResumeThread(parent.hThread);
  CloseHandle(parent.hThread);
  const bool ready = WaitFile(work / L"ready");
  TerminateJobObject(job, 0);
  WaitForSingleObject(parent.hProcess, 10000);
  CloseHandle(parent.hProcess); CloseHandle(job);
  if (!ready || !WaitFile(work / L"survived")) {
    if (fs::exists(work / L"launch-error.txt")) {
      std::ifstream details(work / L"launch-error.txt");
      std::cerr << details.rdbuf() << '\n';
    }
    std::cerr << "Updater did not outlive its parent job. Diagnostics retained in the test temp directory.\n";
    return 1;
  }
  Sleep(300);
  std::error_code ignored;
  fs::remove_all(work, ignored);
  std::cout << "PASS: native updater survives parent job termination; Unicode/space path quoting\n";
}
