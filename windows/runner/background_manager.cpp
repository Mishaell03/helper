#include "background_manager.h"
#include "capture_exclusion.h"
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
}  // namespace

BackgroundManager::BackgroundManager(HWND window,
                                     flutter::BinaryMessenger* messenger,
                                     bool start_hidden)
    : window_(window), start_hidden_(start_hidden) {
  placement_.length = sizeof(placement_);
  ApplyStyles();
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
      [this]() { return ShowCountdownInactive(); });

  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "helper/background", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getSettings") {
      result->Success(State());
    } else if (method == "getAppVersion") {
      result->Success(Value(FLUTTER_VERSION));
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
      if (!ApplyStyles()) {
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
}

BackgroundManager::~BackgroundManager() {
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
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR previous = SetWindowLongPtr(window_, GWL_EXSTYLE,
      (styles | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
  if (previous == 0 && GetLastError() != ERROR_SUCCESS) {
    startup_error_ = WinError("Не удалось настроить фоновое окно", GetLastError());
    return false;
  }
  // Keep standard Windows sizing, but leave non-client painting to the
  // existing frameless window_manager implementation.
  const LONG_PTR style = GetWindowLongPtr(window_, GWL_STYLE);
  SetLastError(ERROR_SUCCESS);
  if (SetWindowLongPtr(window_, GWL_STYLE, style | WS_THICKFRAME) == 0 &&
      GetLastError() != ERROR_SUCCESS) {
    startup_error_ = WinError("Не удалось включить изменение размера окна", GetLastError());
    return false;
  }
  if (!SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    startup_error_ = WinError("Не удалось обновить параметры окна", GetLastError());
    return false;
  }
  return true;
}

void BackgroundManager::Hide() {
  if (hidden_) return;
  GetWindowPlacement(window_, &placement_);
  if (prepared_) SaveSize();
  hidden_ = true;
  ShowWindow(window_, SW_HIDE);
  if (HWND dialog = ImportDialogWindow()) ShowWindow(dialog, SW_HIDE);
}

bool BackgroundManager::Show() {
  if (!ApplyStyles()) return false;
  ExcludeFromCapture(window_);
  if (hidden_) {
    SetWindowPlacement(window_, &placement_);
    hidden_ = false;
  }
  ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
  if (HWND dialog = ImportDialogWindow()) {
    ExcludeFromCapture(dialog);
    ShowWindow(dialog, SW_SHOW);
    SetForegroundWindow(dialog);
  }
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
  if (import_dialog_ || !ApplyStyles()) return false;
  ExcludeFromCapture(window_);
  // Unlike normal Show(), this must NOT activate Helper or steal the external
  // editor's focus when Start/Resume was requested by a global hotkey.
  ShowWindow(window_, IsIconic(window_) ? SW_SHOWNOACTIVATE : SW_SHOWNA);
  if (!SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW)) return false;
  if (!IsWindowVisible(window_) || IsIconic(window_)) return false;
  hidden_ = false;
  return true;
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
    // The Windows dialog pumps messages. HandleMessage defers exit until this
    // call returns so the messenger/result cannot be destroyed mid-callback.
    status = import_dialog_->Show(window_);
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
      if (IsWindowVisible(window_) && !IsIconic(window_)) Hide(); else Show();
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
