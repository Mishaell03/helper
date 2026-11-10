#include "slot_notification.h"

#include <objidl.h>
#include <gdiplus.h>
#include <flutter_windows.h>
#include <algorithm>
#include <cmath>
#include <cwchar>
#include <cstring>
#include <iostream>
#include <utility>

#include "capture_exclusion.h"

namespace {
constexpr wchar_t kClassName[] = L"Helper.SlotNotification";
constexpr wchar_t kSettingsPath[] = L"Software\\Helper\\Window";
constexpr wchar_t kEnabledValue[] = L"SlotNotificationEnabled";
constexpr wchar_t kPositionValue[] = L"SlotNotificationPositionV1";
constexpr UINT_PTR kHideTimer = 1;

SlotNotificationArea Area(const RECT& r) { return {r.left, r.top, r.right, r.bottom}; }
MONITORINFOEXW MonitorInfo(HMONITOR monitor) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info))) info.rcWork = {};
  return info;
}
HMONITOR PrimaryMonitor() {
  return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}
double MonitorScale(HMONITOR monitor) {
  return (std::max)(1.0, FlutterDesktopGetDpiForMonitor(monitor) / 96.0);
}
bool SupportsExclusion() {
  using VersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto function = reinterpret_cast<VersionFunction>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  return function && function(&version) == 0 &&
      (version.dwMajorVersion > 10 ||
       (version.dwMajorVersion == 10 && version.dwBuildNumber >= 19041));
}
LSTATUS WriteSetting(const wchar_t* name, DWORD type, const void* data, DWORD size) {
  HKEY key = nullptr;
  LSTATUS result = RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsPath, 0, nullptr,
      0, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (result == ERROR_SUCCESS) {
    result = RegSetValueExW(key, name, 0, type, static_cast<const BYTE*>(data), size);
    RegCloseKey(key);
  }
  return result;
}
}  // namespace

SlotNotification::SlotNotification(std::function<void(const std::string&)> warning)
    : on_warning_(std::move(warning)) {
  LoadSettings();
}

SlotNotification::~SlotNotification() {
  Dismiss();
  if (window_) DestroyWindow(window_);
  if (graphics_token_) Gdiplus::GdiplusShutdown(graphics_token_);
  if (window_class_) UnregisterClassW(kClassName, GetModuleHandleW(nullptr));
}

void SlotNotification::Fail(const std::string& message) {
  warning_ = message;
  std::cerr << message << std::endl;
  if (on_warning_) on_warning_(message);
}

void SlotNotification::LoadSettings() {
  DWORD enabled = 1;
  DWORD size = sizeof(enabled);
  LSTATUS result = RegGetValueW(HKEY_CURRENT_USER, kSettingsPath, kEnabledValue,
      RRF_RT_REG_DWORD, nullptr, &enabled, &size);
  if (result == ERROR_SUCCESS && enabled <= 1) enabled_ = enabled != 0;
  else if (result != ERROR_FILE_NOT_FOUND && result != ERROR_PATH_NOT_FOUND) {
    Fail("Не удалось прочитать настройку подсказки блока. Использовано значение по умолчанию.");
  }
  size = sizeof(position_);
  result = RegGetValueW(HKEY_CURRENT_USER, kSettingsPath, kPositionValue,
      RRF_RT_REG_BINARY, nullptr, &position_, &size);
  have_position_ = result == ERROR_SUCCESS && size == sizeof(position_) &&
      position_.version == 1 && position_.monitor[CCHDEVICENAME - 1] == L'\0' &&
      position_.monitor[0] != L'\0' && position_.x >= 0 && position_.y >= 0;
  if (!have_position_ && result != ERROR_FILE_NOT_FOUND && result != ERROR_PATH_NOT_FOUND) {
    Fail("Не удалось восстановить позицию подсказки. Использована безопасная позиция по умолчанию.");
  }
}

bool SlotNotification::SetEnabled(bool enabled, std::string* error) {
  const DWORD value = enabled ? 1 : 0;
  const LSTATUS result = WriteSetting(kEnabledValue, REG_DWORD, &value, sizeof(value));
  if (result != ERROR_SUCCESS) {
    *error = "Не удалось сохранить настройку подсказки. Код Windows: " + std::to_string(result);
    return false;
  }
  enabled_ = enabled;
  if (!enabled_) Dismiss();
  return true;
}

bool SlotNotification::Create() {
  if (window_) return true;
  if (!graphics_token_) {
    Gdiplus::GdiplusStartupInput input;
    if (Gdiplus::GdiplusStartup(&graphics_token_, &input, nullptr) != Gdiplus::Ok) return false;
  }
  if (!window_class_) {
    WNDCLASSW type{};
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpfnWndProc = WndProc;
    type.lpszClassName = kClassName;
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class_ = RegisterClassW(&type);
    if (!window_class_) return false;
  }
  window_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
      kClassName, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, GetModuleHandleW(nullptr), this);
  return window_ != nullptr;
}

bool SlotNotification::Protect() {
  DWORD affinity = WDA_NONE;
  return SupportsExclusion() && ExcludeFromCapture(window_) &&
      GetWindowDisplayAffinity(window_, &affinity) && affinity == WDA_EXCLUDEFROMCAPTURE;
}

