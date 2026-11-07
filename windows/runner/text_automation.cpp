#include "text_automation.h"

#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <array>
#include <cwchar>
#include <limits>
#include <utility>

namespace {
constexpr UINT_PTR kTimer = 0x48415401;
constexpr UINT_PTR kGuardTimer = 0x48415403;
constexpr ULONG_PTR kOurInput = 0x48415402;
bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
bool Modifier(UINT key) {
  return key == VK_SHIFT || key == VK_LSHIFT || key == VK_RSHIFT ||
      key == VK_CONTROL || key == VK_LCONTROL || key == VK_RCONTROL ||
      key == VK_MENU || key == VK_LMENU || key == VK_RMENU ||
      key == VK_LWIN || key == VK_RWIN;
}
bool ModifiersHeld() {
  return Down(VK_CONTROL) || Down(VK_SHIFT) || Down(VK_MENU) ||
      Down(VK_LWIN) || Down(VK_RWIN) || Down(VK_LBUTTON) || Down(VK_RBUTTON);
}
bool UsableFocus(const GUITHREADINFO& info) {
  constexpr DWORD kUnsafe = GUI_INMENUMODE | GUI_SYSTEMMENUMODE | GUI_POPUPMENUMODE | GUI_INMOVESIZE;
  return info.hwndFocus && IsWindowVisible(info.hwndFocus) &&
      IsWindowEnabled(info.hwndFocus) && (info.flags & kUnsafe) == 0;
}
bool InputDesktopActive() {
  // Never inject into a locked session / UAC secure desktop, or resume silently
  // after returning from one. GetThreadDesktop's handle must NOT be closed.
  HDESK active = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!active) return false;
  wchar_t active_name[256]{};
  wchar_t thread_name[256]{};
  DWORD bytes = 0;
  const bool same = GetUserObjectInformationW(active, UOI_NAME, active_name,
      static_cast<DWORD>(sizeof(active_name)), &bytes) &&
      GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
          thread_name, static_cast<DWORD>(sizeof(thread_name)), &bytes) &&
      std::wcscmp(active_name, thread_name) == 0;
  CloseDesktop(active);
  return same;
}
int64_t Integer(const flutter::EncodableMap& map, const char* name, int64_t fallback) {
  const auto found = map.find(flutter::EncodableValue(name));
  if (found == map.end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  return fallback;
}
size_t UnitLength(const std::wstring& text, size_t offset) {
  const wchar_t c = text[offset];
  if (offset + 1 < text.size()) {
    if (c == L'\r' && text[offset + 1] == L'\n') return 2;
    if (c >= 0xd800 && c <= 0xdbff &&
        text[offset + 1] >= 0xdc00 && text[offset + 1] <= 0xdfff) return 2;
  }
  return 1;
}
}  // namespace

TextAutomation* TextAutomation::observer_ = nullptr;

TextAutomation::TextAutomation(HWND window, flutter::BinaryMessenger* messenger,
    std::function<bool(UINT)> is_control_hotkey,
    std::function<bool()> has_emergency_stop,
    std::function<bool()> show_countdown)
    : window_(window), is_control_hotkey_(std::move(is_control_hotkey)),
      has_emergency_stop_(std::move(has_emergency_stop)),
      show_countdown_(std::move(show_countdown)) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "helper/automation", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    std::string error;
    if (method == "getState") {
      result->Success(Snapshot());
      return;
    } else if (method == "start") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!args || !Start(*args, &error)) {
        result->Error("automation_error", error.empty() ? "Не указан текст для ввода." : error);
        return;
      }
    } else if (method == "pause") {
      Pause();
    } else if (method == "resume") {
      if (!Resume(&error)) {
        result->Error("automation_error", error);
        return;
      }
    } else if (method == "stop") {
      Stop();
    } else if (method == "cancelCountdown") {
      CancelCountdown();
    } else if (method == "setSpeed") {
      const auto* speed = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
      if (!speed || *speed < 30 || *speed > 500) {
        result->Error("automation_error", "Скорость должна быть от 30 до 500 символов в минуту.");
        return;
      }
      speed_ = static_cast<UINT>(*speed);
      if (phase_ == Phase::typing) Arm(Interval());
      Notify();
    } else {
      result->NotImplemented();
      return;
    }
    result->Success(Snapshot());
  });
}

