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
#include <sstream>

#include "capture_exclusion.h"
#include "capture_diagnostics.h"
#include "slot_notification_surface.h"

namespace {
constexpr wchar_t kClassName[] = L"Helper.SlotNotification";
constexpr wchar_t kSettingsPath[] = L"Software\\Helper\\Window";
constexpr wchar_t kEnabledValue[] = L"SlotNotificationEnabled";
constexpr wchar_t kPositionValue[] = L"SlotNotificationPositionV1";
constexpr UINT_PTR kHideTimer = 1;
constexpr UINT kRefreshSurface = WM_APP + 1; // This independent HWND's queue.

SlotNotificationArea Area(const RECT& r) { return {r.left, r.top, r.right, r.bottom}; }
MONITORINFOEXW MonitorInfo(HMONITOR monitor) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info))) {
    const DWORD code = GetLastError();
    TraceCaptureApi("GetMonitorInfoW", nullptr, false, code);
    info.rcWork = {};
  }
  return info;
}
HMONITOR PrimaryMonitor() {
  return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}
double MonitorScale(HMONITOR monitor) {
  return (std::max)(1.0, FlutterDesktopGetDpiForMonitor(monitor) / 96.0);
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
  surface_.Reset();
  if (graphics_token_) Gdiplus::GdiplusShutdown(graphics_token_);
  if (window_class_) UnregisterClassW(kClassName, GetModuleHandleW(nullptr));
}

void SlotNotification::Fail(const std::string& message) {
  warning_ = message;
  std::cerr << message << std::endl;
  TraceCaptureFailure(message);
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
    ULONG_PTR token = 0;
    const auto status = Gdiplus::GdiplusStartup(&token, &input, nullptr);
    if (status != Gdiplus::Ok) return native_error_.Graphics("GdiplusStartup", status);
    graphics_token_ = token;
  }
  if (!window_class_) {
    WNDCLASSW type{};
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpfnWndProc = WndProc;
    type.lpszClassName = kClassName;
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class_ = RegisterClassW(&type);
    if (!window_class_) return native_error_.Win32("RegisterClassW", GetLastError());
  }
  native_error_ = {};
  affinity_applied_ = false;
  affinity_readback_noted_ = false;
  window_ = CreateWindowExW(SlotNotificationSurface::kExStyle,
      kClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), this);
  if (!window_) {
    const DWORD code = GetLastError();
    if (std::strcmp(native_error_.operation, "none") != 0) return false;
    return native_error_.Win32("CreateWindowExW", code);
  }
  TraceCaptureApi("CreateWindowExW(DWM redirected, non-layered)", window_, true);
  if (!SlotNotificationSurface::Configure(window_, &native_error_)) {
    DestroyWindow(window_);
    return false;
  }
  TraceCapture("slot_notification.dwm_surface_ready", window_, true, false);
  return true;
}

