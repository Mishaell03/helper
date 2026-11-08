#include "background_manager.h"
#include "capture_exclusion.h"
#include "window_composition.h"
#include "capture_diagnostics.h"
#include "update_launcher.h"
#include "utils.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <shlobj.h>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {
constexpr wchar_t kSettingsPath[] = L"Software\\Helper\\Hotkeys";
constexpr wchar_t kSettingsValue[] = L"BindingsV2";
constexpr std::array<const char*, 5> kActionNames = {"toggle", "exit", "start", "pause", "stop"};
constexpr std::array<const char*, 5> kActionLabels = {
    "Показать / скрыть", "Выход", "Начать ввод", "Пауза / продолжение", "Остановить ввод"};
constexpr wchar_t kWindowPath[] = L"Software\\Helper\\Window";
constexpr wchar_t kRunPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Helper.Background";
constexpr int kMinWidth = 360;
constexpr int kMinHeight = 300;
constexpr int kMaxWidth = 1600;
constexpr int kMaxHeight = 1200;
double WindowScale(HWND window) {
  const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  return FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
}
std::string WinError(const char* operation, DWORD error) {
  return std::string(operation) + " (Win32 " + std::to_string(error) + ")";
}
int64_t MapInteger(const flutter::EncodableMap& map, const char* name) {
  const auto found = map.find(flutter::EncodableValue(name));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  return 0;
}
const std::string* MapString(const flutter::EncodableMap& map, const char* name) {
  const auto found = map.find(flutter::EncodableValue(name));
  return found == map.end() ? nullptr : std::get_if<std::string>(&found->second);
}
}  // namespace