TextAutomation::~TextAutomation() {
  Stop(false);
  channel_->SetMethodCallHandler(nullptr);
}

TextAutomation::Value TextAutomation::Snapshot() const {
  const char* phase = "idle";
  switch (phase_) {
    case Phase::idle: break;
    case Phase::countdown: phase = "countdown"; break;
    case Phase::typing: phase = "typing"; break;
    case Phase::paused: phase = "paused"; break;
    case Phase::stopped: phase = "stopped"; break;
    case Phase::completed: phase = "completed"; break;
    case Phase::error: phase = "error"; break;
  }
  return Value(Map{
      {Value("phase"), Value(phase)}, {Value("blockId"), Value(block_id_)},
      {Value("revision"), Value(static_cast<int64_t>(revision_))},
      {Value("stopToken"), Value(static_cast<int64_t>(stop_generation_))},
      {Value("position"), Value(static_cast<int64_t>(position_))},
      {Value("total"), Value(static_cast<int64_t>(total_))},
      {Value("countdown"), Value(countdown_)},
      {Value("speed"), Value(static_cast<int32_t>(speed_))},
      {Value("message"), Value(message_)}});
}

void TextAutomation::Notify() {
  ++revision_;
  channel_->InvokeMethod("state", std::make_unique<Value>(Snapshot()));
}

bool TextAutomation::Start(const Map& args, std::string* error) {
  const int64_t stop_token = Integer(args, "stopToken", -1);
  if (stop_token < 0 || static_cast<uint64_t>(stop_token) != stop_generation_) {
    *error = "Запуск отменён командой остановки. При необходимости запустите ввод заново.";
    return false;
  }
  if (phase_ == Phase::typing || phase_ == Phase::countdown || phase_ == Phase::paused) {
    *error = "Сначала остановите текущий ввод или продолжите его с сохранённой позиции.";
    return false;
  }
  if (!has_emergency_stop_()) {
    *error = "Сначала назначьте доступную глобальную горячую клавишу остановки в настройках.";
    return false;
  }
  const auto found = args.find(Value("text"));
  const auto* text = found == args.end() ? nullptr : std::get_if<std::string>(&found->second);
  const int64_t speed = Integer(args, "speed", 180);
  const int64_t block = Integer(args, "blockId", 0);
  if (!text || text->empty() || text->find('\0') != std::string::npos || block <= 0 ||
      text->size() > static_cast<size_t>((std::numeric_limits<int>::max)()) ||
      speed < 30 || speed > 500) {
    *error = "Нужен непустой Unicode-текст без нулевых символов и скорость 30–500 символов/мин.";
    return false;
  }
  const int bytes = static_cast<int>(text->size());
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(), bytes, nullptr, 0);
  if (length <= 0) {
    *error = "Не удалось прочитать Unicode-текст для ввода.";
    return false;
  }
  std::wstring decoded(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(), bytes,
                         decoded.data(), length) != length) {
    *error = "Не удалось преобразовать Unicode-текст для ввода.";
    return false;
  }
  if (std::any_of(decoded.begin(), decoded.end(), [](wchar_t c) {
      return (c < 0x20 && c != L'\t' && c != L'\r' && c != L'\n') || c == 0x7f;
    })) {
    *error = "Текст содержит управляющие символы, которые могут выполнять команды. Допустимы обычный текст, табуляция и переводы строк.";
    return false;
  }
  CloseTarget();
  text_ = std::move(decoded);
  offset_ = position_ = total_ = 0;
  for (size_t i = 0; i < text_.size(); i += UnitLength(text_, i)) ++total_;
  block_id_ = block;
  speed_ = static_cast<UINT>(speed);
  BeginCountdown(false);
  return true;
}