bool SlotNotification::Protect(bool refresh) {
  if (!SlotNotificationCaptureSupported(CaptureWindowsBuild())) {
    return native_error_.HResult("WindowsBuild(requires 19041 or newer)", E_NOTIMPL);
  }
  DWORD process = 0;
  if (!GetWindowThreadProcessId(window_, &process))
    return native_error_.Win32("GetWindowThreadProcessId", GetLastError());
  if (process != GetCurrentProcessId() || GetAncestor(window_, GA_ROOT) != window_)
    return native_error_.HResult("VerifyOwnTopLevelHWND", E_ACCESSDENIED);
  constexpr LONG_PTR no_redirection = 0x00200000; // WS_EX_NOREDIRECTIONBITMAP
  if (GetWindowLongPtrW(window_, GWL_EXSTYLE) & (WS_EX_LAYERED | no_redirection))
    return native_error_.HResult("VerifyDwmRedirectedStyle(no layered/no-redirection)", E_INVALIDARG);
  BOOL composition = FALSE;
  const HRESULT composed = DwmIsCompositionEnabled(&composition);
  if (FAILED(composed)) return native_error_.HResult("DwmIsCompositionEnabled", composed);
  if (!composition) return native_error_.HResult("DwmIsCompositionEnabled(disabled)", DWM_E_COMPOSITIONDISABLED);
  DWORD affinity = WDA_NONE;
  DWORD error = ERROR_SUCCESS;
  if (refresh) affinity_applied_ = false;
  if (!affinity_applied_) {
    // Force a real setter, not a cached Get result, before storing this proof.
    if (!ExcludeFromCapture(window_, true, &error)) {
      return native_error_.Win32("SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)", error);
    }
    affinity_applied_ = true;
    TraceCaptureApi("SetWindowDisplayAffinity(0x11)", window_, true);
  }
  const BOOL readable = GetWindowDisplayAffinity(window_, &affinity);
  const DWORD query_error = readable ? ERROR_SUCCESS : GetLastError();
  if (!SlotNotificationProtectionConfirmed(affinity_applied_, readable != FALSE,
                                           affinity, query_error, false)) {
    affinity_applied_ = false;
    if (!readable) return native_error_.Win32("GetWindowDisplayAffinity", query_error);
    return native_error_.HResult("VerifyAffinity(expected 0x11)", E_ACCESSDENIED);
  }
  if (!readable && !affinity_readback_noted_) {
    affinity_readback_noted_ = true;
    TraceCaptureApi("GetWindowDisplayAffinity(non-layered readback unavailable)", window_, false, query_error);
    TraceCaptureNote("slot_notification: SetWindowDisplayAffinity(0x11) succeeded; Get is unavailable "
                     "for this non-layered HWND per the API prerequisite. No affinity downgrade.");
  }
  return true;
}

void SlotNotification::ProtectionFailed() {
  NativeFailed(native_error_);
}