BackgroundManager::BackgroundManager(HWND window,
                                     flutter::BinaryMessenger* messenger,
                                     bool start_hidden)
    : window_(window), visibility_(start_hidden), start_hidden_(start_hidden) {
  ApplyStyles();
  TraceCapture("created", window_, hidden_, parking_.parked());
  std::array<Shortcut, kActionCount> shortcuts = {{{MOD_CONTROL | MOD_SHIFT, VK_F12},
      {MOD_CONTROL | MOD_SHIFT, VK_F4}, {MOD_CONTROL | MOD_SHIFT, VK_F6},
      {MOD_CONTROL | MOD_SHIFT, VK_F7}, {MOD_CONTROL | MOD_SHIFT, VK_F8}}};
  DWORD data[kActionCount * 2]{};
  DWORD size = sizeof(data);
  const LSTATUS read = RegGetValueW(HKEY_CURRENT_USER, kSettingsPath,
      kSettingsValue, RRF_RT_REG_BINARY, nullptr, data, &size);
  auto saved = shortcuts;
  bool loaded = false;
  if (read == ERROR_SUCCESS && size == sizeof(data)) {
    for (size_t i = 0; i < saved.size(); ++i) saved[i] = {data[i * 2], data[i * 2 + 1]};
    loaded = ValidAll(saved);
  }
  if (loaded) {
    shortcuts = saved;
  } else {
    // Preserve the existing user's two shortcuts; never silently overwrite them
    // when introducing the three automation actions.
    DWORD legacy[4]{};
    DWORD bytes = sizeof(legacy);
    const LSTATUS old = RegGetValueW(HKEY_CURRENT_USER, kSettingsPath, L"BindingsV1",
        RRF_RT_REG_BINARY, nullptr, legacy, &bytes);
    const bool legacy_valid = old == ERROR_SUCCESS && bytes == sizeof(legacy) &&
        Valid({legacy[0], legacy[1]}) && Valid({legacy[2], legacy[3]}) &&
        !(Shortcut{legacy[0], legacy[1]} == Shortcut{legacy[2], legacy[3]});
    if (legacy_valid) {
      shortcuts[0] = {legacy[0], legacy[1]};
      shortcuts[1] = {legacy[2], legacy[3]};
    }
    if ((read != ERROR_FILE_NOT_FOUND && read != ERROR_PATH_NOT_FOUND) ||
        (old != ERROR_SUCCESS && old != ERROR_FILE_NOT_FOUND && old != ERROR_PATH_NOT_FOUND) ||
        (old == ERROR_SUCCESS && !legacy_valid)) {
      startup_error_ += "Не удалось прочитать все сочетания клавиш. Проверьте настройки. ";
    }
  }
  // At startup, retain each available action independently: a conflict on the
  // visibility shortcut must not disable an otherwise available exit shortcut.
  // Reconfiguration below remains transactional and preserves the old pair.
  for (size_t i = 0; i < bindings_.size(); ++i) {
    bindings_[i].shortcut = shortcuts[i];
    bool duplicate = false;
    for (size_t j = 0; j < i; ++j) if (shortcuts[i] == shortcuts[j]) duplicate = true;
    if (duplicate) {
      startup_error_ += std::string("Сочетание «") + kActionLabels[i] +
          "» совпадает с прежним назначением. Выберите другое сочетание. ";
      continue;
    }
    const int id = static_cast<int>(i) + 1;
    if (RegisterHotKey(window_, id, shortcuts[i].modifiers | MOD_NOREPEAT,
                       shortcuts[i].key)) {
      bindings_[i].id = id;
    } else {
      const DWORD error = GetLastError();
      const std::string label = std::string("Сочетание «") + kActionLabels[i] +
          "» занято или зарезервировано Windows. Выберите другое";
      startup_error_ += WinError(label.c_str(), error) + ". ";
    }
  }
  LoadAutostart();
  automation_ = std::make_unique<TextAutomation>(window_, messenger,
      [this](UINT key, UINT modifiers) { return DispatchControlHotkey(key, modifiers); },
      [this]() { return bindings_[4].id != 0; },
      [this]() { return ShowCountdownInactive(); },
      [this](UINT win_key, bool replay) {
        HideForTaskView();
        if (replay && task_view_guard_) task_view_guard_->ReplaySuppressedChord(win_key);
      });

  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "helper/background", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getSettings") {
      result->Success(State());
    } else if (method == "heartbeat") {
      if (watchdog_) watchdog_->DartPulse();
      result->Success();
    } else if (method == "blockStage") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (args && watchdog_) {
        const int64_t stage = MapInteger(*args, "stage");
        if (stage >= 1 && stage <= 5) {
          watchdog_->SetStage(static_cast<int>(stage), MapInteger(*args, "blockId"),
                              MapInteger(*args, "length"));
        }
      }
      result->Success();
    } else if (method == "getAppVersion") {
      result->Success(Value(FLUTTER_VERSION));
    } else if (method == "launchUpdate") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* work_path = args ? MapString(*args, "workDir") : nullptr;
      const auto* log_path = args ? MapString(*args, "logPath") : nullptr;
      std::string error;
      if (!work_path || !log_path) {
        result->Error("update_error", "Не указан каталог обновления или журнал.");
      } else {
        // Stop is native and authoritative, independent of stale Dart snapshots.
        automation_->Stop();
        if (update_process_) {
          if (WaitForSingleObject(update_process_, 0) == WAIT_TIMEOUT) TerminateProcess(update_process_, ERROR_CANCELLED);
          CloseHandle(update_process_);
          update_process_ = nullptr;
        }
        if (LaunchUpdateHelper(Utf16FromUtf8(*work_path), Utf16FromUtf8(*log_path), &error, &update_process_)) result->Success();
        else result->Error("update_error", error);
      }
    } else if (method == "cancelUpdate") {
      if (update_process_) {
        if (WaitForSingleObject(update_process_, 0) == WAIT_TIMEOUT) TerminateProcess(update_process_, ERROR_CANCELLED);
        CloseHandle(update_process_);
        update_process_ = nullptr;
      }
      result->Success();
    } else if (method == "getStorageDirectory") {
      PWSTR directory = nullptr;
      const HRESULT status = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0,
                                                   nullptr, &directory);
      if (FAILED(status)) {
        result->Error("storage_error", "Не удалось определить каталог локальных данных пользователя.");
      } else {
        const std::wstring path = std::wstring(directory) + L"\\Helper";
        const std::string utf8 = Utf8FromUtf16(path.c_str());
        if (utf8.empty()) {
          result->Error("storage_error", "Не удалось прочитать путь к локальным данным.");
        } else {
          result->Success(Value(utf8));
        }
      }
      if (directory) CoTaskMemFree(directory);
    } else if (method == "saveSettings") {
      const auto* map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      std::array<Shortcut, kActionCount> shortcuts{};
      for (size_t i = 0; i < shortcuts.size(); ++i) shortcuts[i] = bindings_[i].shortcut;
      if (!map || map->count(Value("toggle")) == 0 ||
          map->count(Value("exit")) == 0 ||
          !ReadShortcut(map->at(Value("toggle")), &shortcuts[0]) ||
          !ReadShortcut(map->at(Value("exit")), &shortcuts[1])) {
        result->Error("invalid_hotkey", "Выберите Ctrl, Alt, Shift или Win и поддерживаемую клавишу.");
        return;
      }
      for (size_t i = 2; i < shortcuts.size(); ++i) {
        const auto found = map->find(Value(kActionNames[i]));
        if (found != map->end() && !ReadShortcut(found->second, &shortcuts[i])) {
          result->Error("invalid_hotkey", "Некорректное сочетание клавиш автоматического ввода.");
          return;
        }
      }
      std::string error;
      if (!Apply(shortcuts, true, &error)) {
        result->Error("hotkey_error", error);
      } else {
        startup_error_.clear();
        result->Success(State());
      }
    } else if (method == "setRecording") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) {
        result->Error("invalid_argument", "Ожидается значение «включено» или «выключено».");
        return;
      }
      recording_ = *enabled;
      if (recording_) automation_->Pause("Запись горячей клавиши. Ввод приостановлен.");
      result->Success();
    } else if (method == "setAutostart") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      std::string error;
      if (!enabled) {
        result->Error("invalid_argument", "Некорректное значение автозапуска.");
      } else if (!SetAutostart(*enabled, &error)) {
        result->Error("autostart_error", error);
      } else {
        result->Success(State());
      }
    } else if (method == "prepareWindow") {
      if (!PreparePresentation()) {
        result->Error("window_style_error", startup_error_);
        return;
      }
      if (!prepared_) {
        RestoreSize();
        prepared_ = true;
      }
      result->Success(State());
    } else if (method == "pickMarkdownFiles") {
      PickMarkdownFiles(std::move(result));
    } else if (method == "finishStartup") {
      // Make the final presentation decision natively, once. --background
      // never reveals itself; a hotkey pressed during bootstrap takes priority.
      if (visibility_.FinishStartup() && !Show()) {
        result->Error("window_style_error", startup_error_);
      } else {
        result->Success();
      }
    } else if (method == "hide") {
      Hide();
      result->Success();
    } else if (method == "show") {
      if (Show()) result->Success();
      else result->Error("window_style_error", startup_error_);
    } else if (method == "exit") {
      result->Success();
      // Post rather than destroy the messenger during its own callback.
      PostMessage(window_, WM_APP + 43, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
  task_view_guard_ = std::make_unique<TaskViewGuard>([this]() { HideForTaskView(); });
  if (!task_view_guard_->active()) {
    startup_error_ += "Не удалось включить скрытие перед Win+Tab. Проверьте показ панели в обзоре задач. ";
  }
  watchdog_ = std::make_unique<WindowWatchdog>(window_);
}

BackgroundManager::~BackgroundManager() {
  if (update_process_) CloseHandle(update_process_); // Do not kill committed updater.
  watchdog_.reset();
  task_view_guard_.reset();
  automation_.reset();
  if (prepared_) SaveSize();
  channel_->SetMethodCallHandler(nullptr);
  for (const auto& binding : bindings_) {
    if (binding.id) UnregisterHotKey(window_, binding.id);
  }
}

bool BackgroundManager::Valid(const Shortcut& shortcut) const {
  const UINT key = shortcut.key;
  const bool supported = (key >= 'A' && key <= 'Z') ||
      (key >= '0' && key <= '9') || (key >= VK_F1 && key <= VK_F24) ||
      (key >= VK_NUMPAD0 && key <= VK_DIVIDE) ||
      (key >= VK_PRIOR && key <= VK_DOWN) || key == VK_SPACE ||
      key == VK_RETURN || key == VK_TAB || key == VK_BACK ||
      key == VK_INSERT || key == VK_DELETE ||
      (key >= VK_OEM_1 && key <= VK_OEM_3) ||
      (key >= VK_OEM_4 && key <= VK_OEM_8) || key == VK_OEM_102;
  return supported && shortcut.modifiers != 0 &&
      (shortcut.modifiers & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) == 0;
}

bool BackgroundManager::ReadShortcut(const Value& value, Shortcut* shortcut) {
  const auto* map = std::get_if<Map>(&value);
  if (!map) return false;
  const auto modifiers = map->find(Value("modifiers"));
  const auto key = map->find(Value("key"));
  if (modifiers == map->end() || key == map->end()) return false;
  const auto* m = std::get_if<int32_t>(&modifiers->second);
  const auto* k = std::get_if<int32_t>(&key->second);
  if (!m || !k || *m < 0 || *k < 0) return false;
  *shortcut = {static_cast<UINT>(*m), static_cast<UINT>(*k)};
  return Valid(*shortcut);
}

bool BackgroundManager::ValidAll(const std::array<Shortcut, kActionCount>& shortcuts) const {
  for (size_t i = 0; i < shortcuts.size(); ++i) {
    if (!Valid(shortcuts[i])) return false;
    for (size_t j = 0; j < i; ++j) if (shortcuts[i] == shortcuts[j]) return false;
  }
  return true;
}

bool BackgroundManager::DispatchControlHotkey(UINT key, UINT modifiers) const {
  for (const auto& binding : bindings_) {
    if (binding.id && binding.shortcut.key == key &&
        binding.shortcut.modifiers == modifiers) {
      // Blocked modifiers never reach RegisterHotKey. Dispatch the same native
      // message ourselves; it is validated by HandleMessage as usual.
      PostMessage(window_, WM_HOTKEY, binding.id, MAKELPARAM(modifiers, key));
      return true;
    }
  }
  return false;
}

bool BackgroundManager::Apply(const std::array<Shortcut, kActionCount>& shortcuts,
                               bool persist, std::string* error) {
  if (!ValidAll(shortcuts)) {
    *error = "Сочетания должны различаться и содержать Ctrl, Alt, Shift или Win и поддерживаемую клавишу.";
    return false;
  }
  // Keep old registrations until BOTH new shortcuts and persistence succeed.
  // Reuse matching registrations, including when the two actions are swapped.
  std::array<Binding, kActionCount> next{};
  std::vector<int> acquired;
  auto rollback = [&]() {
    for (int id : acquired) UnregisterHotKey(window_, id);
  };
  for (size_t i = 0; i < next.size(); ++i) {
    next[i].shortcut = shortcuts[i];
    for (const auto& old : bindings_) {
      if (old.id && old.shortcut == shortcuts[i]) next[i].id = old.id;
    }
    if (next[i].id) continue;
    int id = 1;
    while (std::any_of(bindings_.begin(), bindings_.end(),
                      [id](const Binding& b) { return b.id == id; }) ||
           std::find(acquired.begin(), acquired.end(), id) != acquired.end()) ++id;
    if (!RegisterHotKey(window_, id, shortcuts[i].modifiers | MOD_NOREPEAT,
                        shortcuts[i].key)) {
      const DWORD code = GetLastError();
      const std::string operation = std::string("Сочетание «") + kActionLabels[i] +
          "» недоступно: занято или зарезервировано Windows. Выберите другое";
      *error = WinError(operation.c_str(), code);
      rollback();
      return false;
    }
    acquired.push_back(id);
    next[i].id = id;
  }
  if (persist) {
    HKEY key = nullptr;
    LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsPath, 0, nullptr,
        0, KEY_SET_VALUE, nullptr, &key, nullptr);
    if (status == ERROR_SUCCESS) {
      DWORD data[kActionCount * 2]{};
      for (size_t i = 0; i < shortcuts.size(); ++i) {
        data[i * 2] = shortcuts[i].modifiers;
        data[i * 2 + 1] = shortcuts[i].key;
      }
      status = RegSetValueExW(key, kSettingsValue, 0, REG_BINARY,
          reinterpret_cast<const BYTE*>(data), sizeof(data));
      RegCloseKey(key);
    }
    if (status != ERROR_SUCCESS) {
      *error = WinError("Не удалось сохранить сочетания клавиш", status);
      rollback();
      return false;
    }
  }
  for (const auto& old : bindings_) {
    if (old.id && std::none_of(next.begin(), next.end(), [&old](const Binding& b) { return b.id == old.id; }))
      UnregisterHotKey(window_, old.id);
  }
  bindings_ = next;
  return true;
}