void TextAutomation::RequestStart() {
  if (phase_ == Phase::typing || phase_ == Phase::countdown || phase_ == Phase::paused) return;
  channel_->InvokeMethod("startRequested", nullptr);
}

bool TextAutomation::Resume(std::string* error) {
  if (phase_ != Phase::paused) {
    *error = "Продолжение доступно только после паузы.";
    return false;
  }
  if (!has_emergency_stop_()) {
    *error = "Не зарегистрирована глобальная клавиша остановки. Исправьте её в настройках.";
    return false;
  }
  if (offset_ == text_.size()) {
    CloseTarget();
    std::wstring().swap(text_);
    phase_ = Phase::completed;
    message_ = "Ввод завершён.";
    Notify();
    return true;
  }
  BeginCountdown(true);
  return true;
}

void TextAutomation::TogglePause() {
  if (phase_ == Phase::paused) {
    std::string error;
    if (!Resume(&error)) { message_ = error; Notify(); }
  } else {
    Pause();
  }
}

void TextAutomation::BeginCountdown(bool resume) {
  KillTimer(window_, kTimer);
  RemoveObservers();
  resuming_ = resume;
  countdown_ = 5;
  phase_ = Phase::countdown;
  message_ = resume ? "Верните фокус в прежнее поле. Продолжение через 5 секунд."
                    : "Выберите поле другого приложения. Начало через 5 секунд.";
  if (!show_countdown_()) {
    Fail("Не удалось показать окно с отсчётом. Ввод не начат.");
    return;
  }
  deadline_ = GetTickCount64() + 5000;
  if (Arm(100)) Notify();
}

bool TextAutomation::Arm(UINT interval) {
  if (SetTimer(window_, kTimer, interval, nullptr) != 0) return true;
  Fail("Не удалось создать таймер ввода. Код Win32: " + std::to_string(GetLastError()));
  return false;
}

UINT TextAutomation::Interval() const { return (60000u + speed_ / 2u) / speed_; }

void TextAutomation::Pause(const std::string& reason) {
  if (phase_ != Phase::typing && phase_ != Phase::countdown) return;
  KillTimer(window_, kTimer);
  RemoveObservers();
  phase_ = Phase::paused;
  countdown_ = 0;
  message_ = reason;
  Notify();
}

void TextAutomation::CancelCountdown() {
  if (phase_ != Phase::countdown) return;
  if (resuming_) Pause("Отсчёт отменён. Позиция сохранена.");
  else { Stop(); message_ = "Отсчёт отменён. Текст не вводился."; Notify(); }
}

void TextAutomation::Stop(bool notify) {
  ++stop_generation_;
  KillTimer(window_, kTimer);
  RemoveObservers();
  CloseTarget();
  countdown_ = 0;
  phase_ = block_id_ == 0 ? Phase::idle : Phase::stopped;
  std::wstring().swap(text_);
  message_ = "Ввод остановлен. Новый запуск начнётся с начала.";
  if (notify) Notify();
}

void TextAutomation::CloseTarget() {
  if (target_process_) CloseHandle(target_process_);
  target_process_ = nullptr;
  target_window_ = target_focus_ = nullptr;
  target_process_id_ = 0;
}

bool TextAutomation::CaptureTarget() {
  if (!InputDesktopActive()) return false;
  const HWND foreground = GetForegroundWindow();
  DWORD process = 0;
  const DWORD thread = GetWindowThreadProcessId(foreground, &process);
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  if (!foreground || !thread || process == GetCurrentProcessId() ||
      !GetGUIThreadInfo(thread, &info) || !UsableFocus(info)) return false;
  DWORD focus_process = 0;
  GetWindowThreadProcessId(info.hwndFocus, &focus_process);
  if (focus_process != process) return false;
  HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, process);
  if (!handle) return false;
  CloseTarget();
  target_window_ = foreground;
  target_focus_ = info.hwndFocus;
  target_process_id_ = process;
  target_process_ = handle;
  return true;
}