void SlotNotification::NativeFailed(const SlotSurfaceError& error) {
  // Copy before ShowWindow/WM_PAINT can re-enter our procedure.
  const auto failure = error;
  native_error_ = failure;
  Dismiss();
  TraceCaptureApi(failure.operation, window_, false, failure.win32, failure.hresult);
  TraceCapture("slot_notification.failure", window_, true, false, failure.win32);
  std::ostringstream message;
  message << "Подсказка блока не показана. Ошибка " << failure.operation;
  if (failure.graphics_status >= 0) message << ": GDI+ status " << failure.graphics_status;
  else if (FAILED(failure.hresult)) message << ": HRESULT 0x" << std::hex
      << static_cast<unsigned long>(failure.hresult) << std::dec;
  else message << ": Win32 " << failure.win32 << " (" << CaptureErrorMessage(failure.win32) << ')';
  message << ". Сборка Windows " << CaptureWindowsBuild() << ". Показ без защиты запрещён.";
  Fail(message.str());
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
  if (work_width <= 0 || work_height <= 0)
    return native_error_.HResult("GetMonitorInfoW/validate work area", E_FAIL);
  const double scale = MonitorScale(monitor);
  const int padding = static_cast<int>(std::ceil(2 * scale));
  const int max_width = (std::max)(1, (std::min)(static_cast<int>(420 * scale), work_width));
  const int max_height = (std::max)(1, (std::min)(static_cast<int>(34 * scale), work_height));
  Gdiplus::Font font(L"Segoe UI", static_cast<Gdiplus::REAL>(14 * scale),
      Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::StringFormat format;
  auto formatted = format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  if (formatted != Gdiplus::Ok) return native_error_.Graphics("GDI+ SetFormatFlags", formatted);
  formatted = format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  if (formatted != Gdiplus::Ok) return native_error_.Graphics("GDI+ SetTrimming", formatted);
  Gdiplus::Bitmap measurement(1, 1, PixelFormat32bppPARGB);
  const auto measurement_status = measurement.GetLastStatus();
  if (measurement_status != Gdiplus::Ok) return native_error_.Graphics("GDI+ Bitmap(measurement)", measurement_status);
  Gdiplus::Graphics measure(&measurement);
  Gdiplus::RectF bounds;
  const int length = static_cast<int>(text_.size());
  const auto font_status = font.GetLastStatus();
  if (font_status != Gdiplus::Ok) return native_error_.Graphics("GDI+ Font", font_status);
  const auto measured = measure.MeasureString(text_.c_str(), length, &font, Gdiplus::PointF(0, 0),
                                              &format, &bounds);
  if (measured != Gdiplus::Ok) return native_error_.Graphics("GDI+ MeasureString", measured);
  const int width = (std::min)(max_width, static_cast<int>(std::ceil(bounds.Width)) + padding * 2);
  const int height = (std::min)(max_height, static_cast<int>(std::ceil(bounds.Height)) + padding * 2);
  std::vector<uint32_t> pixels(static_cast<size_t>(width) * height, 0);
  {
    Gdiplus::Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB,
                            reinterpret_cast<BYTE*>(pixels.data()));
    const auto surface_status = surface.GetLastStatus();
    if (surface_status != Gdiplus::Ok) return native_error_.Graphics("GDI+ Bitmap(frame)", surface_status);
    Gdiplus::Graphics graphics(&surface);
    auto status = graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
    if (status != Gdiplus::Ok) return native_error_.Graphics("GDI+ Clear", status);
    status = graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    if (status != Gdiplus::Ok) return native_error_.Graphics("GDI+ SetTextRenderingHint", status);
    Gdiplus::RectF box(static_cast<float>(padding), static_cast<float>(padding),
        static_cast<float>((std::max)(1, width - padding * 2)),
        static_cast<float>((std::max)(1, height - padding * 2)));
    Gdiplus::SolidBrush shadow(Gdiplus::Color(190, 0, 0, 0));
    Gdiplus::SolidBrush foreground(Gdiplus::Color(255, 255, 255, 255));
    const auto shadow_status = shadow.GetLastStatus();
    if (shadow_status != Gdiplus::Ok) return native_error_.Graphics("GDI+ SolidBrush(shadow)", shadow_status);
    const auto foreground_status = foreground.GetLastStatus();
    if (foreground_status != Gdiplus::Ok) return native_error_.Graphics("GDI+ SolidBrush(text)", foreground_status);
    auto shadow_box = box;
    shadow_box.X += static_cast<float>(scale);
    shadow_box.Y += static_cast<float>(scale);
    status = graphics.DrawString(text_.c_str(), length, &font, shadow_box, &format, &shadow);
    if (status != Gdiplus::Ok) return native_error_.Graphics("GDI+ DrawString(shadow)", status);
    status = graphics.DrawString(text_.c_str(), length, &font, box, &format, &foreground);
    if (status != Gdiplus::Ok) return native_error_.Graphics("GDI+ DrawString(text)", status);
    graphics.Flush(Gdiplus::FlushIntentionSync); // VOID API: no GetLastError/fictional status.
  }
  if (std::none_of(pixels.begin(), pixels.end(), [](uint32_t pixel) { return (pixel >> 24) != 0; }))
    return native_error_.HResult("VerifyTextAlpha(non-empty)", E_FAIL);
  SlotNotificationPoint location = DefaultSlotNotificationPosition(Area(info.rcWork), width, height,
      static_cast<int>(24 * scale));
  if (requested) location = {requested->x, requested->y};
  else if (have_position_ && std::wcscmp(info.szDevice, position_.monitor) == 0) {
    location = {info.rcWork.left + static_cast<int64_t>(std::llround(position_.x * scale)),
                info.rcWork.top + static_cast<int64_t>(std::llround(position_.y * scale))};
  }
  location = ClampSlotNotification(Area(info.rcWork), width, height, location);
  rendering_ = true;
  render_message_failed_ = false;
  const bool result = surface_.SetFrame(window_, pixels, width, height,
      static_cast<int>(location.x), static_cast<int>(location.y), &native_error_);
  rendering_ = false;
  return result && !render_message_failed_;
}