BackgroundManager::Value BackgroundManager::State() const {
  auto encode = [](const Shortcut& shortcut) {
    return Value(Map{{Value("modifiers"), Value(static_cast<int32_t>(shortcut.modifiers))},
                     {Value("key"), Value(static_cast<int32_t>(shortcut.key))}});
  };
  Map state{{Value("active"), Value(std::all_of(bindings_.begin(), bindings_.end(),
                     [](const Binding& b) { return b.id != 0; }))},
                   {Value("autostart"), Value(autostart_)},
                   {Value("startHidden"), Value(start_hidden_)},
                   {Value("warning"), Value(startup_error_)}};
  for (size_t i = 0; i < bindings_.size(); ++i) state[Value(kActionNames[i])] = encode(bindings_[i].shortcut);
  return Value(state);
}

bool BackgroundManager::ApplyStyles() {
  const LONG_PTR styles = GetWindowLongPtr(window_, GWL_EXSTYLE);
  const LONG_PTR desired = (styles | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
  bool frame_changed = false;
  if (styles != desired) {
    SetLastError(ERROR_SUCCESS);
    if (SetWindowLongPtr(window_, GWL_EXSTYLE, desired) == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      startup_error_ = WinError("Не удалось настроить фоновое окно", GetLastError());
      return false;
    }
    frame_changed = true;
  }
  // Keep standard Windows sizing, but leave non-client painting to the
  // existing frameless window_manager implementation.
  const LONG_PTR style = GetWindowLongPtr(window_, GWL_STYLE);
  if ((style & WS_THICKFRAME) == 0) {
    SetLastError(ERROR_SUCCESS);
    if (SetWindowLongPtr(window_, GWL_STYLE, style | WS_THICKFRAME) == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      startup_error_ = WinError("Не удалось включить изменение размера окна", GetLastError());
      return false;
    }
    frame_changed = true;
  }
  // Rebuilding an unchanged frame on every reveal invalidates DWM surfaces.
  // Only change z-order/frame when something actually changed.
  if (!frame_changed && (styles & WS_EX_TOPMOST) != 0) return true;
  const UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
      (frame_changed ? static_cast<UINT>(SWP_FRAMECHANGED) : 0u);
  if (!SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0, flags)) {
    startup_error_ = WinError("Не удалось обновить параметры окна", GetLastError());
    return false;
  }
  return true;
}