HMONITOR SlotNotification::TargetMonitor() const {
  if (!have_position_) return PrimaryMonitor();
  struct Search { const wchar_t* name; HMONITOR found; } search{position_.monitor, nullptr};
  EnumDisplayMonitors(nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
        auto& search = *reinterpret_cast<Search*>(data);
        const auto info = MonitorInfo(monitor);
        if (std::wcscmp(info.szDevice, search.name) == 0) search.found = monitor;
        return TRUE;
      }, reinterpret_cast<LPARAM>(&search));
  return search.found ? search.found : PrimaryMonitor();
}

bool SlotNotification::Render(HMONITOR monitor, const POINT* requested) {
  const auto info = MonitorInfo(monitor);
  const int work_width = info.rcWork.right - info.rcWork.left;
  const int work_height = info.rcWork.bottom - info.rcWork.top;
  if (work_width <= 0 || work_height <= 0) return false;
  const double scale = MonitorScale(monitor);
  const int padding = static_cast<int>(std::ceil(3 * scale));
  const int max_width = (std::max)(1, (std::min)(static_cast<int>(480 * scale), work_width));
  const int max_height = (std::max)(1, (std::min)(static_cast<int>(40 * scale), work_height));
  Gdiplus::Font font(L"Segoe UI", static_cast<Gdiplus::REAL>(16 * scale),
      Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::StringFormat format;
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  Gdiplus::Bitmap measurement(1, 1, PixelFormat32bppPARGB);
  Gdiplus::Graphics measure(&measurement);
  Gdiplus::RectF bounds;
  const int length = static_cast<int>(text_.size());
  if (font.GetLastStatus() != Gdiplus::Ok ||
      measure.MeasureString(text_.c_str(), length, &font, Gdiplus::PointF(0, 0),
                            &format, &bounds) != Gdiplus::Ok) return false;
  const int width = (std::min)(max_width, static_cast<int>(std::ceil(bounds.Width)) + padding * 2);
  const int height = (std::min)(max_height, static_cast<int>(std::ceil(bounds.Height)) + padding * 2);
  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &bitmap_info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  HDC dc = CreateCompatibleDC(nullptr);
  if (!bitmap || !dc) {
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    return false;
  }
  const HGDIOBJ previous = SelectObject(dc, bitmap);
  if (!previous || previous == HGDI_ERROR) {
    DeleteDC(dc);
    DeleteObject(bitmap);
    return false;
  }
  std::memset(pixels, 0, static_cast<size_t>(width) * height * 4);
  bool drawn = false;
  {
    Gdiplus::Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB,
                            static_cast<BYTE*>(pixels));
    Gdiplus::Graphics graphics(&surface);
    const bool cleared = graphics.Clear(Gdiplus::Color(0, 0, 0, 0)) == Gdiplus::Ok;
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    Gdiplus::RectF box(static_cast<float>(padding), static_cast<float>(padding),
        static_cast<float>((std::max)(1, width - padding * 2)),
        static_cast<float>((std::max)(1, height - padding * 2)));
    Gdiplus::SolidBrush shadow(Gdiplus::Color(190, 0, 0, 0));
    Gdiplus::SolidBrush foreground(Gdiplus::Color(255, 255, 255, 255));
    auto shadow_box = box;
    shadow_box.X += static_cast<float>(scale);
    shadow_box.Y += static_cast<float>(scale);
    drawn = cleared && graphics.DrawString(text_.c_str(), length, &font, shadow_box, &format, &shadow) == Gdiplus::Ok &&
        graphics.DrawString(text_.c_str(), length, &font, box, &format, &foreground) == Gdiplus::Ok;
    graphics.Flush(Gdiplus::FlushIntentionSync);
  }
  SlotNotificationPoint location = DefaultSlotNotificationPosition(Area(info.rcWork), width, height,
      static_cast<int>(24 * scale));
  if (requested) location = {requested->x, requested->y};
  else if (have_position_ && std::wcscmp(info.szDevice, position_.monitor) == 0) {
    location = {info.rcWork.left + static_cast<int64_t>(std::llround(position_.x * scale)),
                info.rcWork.top + static_cast<int64_t>(std::llround(position_.y * scale))};
  }
  location = ClampSlotNotification(Area(info.rcWork), width, height, location);
  POINT destination{static_cast<LONG>(location.x), static_cast<LONG>(location.y)};
  POINT source{};
  SIZE size{width, height};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  const bool result = drawn && UpdateLayeredWindow(window_, nullptr, &destination, &size,
      dc, &source, 0, &blend, ULW_ALPHA);
  SelectObject(dc, previous);
  DeleteDC(dc);
  DeleteObject(bitmap);
  return result;
}

