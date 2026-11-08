#ifndef RUNNER_UPDATE_LAUNCHER_H_
#define RUNNER_UPDATE_LAUNCHER_H_

#include <windows.h>
#include <string>

// Explicitly escapes Helper's kill-on-close job; ordinary descendants do not.
bool LaunchUpdateHelper(const std::wstring& work_directory,
                        const std::wstring& log_path, std::string* error,
                        HANDLE* process_handle = nullptr);

#endif  // RUNNER_UPDATE_LAUNCHER_H_