bool BackgroundManager::PreparePresentation() {
  if (!ApplyStyles()) return false;
  const bool composition_changed = !composition_ready_;
  if (composition_changed) {
    if (!ConfigureTransparentComposition(window_, &startup_error_)) {
      TraceCaptureFailure(startup_error_);
      return false;
    }
    composition_ready_ = true;
  }
  // Check before showing; never reveal a window after a failed protection call.
  if (!ExcludeFromCapture(window_, composition_changed)) {
    composition_ready_ = false;
    startup_error_ = "Не удалось исключить окно из захвата. Показ отменён.";
    TraceCaptureFailure(startup_error_);
    return false;
  }
  return true;
}

void BackgroundManager::HideForTaskView() {
  TraceCapture("task_view.hide", window_, hidden_, parking_.parked());
  automation_->Pause("Открыт обзор задач Windows. Ввод приостановлен, позиция сохранена.");
  // Keep the keyboard hook short: no registry writes before the shell snapshot.
  Hide(false);
}

void BackgroundManager::Hide(bool persist_size) {
  if (watchdog_) watchdog_->SetVisible(false);
  TraceCapture("hide.begin", window_, hidden_, parking_.parked());
  visibility_.Hide();
  if (hidden_) return;
  if (prepared_ && persist_size) SaveSize();
  hidden_ = true;
  if (UseStableCaptureSurface() && parking_.Park(window_)) {
    TraceCapture("hide.parked", window_, hidden_, parking_.parked());
    RestoreExternalFocus();
  } else {
    TraceCapture("hide.native", window_, hidden_, parking_.parked());
    ShowWindow(window_, SW_HIDE);
  }
  if (HWND dialog = ImportDialogWindow()) ShowWindow(dialog, SW_HIDE);
  FlushHiddenWindowComposition();
  TraceCapture("hide.end", window_, hidden_, parking_.parked());
}