bool SlotNotification::Repaint() {
  paint_ok_ = true;
  SetLastError(ERROR_SUCCESS);
  if (!RedrawWindow(window_, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE)) {
    const DWORD error = GetLastError();
    SlotSurfaceError failure;
    failure.Win32("RedrawWindow", error);
    NativeFailed(failure);
    return false;
  }
  return paint_ok_;
}

void SlotNotification::SelectionChanged(int64_t id, const std::wstring& name, bool main_visible) {
  if (!ShouldShowSlotNotification(enabled_, main_visible, id)) { Dismiss(); return; }
  if (!Create()) {
    NativeFailed(native_error_);
    return;
  }
  if (!Protect()) {
    ProtectionFailed();
    return;
  }
  text_ = SlotNotificationText(id, name);
  RECT current{};
  const bool moving = lifetime_.dragging();
  if (moving && !GetWindowRect(window_, &current)) {
    native_error_.Win32("GetWindowRect(drag)", GetLastError());
    NativeFailed(native_error_);
    return;
  }
  const POINT point{current.left, current.top};
  if (!Render(moving ? MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST) : TargetMonitor(),
              moving ? &point : nullptr)) {
    NativeFailed(native_error_);
    return;
  }
  TraceCapture("slot_notification.frame_ready", window_, !IsWindowVisible(window_), false);
  // Resize/region changes retain affinity. Verify again before the first show.
  if (!Protect()) {
    ProtectionFailed();
    return;
  }
  TraceCapture("slot_notification.protected", window_, !IsWindowVisible(window_), false);
  // ShowWindow's return value is PREVIOUS visibility, not an error indicator.
  paint_ok_ = true;
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  if (!paint_ok_) return; // A synchronous WM_PAINT already reported its exact failure.
  if (!IsWindowVisible(window_)) {
    SlotSurfaceError failure;
    failure.HResult("VerifyVisibility(after SW_SHOWNOACTIVATE)", E_FAIL);
    NativeFailed(failure);
    return;
  }
  if (!Repaint()) return;
  lifetime_.Restart(GetTickCount64());
  if (!SetTimer(window_, kHideTimer, SlotNotificationLifetime::kDurationMs, nullptr)) {
    const DWORD error = GetLastError();
    SlotSurfaceError failure;
    failure.Win32("SetTimer", error);
    NativeFailed(failure);
    return;
  }
  warning_.clear();
  TraceCapture("slot_notification.show", window_, false, false);
}

void SlotNotification::Dismiss() {
  lifetime_.Dismiss();
  if (window_) {
    KillTimer(window_, kHideTimer);
    const bool visible = IsWindowVisible(window_) != FALSE;
    ShowWindow(window_, SW_HIDE);
    if (visible) TraceCapture("slot_notification.hide", window_, true, false);
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
    NativeFailed(native_error_);
  } else Repaint();
}

LRESULT CALLBACK SlotNotification::WndProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto* self = reinterpret_cast<SlotNotification*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SlotNotification*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    self->window_ = window;
    SetLastError(ERROR_SUCCESS); // A zero previous value is also a valid success.
    const LONG_PTR previous = SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    if (!previous) {
      const DWORD error = GetLastError();
      if (error) {
        self->native_error_.Win32("SetWindowLongPtrW(GWLP_USERDATA)", error);
        TraceCaptureApi("SetWindowLongPtrW(GWLP_USERDATA)", window, false, error);
        return FALSE;
      }
    }
  }
  if (self) {
    if (message == WM_NCDESTROY) {
      SetLastError(ERROR_SUCCESS);
      const LONG_PTR previous = SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      if (!previous) {
        const DWORD error = GetLastError();
        if (error) TraceCaptureApi("SetWindowLongPtrW(clear user data)", window, false, error);
      }
      self->window_ = nullptr;
      self->affinity_applied_ = false;
      return DefWindowProcW(window, message, wp, lp);
    }
    return self->HandleMessage(message, wp, lp);
  }
  return DefWindowProcW(window, message, wp, lp);
}