void SlotNotification::SelectionChanged(int64_t id, const std::wstring& name, bool main_visible) {
  if (!ShouldShowSlotNotification(enabled_, main_visible, id)) { Dismiss(); return; }
  if (!Create() || !Protect()) {
    Dismiss();
    Fail("Подсказка блока скрыта: не удалось обеспечить исключение её окна из захвата.");
    return;
  }
  text_ = SlotNotificationText(id, name);
  if (!Render(TargetMonitor())) {
    Dismiss();
    Fail("Не удалось отрисовать прозрачную подсказку блока.");
    return;
  }
  lifetime_.Restart(GetTickCount64());
  if (!SetTimer(window_, kHideTimer, SlotNotificationLifetime::kDurationMs, nullptr)) {
    Dismiss();
    Fail("Не удалось запустить таймер подсказки блока.");
    return;
  }
  warning_.clear();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
}

void SlotNotification::Dismiss() {
  lifetime_.Dismiss();
  if (window_) {
    KillTimer(window_, kHideTimer);
    ShowWindow(window_, SW_HIDE);
  }
}

void SlotNotification::SavePosition() {
  RECT rect{};
  if (!GetWindowRect(window_, &rect)) return;
  const HMONITOR monitor = MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  const auto info = MonitorInfo(monitor);
  if (info.rcWork.right <= info.rcWork.left) return;
  const double scale = MonitorScale(monitor);
  position_ = SavedPosition{};
  std::copy_n(info.szDevice, CCHDEVICENAME, position_.monitor);
  position_.x = static_cast<LONG>(std::lround((rect.left - info.rcWork.left) / scale));
  position_.y = static_cast<LONG>(std::lround((rect.top - info.rcWork.top) / scale));
  have_position_ = true;
  const LSTATUS result = WriteSetting(kPositionValue, REG_BINARY, &position_, sizeof(position_));
  if (result != ERROR_SUCCESS) Fail("Не удалось сохранить позицию подсказки блока. Код Windows: " + std::to_string(result));
}

void SlotNotification::RefreshPosition() {
  if (!window_ || !IsWindowVisible(window_)) return;
  RECT rect{};
  if (!GetWindowRect(window_, &rect)) return;
  const HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
  POINT point{rect.left, rect.top};
  if (!Render(monitor ? monitor : PrimaryMonitor(), monitor ? &point : nullptr)) {
    Dismiss();
    Fail("Не удалось обновить позицию подсказки блока.");
  }
}

LRESULT CALLBACK SlotNotification::WndProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto* self = reinterpret_cast<SlotNotification*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SlotNotification*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    self->window_ = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self) {
    if (message == WM_NCDESTROY) {
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      self->window_ = nullptr;
      return DefWindowProcW(window, message, wp, lp);
    }
    return self->HandleMessage(message, wp, lp);
  }
  return DefWindowProcW(window, message, wp, lp);
}

LRESULT SlotNotification::HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_POINTERACTIVATE: return PA_NOACTIVATE;
    // Layered-window alpha-zero pixels pass mouse input to windows underneath.
    // Only the small rendered text/shadow region initiates the system move loop.
    case WM_NCHITTEST: return HTCAPTION;
    case WM_EXITSIZEMOVE: SavePosition(); break;
    case WM_TIMER:
      if (wp == kHideTimer) {
        const UINT remaining = lifetime_.Remaining(GetTickCount64());
        if (!remaining) Dismiss();
        else if (!SetTimer(window_, kHideTimer, remaining, nullptr)) Dismiss();
        return 0;
      }
      break;
    case WM_WINDOWPOSCHANGING: {
      auto* position = reinterpret_cast<WINDOWPOS*>(lp);
      position->flags |= SWP_NOACTIVATE;
      if (IsWindowVisible(window_) && !(position->flags & SWP_NOMOVE)) {
        RECT current{};
        GetWindowRect(window_, &current);
        const int width = position->flags & SWP_NOSIZE ? current.right - current.left : position->cx;
        const int height = position->flags & SWP_NOSIZE ? current.bottom - current.top : position->cy;
        RECT proposed{position->x, position->y, position->x + width, position->y + height};
        const auto info = MonitorInfo(MonitorFromRect(&proposed, MONITOR_DEFAULTTONEAREST));
        const auto point = ClampSlotNotification(Area(info.rcWork), width, height,
            {position->x, position->y});
        position->x = static_cast<int>(point.x);
        position->y = static_cast<int>(point.y);
      }
      break;
    }
    case WM_DPICHANGED: {
      if (!IsWindowVisible(window_)) break;
      const RECT suggested = *reinterpret_cast<RECT*>(lp);
      const POINT point{suggested.left, suggested.top};
      if (!Render(MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST), &point)) {
        Dismiss();
        Fail("Не удалось обновить масштаб подсказки блока.");
      }
      return 0;
    }
    case WM_DISPLAYCHANGE: RefreshPosition(); return 0;
    case WM_SETTINGCHANGE:
      if (wp == SPI_SETWORKAREA) RefreshPosition();
      break;
    case WM_DWMCOMPOSITIONCHANGED:
      if (IsWindowVisible(window_) && !Protect()) {
        Dismiss();
        Fail("Подсказка скрыта: исключение из захвата больше недоступно.");
      }
      return 0;
    case WM_CLOSE: Dismiss(); return 0;
  }
  return DefWindowProcW(window_, message, wp, lp);
}