void BackgroundManager::RestoreExternalFocus() {
  DWORD process = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &process);
  if (process != GetCurrentProcessId()) return;
  if (IsWindow(previous_foreground_) && IsWindowVisible(previous_foreground_) &&
      !IsIconic(previous_foreground_) && IsWindowEnabled(previous_foreground_) &&
      SetForegroundWindow(previous_foreground_)) return;
  for (HWND next = GetWindow(window_, GW_HWNDNEXT); next; next = GetWindow(next, GW_HWNDNEXT)) {
    DWORD owner = 0;
    GetWindowThreadProcessId(next, &owner);
    if (owner != GetCurrentProcessId() && IsWindowVisible(next) &&
        !IsIconic(next) && IsWindowEnabled(next) &&
        (GetWindowLongPtr(next, GWL_EXSTYLE) & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) == 0 &&
        SetForegroundWindow(next)) return;
  }
  SetForegroundWindow(GetShellWindow());
}

bool BackgroundManager::Show() {
  return ShowWindowSafely(true);
}

bool BackgroundManager::ShowWindowSafely(bool activate) {
  TraceCapture("show.begin", window_, hidden_, parking_.parked());
  if (!PreparePresentation()) {
    TraceCapture("show.prepare_failed", window_, hidden_, parking_.parked(), GetLastError());
    std::cerr << "Window presentation failed: " << startup_error_ << std::endl;
    return false;
  }
  if (watchdog_ && !watchdog_->AllowReveal()) {
    startup_error_ = "Интерфейс ещё не отвечает. Панель остаётся скрытой; попробуйте показать её позже.";
    return false;
  }
  visibility_.Reveal();
  if (!parking_.Restore(window_)) {
    TraceCapture("show.restore_failed", window_, hidden_, parking_.parked(), GetLastError());
    visibility_.Hide();
    return false;
  }
  // SW_HIDE preserves the rectangle. SetWindowPlacement is unnecessary here
  // and can itself reveal/activate the window before the intended ShowWindow.
  if (!IsWindowVisible(window_) || IsIconic(window_)) {
    const int command = activate ? (IsIconic(window_) ? SW_RESTORE : SW_SHOW)
                                 : SW_SHOWNOACTIVATE;
    ShowWindow(window_, command);
  }
  hidden_ = !IsWindowVisible(window_) || IsIconic(window_);
  if (hidden_) return false;
  if (watchdog_) watchdog_->SetVisible(true);
  PostMessage(window_, kRefreshHelperFrame, 0, 0);
  RedrawWindow(window_, nullptr, nullptr,
      RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW | RDW_NOERASE);
  if (activate) {
    HWND foreground = GetForegroundWindow();
    DWORD owner = 0;
    GetWindowThreadProcessId(foreground, &owner);
    if (foreground && owner != GetCurrentProcessId()) previous_foreground_ = foreground;
    SetForegroundWindow(window_);
  }
  if (HWND dialog = ImportDialogWindow()) {
    if (!ExcludeFromCapture(dialog)) return false;
    ShowWindow(dialog, activate ? SW_SHOW : SW_SHOWNA);
    if (activate) SetForegroundWindow(dialog);
  }
  TraceCapture("show.end", window_, hidden_, parking_.parked());
  return true;
}