LRESULT SlotNotification::HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
    case kRefreshSurface:
      refresh_pending_ = false;
      RefreshPosition();
      return 0;
    case WM_NCCALCSIZE: return 0;
    case WM_NCPAINT: return 0;
    case WM_ERASEBKGND: return 1; // WM_PAINT copies all premultiplied pixels, including alpha-zero.
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      SetLastError(ERROR_SUCCESS);
      HDC dc = BeginPaint(window_, &paint);
      if (!dc) {
        const DWORD error = GetLastError();
        SlotSurfaceError failure;
        failure.Win32("BeginPaint", error);
        paint_ok_ = false;
        NativeFailed(failure);
        return 0;
      }
      SlotSurfaceError failure;
      bool okay = true;
      if (!surface_.empty()) {
        okay = Protect();
        if (!okay) failure = native_error_;
        else okay = surface_.Paint(dc, &failure);
      }
      const BOOL ended = EndPaint(window_, &paint);
      if (!ended && okay) {
        const DWORD error = GetLastError();
        okay = failure.Win32("EndPaint", error);
      }
      if (!okay) {
        paint_ok_ = false;
        if (rendering_) render_message_failed_ = true;
        NativeFailed(failure);
      }
      return 0;
    }
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_POINTERACTIVATE: return PA_NOACTIVATE;
    // SetWindowRgn restricts input to text/shadow; all other pixels fall through
    // to the actual windows underneath, including other processes.
    case WM_NCHITTEST: return HTCAPTION;
    case WM_ENTERSIZEMOVE: lifetime_.SetDragging(true); return 0;
    case WM_EXITSIZEMOVE:
      SavePosition();
      lifetime_.SetDragging(false);
      if (lifetime_.ShouldHide(GetTickCount64())) Dismiss();
      return 0;
    case WM_TIMER:
      if (wp == kHideTimer) {
        const UINT remaining = lifetime_.Remaining(GetTickCount64());
        if (!remaining) {
          KillTimer(window_, kHideTimer);
          if (lifetime_.ShouldHide(GetTickCount64())) Dismiss();
        } else if (!SetTimer(window_, kHideTimer, remaining, nullptr)) Dismiss();
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
      // SetWindowPos can synchronously report a DPI change. Finish the current
      // frame first; refresh once via the event queue, never recursively replace
      // the bitmap/region while SetFrame still owns its local GDI resources.
      if (rendering_) {
        if (!refresh_pending_) {
          if (!PostMessageW(window_, kRefreshSurface, 0, 0)) {
            native_error_.Win32("PostMessageW(DPI refresh)", GetLastError());
            render_message_failed_ = true;
          } else refresh_pending_ = true;
        }
        return 0;
      }
      const RECT suggested = *reinterpret_cast<RECT*>(lp);
      const POINT point{suggested.left, suggested.top};
      if (!Render(MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST), &point)) {
        NativeFailed(native_error_);
      } else Repaint();
      return 0;
    }
    case WM_DISPLAYCHANGE: RefreshPosition(); return 0;
    case WM_SETTINGCHANGE:
      if (wp == SPI_SETWORKAREA) RefreshPosition();
      break;
    case WM_DWMCOMPOSITIONCHANGED: {
      const bool visible = IsWindowVisible(window_) != FALSE;
      affinity_applied_ = false;
      affinity_readback_noted_ = false;
      ShowWindow(window_, SW_HIDE); // Revalidate composition while no text is visible.
      if (!SlotNotificationSurface::Configure(window_, &native_error_)) NativeFailed(native_error_);
      else if (!Protect(true)) ProtectionFailed();
      else if (visible && !lifetime_.ShouldHide(GetTickCount64())) {
        ShowWindow(window_, SW_SHOWNOACTIVATE);
        Repaint();
      } else Dismiss();
      return 0;
    }
    case WM_CLOSE: Dismiss(); return 0;
  }
  return DefWindowProcW(window_, message, wp, lp);
}