bool TextAutomation::TargetStillFocused() const {
  if (!InputDesktopActive()) return false;
  if (!target_process_ || WaitForSingleObject(target_process_, 0) != WAIT_TIMEOUT ||
      !IsWindow(target_window_) || !IsWindow(target_focus_) ||
      GetForegroundWindow() != target_window_) return false;
  DWORD process = 0;
  const DWORD thread = GetWindowThreadProcessId(target_window_, &process);
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  return thread != 0 && process == target_process_id_ &&
      GetGUIThreadInfo(thread, &info) && UsableFocus(info) && info.hwndFocus == target_focus_;
}

bool TextAutomation::ObserveInput() {
  observer_ = this;
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, GetModuleHandle(nullptr), 0);
  mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, GetModuleHandle(nullptr), 0);
  if (keyboard_hook_ && mouse_hook_) return true;
  RemoveObservers();
  Fail("Не удалось включить наблюдение за ручным вводом. Автоматический ввод не начат.");
  return false;
}

void TextAutomation::RemoveObservers() {
  KillTimer(window_, kGuardTimer);
  if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
  if (mouse_hook_) UnhookWindowsHookEx(mouse_hook_);
  keyboard_hook_ = mouse_hook_ = nullptr;
  if (observer_ == this) observer_ = nullptr;
}

LRESULT CALLBACK TextAutomation::KeyboardHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION && observer_ && observer_->phase_ == Phase::typing &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
    const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    if (key->dwExtraInfo != kOurInput && !Modifier(key->vkCode) &&
        !observer_->is_control_hotkey_(key->vkCode)) {
      observer_->Pause("Обнаружен ручной ввод. Автоматический ввод приостановлен.");
    }
  }
  // Observation only: never swallow, remap or block any user's input.
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