HWND BackgroundManager::ImportDialogWindow() const {
  if (!import_dialog_) return nullptr;
  Microsoft::WRL::ComPtr<IOleWindow> ole_window;
  HWND window = nullptr;
  if (SUCCEEDED(import_dialog_.As(&ole_window))) ole_window->GetWindow(&window);
  return window;
}

bool BackgroundManager::ShowCountdownInactive() {
  // Same composition/protection path, without taking focus from the editor.
  return !import_dialog_ && ShowWindowSafely(false);
}

void BackgroundManager::PickMarkdownFiles(
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (import_dialog_) {
    result->Error("import_error", "Диалог импорта уже открыт.");
    return;
  }
  HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(import_dialog_.GetAddressOf()));
  const COMDLG_FILTERSPEC filters[] = {
      {L"Текстовые файлы (*.md; *.txt)", L"*.md;*.txt"},
      {L"Markdown (*.md)", L"*.md"}, {L"Текст (*.txt)", L"*.txt"}};
  if (SUCCEEDED(status)) status = import_dialog_->SetOptions(
      FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST |
      FOS_ALLOWMULTISELECT | FOS_NOCHANGEDIR);
  if (SUCCEEDED(status)) status = import_dialog_->SetFileTypes(ARRAYSIZE(filters), filters);
  if (SUCCEEDED(status)) status = import_dialog_->SetTitle(L"Импорт текстовых блоков");
  if (SUCCEEDED(status)) status = import_dialog_->SetOkButtonLabel(L"Импортировать");
  if (SUCCEEDED(status)) {
    CaptureDialogScope capture_scope;
    if (watchdog_) watchdog_->SetNativeDialogOpen(true);
    // The Windows dialog pumps messages. HandleMessage defers exit until this
    // call returns so the messenger/result cannot be destroyed mid-callback.
    status = import_dialog_->Show(window_);
    if (watchdog_) watchdog_->SetNativeDialogOpen(false);
  }
  flutter::EncodableList paths;
  if (SUCCEEDED(status)) {
    Microsoft::WRL::ComPtr<IShellItemArray> items;
    status = import_dialog_->GetResults(&items);
    DWORD count = 0;
    if (SUCCEEDED(status)) status = items->GetCount(&count);
    for (DWORD i = 0; SUCCEEDED(status) && i < count; ++i) {
      Microsoft::WRL::ComPtr<IShellItem> item;
      status = items->GetItemAt(i, &item);
      PWSTR filename = nullptr;
      if (SUCCEEDED(status)) status = item->GetDisplayName(SIGDN_FILESYSPATH, &filename);
      if (SUCCEEDED(status)) {
        const int size = WideCharToMultiByte(CP_UTF8, 0, filename, -1,
                                             nullptr, 0, nullptr, nullptr);
        if (size > 0) {
          std::string utf8(static_cast<size_t>(size), '\0');
          WideCharToMultiByte(CP_UTF8, 0, filename, -1, utf8.data(), size, nullptr, nullptr);
          utf8.pop_back();
          paths.emplace_back(utf8);
        } else {
          status = HRESULT_FROM_WIN32(GetLastError());
        }
      }
      if (filename) CoTaskMemFree(filename);
    }
  }
  import_dialog_.Reset();
  if (SUCCEEDED(status) || status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success(Value(paths));
  } else {
    result->Error("import_error", "Не удалось открыть диалог импорта. Код Windows: " +
        std::to_string(static_cast<unsigned long>(status)));
  }
  if (exit_requested_) PostMessage(window_, WM_APP + 43, 0, 0);
}

void BackgroundManager::LoadAutostart() {
  DWORD bytes = 0;
  const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kRunPath, kRunValue,
      RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return;
  if (status != ERROR_SUCCESS) {
    startup_error_ += WinError("Не удалось прочитать настройку автозапуска", status) + ". ";
    return;
  }
  // The Run value IS the persisted preference. Repair an old executable path
  // when the user next launches a moved installation. Never create duplicates.
  autostart_ = true;
  std::string error;
  if (!SetAutostart(true, &error)) startup_error_ += error + ". ";
}

bool BackgroundManager::SetAutostart(bool enabled, std::string* error) {
  std::wstring command;
  if (enabled) {
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                           static_cast<DWORD>(path.size()));
    if (length == 0 || length >= static_cast<DWORD>(path.size())) {
      *error = "Не удалось определить путь к приложению для автозапуска.";
      return false;
    }
    if (GetFileAttributesW(path.data()) == INVALID_FILE_ATTRIBUTES) {
      *error = "Файл приложения перемещён или удалён. Запустите его из нового расположения.";
      return false;
    }
    command = L"\"" + std::wstring(path.data(), length) + L"\" --background";
  }
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunPath, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status == ERROR_SUCCESS) {
    if (enabled) {
      status = RegSetValueExW(key, kRunValue, 0, REG_SZ,
          reinterpret_cast<const BYTE*>(command.c_str()),
          static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    } else {
      status = RegDeleteValueW(key, kRunValue);
      if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
    }
    RegCloseKey(key);
  }
  if (status != ERROR_SUCCESS) {
    *error = WinError(enabled ? "Не удалось включить автозапуск"
                             : "Не удалось отключить автозапуск", status);
    return false;
  }
  autostart_ = enabled;
  return true;
}

void BackgroundManager::RestoreSize() {
  DWORD dimensions[2] = {368, 440};
  DWORD bytes = sizeof(dimensions);
  DWORD saved[2]{};
  const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kWindowPath, L"SizeV1",
      RRF_RT_REG_BINARY, nullptr, saved, &bytes);
  if (status == ERROR_SUCCESS && bytes == sizeof(saved)) {
    dimensions[0] = std::clamp(saved[0], static_cast<DWORD>(kMinWidth),
                               static_cast<DWORD>(kMaxWidth));
    dimensions[1] = std::clamp(saved[1], static_cast<DWORD>(kMinHeight),
                               static_cast<DWORD>(kMaxHeight));
  } else if (status != ERROR_FILE_NOT_FOUND && status != ERROR_PATH_NOT_FOUND) {
    startup_error_ += "Не удалось прочитать размер окна. Используется размер по умолчанию. ";
  }
  const double scale = WindowScale(window_);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor)) {
    startup_error_ += "Не удалось определить рабочую область экрана. ";
    return;
  }
  const RECT work = monitor.rcWork;
  const int width = std::min(static_cast<int>(dimensions[0] * scale),
                            static_cast<int>(work.right - work.left));
  const int height = std::min(static_cast<int>(dimensions[1] * scale),
                             static_cast<int>(work.bottom - work.top));
  if (!SetWindowPos(window_, nullptr,
      work.left + (work.right - work.left - width) / 2,
      work.top + (work.bottom - work.top - height) / 2, width, height,
      SWP_NOZORDER | SWP_NOACTIVATE)) {
    startup_error_ += WinError("Не удалось восстановить размер окна", GetLastError()) + ". ";
  }
}

void BackgroundManager::SaveSize() {
  if (parking_.parked()) return;  // Hide already saved the visible/DPI-correct size.
  WINDOWPLACEMENT current{};
  current.length = sizeof(current);
  if (!GetWindowPlacement(window_, &current)) return;
  const RECT normal = current.rcNormalPosition;
  const double scale = WindowScale(window_);
  const DWORD dimensions[] = {
      static_cast<DWORD>(std::clamp(static_cast<int>((normal.right - normal.left) / scale),
                                    kMinWidth, kMaxWidth)),
      static_cast<DWORD>(std::clamp(static_cast<int>((normal.bottom - normal.top) / scale),
                                    kMinHeight, kMaxHeight))};
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kWindowPath, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status == ERROR_SUCCESS) {
    status = RegSetValueExW(key, L"SizeV1", 0, REG_BINARY,
        reinterpret_cast<const BYTE*>(dimensions), sizeof(dimensions));
    RegCloseKey(key);
  }
  if (status != ERROR_SUCCESS) {
    const std::string error = WinError("Не удалось сохранить размер окна", status);
    std::cerr << error << std::endl;
    if (channel_) channel_->InvokeMethod("warning", std::make_unique<Value>(error));
  }
}