LRESULT CALLBACK TextAutomation::MouseHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION && observer_ && observer_->phase_ == Phase::typing &&
      (wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
       wparam == WM_MBUTTONDOWN || wparam == WM_XBUTTONDOWN ||
       wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL)) {
    const auto* mouse = reinterpret_cast<MSLLHOOKSTRUCT*>(lparam);
    if (mouse->dwExtraInfo != kOurInput) {
      observer_->Pause("Обнаружено действие мышью. Автоматический ввод приостановлен.");
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void TextAutomation::Tick() {
  if (phase_ == Phase::countdown) {
    const ULONGLONG now = GetTickCount64();
    if (now < deadline_) {
      const int seconds = static_cast<int>((deadline_ - now + 999) / 1000);
      if (seconds != countdown_) { countdown_ = seconds; Notify(); }
      return;
    }
    if ((!target_process_ && !CaptureTarget()) || !TargetStillFocused()) {
      Pause("Поле не выбрано или фокус изменился. Верните фокус в нужное поле и продолжите.");
      return;
    }
    if (!ObserveInput()) return;
    phase_ = Phase::typing;
    countdown_ = 0;
    message_ = "Ввод текста.";
    if (!Arm(Interval())) return;
    last_guard_ = GetTickCount64();
    if (SetTimer(window_, kGuardTimer, 100, nullptr) == 0) {
      Fail("Не удалось создать таймер контроля фокуса. Ввод не начат.");
      return;
    }
    Notify();
  }
  if (phase_ != Phase::typing) return;
  if (GetTickCount64() - last_guard_ > 500) {
    Pause("Задержка обработки сообщений Windows. Ввод приостановлен для проверки поля.");
    return;
  }
  if (!TargetStillFocused()) {
    Pause("Фокус изменился или целевое окно закрыто. Позиция сохранена.");
    return;
  }
  // Never release real modifiers or send text through an unrelated shortcut.
  if (ModifiersHeld()) {
    const std::string waiting = "Ожидание отпускания клавиш-модификаторов или кнопки мыши.";
    if (message_ != waiting) { message_ = waiting; Notify(); }
    return;
  }
  message_ = "Ввод текста.";
  SendNext();
}

void TextAutomation::SendNext() {
  if (offset_ >= text_.size()) return;
  const size_t length = UnitLength(text_, offset_);
  const bool newline = text_[offset_] == L'\r' || text_[offset_] == L'\n';
  std::array<INPUT, 4> inputs{};
  const UINT units = newline ? 1u : static_cast<UINT>(length);
  const UINT count = units * 2u;
  for (UINT i = 0; i < units; ++i) {
    auto& down = inputs[static_cast<size_t>(i) * 2u];
    down.type = INPUT_KEYBOARD;
    down.ki.dwExtraInfo = kOurInput;
    if (newline) down.ki.wVk = VK_RETURN;
    else { down.ki.wScan = static_cast<WORD>(text_[offset_ + i]); down.ki.dwFlags = KEYEVENTF_UNICODE; }
    auto& up = inputs[static_cast<size_t>(i) * 2u + 1u];
    up = down;
    up.ki.dwFlags |= KEYEVENTF_KEYUP;
  }
  const UINT sent = SendInput(count, inputs.data(), static_cast<int>(sizeof(INPUT)));
  if (sent != count) {
    // Best-effort release ONLY our own keys; never touch the physical modifiers.
    std::array<INPUT, 2> releases{};
    for (UINT i = 0; i < units; ++i) releases[i] = inputs[static_cast<size_t>(i) * 2u + 1u];
    if (sent != 0) SendInput(units, releases.data(), static_cast<int>(sizeof(INPUT)));
    Fail(sent == 0
        ? "Windows отклонила ввод. Проверьте права целевого приложения (UIPI); обход ограничений не выполняется."
        : "Ввод выполнен частично. Проверьте поле вручную: автоматическое продолжение отключено, позиция последнего подтверждённого символа сохранена.");
    return;
  }
  offset_ += length;
  ++position_;
  if (phase_ != Phase::typing) { Notify(); return; }
  if (offset_ == text_.size()) {
    KillTimer(window_, kTimer);
    RemoveObservers();
    CloseTarget();
    phase_ = Phase::completed;
    message_ = "Ввод завершён.";
    std::wstring().swap(text_);
  }
  Notify();
}

void TextAutomation::Fail(const std::string& message) {
  KillTimer(window_, kTimer);
  RemoveObservers();
  CloseTarget();
  std::wstring().swap(text_);
  phase_ = Phase::error;
  countdown_ = 0;
  message_ = message;
  Notify();
}

bool TextAutomation::HandleMessage(UINT message, WPARAM wparam) {
  if (message == WM_QUERYENDSESSION) {
    Pause("Windows завершает сеанс. Ввод приостановлен; позиция сохранена.");
    return false;
  }
  if (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) {
    Pause("Переход Windows в спящий режим. Позиция сохранена; продолжение только вручную.");
    return false;
  }
  if (message == WM_TIMER && wparam == kGuardTimer) {
    if (phase_ == Phase::typing) {
      const ULONGLONG now = GetTickCount64();
      if (now - last_guard_ > 500) {
        Pause("Задержка обработки сообщений Windows. Ввод приостановлен для проверки поля.");
      } else if (!TargetStillFocused()) {
        Pause("Фокус изменился или целевое окно закрыто. Позиция сохранена.");
      }
      last_guard_ = now;
    }
    return true;
  }
  if (message != WM_TIMER || wparam != kTimer) return false;
  Tick();
  return true;
}