bool BackgroundManager::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_TIMER && wparam == kWatchdogNativeTimer) {
    if (watchdog_) watchdog_->NativePulse();
    return true;
  }
  if (message == kWatchdogTriggered) {
    automation_->Pause("Интерфейс не отвечал. Панель скрыта, ввод приостановлен.");
    Hide(false);
    composition_ready_ = false; // Revalidate protected composition before recovery.
    if (watchdog_) watchdog_->AcknowledgeHidden();
    return true;
  }
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE && lparam) {
    HWND previous = reinterpret_cast<HWND>(lparam);
    DWORD owner = 0;
    GetWindowThreadProcessId(previous, &owner);
    if (owner && owner != GetCurrentProcessId()) previous_foreground_ = previous;
  }
  if (message == WM_DISPLAYCHANGE && parking_.parked()) parking_.Repark(window_);
  if (message == WM_SHOWWINDOW) TraceCapture(wparam ? "WM_SHOWWINDOW.show" : "WM_SHOWWINDOW.hide", window_, hidden_, parking_.parked());
  if (message == WM_WINDOWPOSCHANGED) TraceCapture("WM_WINDOWPOSCHANGED", window_, hidden_, parking_.parked());
  if (message == WM_STYLECHANGED && lparam) {
    const auto* change = reinterpret_cast<const STYLESTRUCT*>(lparam);
    const DWORD changed = change->styleOld ^ change->styleNew;
    // WS_VISIBLE/WS_EX_TOPMOST changes are normal show/hide operations, not
    // reasons to rebuild composition. Only actual rendering/frame changes count.
    constexpr DWORD kNoRedirectionBitmap = 0x00200000;
    if ((wparam == static_cast<WPARAM>(GWL_STYLE) &&
         (changed & (WS_CAPTION | WS_THICKFRAME)) != 0) ||
        (wparam == static_cast<WPARAM>(GWL_EXSTYLE) &&
         (changed & (WS_EX_LAYERED | kNoRedirectionBitmap)) != 0)) {
      composition_ready_ = false;
    }
  }
  if (message == WM_DWMCOMPOSITIONCHANGED) {
    TraceCapture("WM_DWMCOMPOSITIONCHANGED", window_, hidden_, parking_.parked());
    composition_ready_ = false;
    if (prepared_ && IsWindowVisible(window_)) {
      if (!PreparePresentation()) Hide();
      else RedrawWindow(window_, nullptr, nullptr,
          RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_NOERASE);
    }
  }
  if (message == WM_WINDOWPOSCHANGING && lparam && !visibility_.may_show()) {
    // Defend against plugin/window-initialization requests showing or focusing
    // an autostarted window before an explicit reveal action.
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    position->flags &= ~static_cast<UINT>(SWP_SHOWWINDOW);
    position->flags |= SWP_NOACTIVATE;
    parking_.ConstrainPosition(position);
  }
  if (automation_ && automation_->HandleMessage(message, wparam)) return true;
  if (message == WM_ENDSESSION && wparam != 0) automation_->Stop(false);
  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    const double scale = WindowScale(window_);
    info->ptMinTrackSize = {static_cast<LONG>(kMinWidth * scale),
                            static_cast<LONG>(kMinHeight * scale)};
    info->ptMaxTrackSize = {static_cast<LONG>(kMaxWidth * scale),
                            static_cast<LONG>(kMaxHeight * scale)};
    return true;
  }
  if (message == WM_EXITSIZEMOVE && prepared_) {
    SaveSize();
    ExcludeFromCapture(window_);
  }
  if (message == WM_CLOSE) {
    Hide();
    return true;
  }
  if (message == kShowHelper) {
    Show();
    return true;
  }
  if (message == WM_APP + 43) {
    automation_->Stop(false);
    if (import_dialog_) {
      exit_requested_ = true;
      import_dialog_->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
      return true;
    }
    DestroyWindow(window_);
    return true;
  }
  if (message != WM_HOTKEY) return false;
  const UINT modifiers = static_cast<UINT>(LOWORD(lparam)) & 0x0fu;
  const UINT key = static_cast<UINT>(HIWORD(lparam));
  // Ignore stale queued messages after reconfiguration.
  for (size_t i = 0; i < bindings_.size(); ++i) {
    const auto& b = bindings_[i];
    if (!b.id || wparam != static_cast<WPARAM>(b.id) ||
        modifiers != b.shortcut.modifiers || key != b.shortcut.key)
      continue;
    if (recording_ && GetForegroundWindow() == window_) {
      if (i == 4) automation_->Stop();
      channel_->InvokeMethod("recorded", std::make_unique<Value>(Map{
          {Value("modifiers"), Value(static_cast<int32_t>(b.shortcut.modifiers))},
          {Value("key"), Value(static_cast<int32_t>(b.shortcut.key))}}));
    } else if (i == 0) {
      if (!hidden_ && !IsIconic(window_)) Hide(); else Show();
    } else if (i == 1) {
      PostMessage(window_, WM_APP + 43, 0, 0);
    } else if (i == 2) {
      if (!import_dialog_) automation_->RequestStart();
    } else if (i == 3) {
      automation_->TogglePause();
    } else {
      automation_->Stop();
    }
    break;
  }
  return true;
}
