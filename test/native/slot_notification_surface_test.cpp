// Windows interactive desktop only. Real DWM/affinity/parking and GDI capture.
// Not a Flutter main-window test or an OBS/WGC certification.
#include "../../windows/runner/slot_notification_surface.h"
#include "../../windows/runner/slot_notification_policy.h"
#include "../../windows/runner/capture_exclusion.h"
#include "../../windows/runner/capture_diagnostics.h"
#include "../../windows/runner/capture_window_parking.h"
#include "../../windows/runner/frameless_window.h"

#include <cassert>
#include <iostream>

namespace {
struct State {
  SlotNotificationSurface surface;
  CaptureWindowParking parking;
  bool allow_paint = false;
  bool setter_succeeded = false;
  int paints = 0;
  int shows = 0;
  int hides = 0;
};

bool Verify(HWND window, bool setter_succeeded) {
  DWORD affinity = WDA_NONE;
  const BOOL readable = GetWindowDisplayAffinity(window, &affinity);
  const DWORD error = readable ? ERROR_SUCCESS : GetLastError();
  return SlotNotificationProtectionConfirmed(setter_succeeded, readable != FALSE,
                                               affinity, error, false);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto* state = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    state = static_cast<State*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
  }
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_NCCALCSIZE || message == WM_NCPAINT) return 0;
  if (message == WM_ERASEBKGND) return 1;
  if (state && message == WM_SHOWWINDOW) {
    if (wp) ++state->shows; else ++state->hides;
  }
  if (state && message == WM_WINDOWPOSCHANGING && state->parking.parked())
    state->parking.ConstrainPosition(reinterpret_cast<WINDOWPOS*>(lp));
  if (message == WM_PAINT && state) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    assert(dc);
    if (state->allow_paint && !state->surface.empty()) {
      assert(Verify(window, state->setter_succeeded)); // No unprotected copy.
      SlotSurfaceError error;
      assert(state->surface.Paint(dc, &error));
      ++state->paints;
    }
    EndPaint(window, &paint);
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}

LRESULT CALLBACK BackgroundProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    RECT rect{};
    GetClientRect(window, &rect);
    HBRUSH brush = CreateSolidBrush(RGB(16, 80, 180));
    assert(brush);
    FillRect(dc, &rect, brush);
    DeleteObject(brush);
    EndPaint(window, &paint);
    return 0;
  }
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  return DefWindowProcW(window, message, wp, lp);
}

std::vector<uint32_t> Capture(const RECT& rect) {
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  assert(screen && dc);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  assert(bitmap);
  HGDIOBJ previous = SelectObject(dc, bitmap);
  assert(previous && previous != HGDI_ERROR);
  assert(BitBlt(dc, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT));
  assert(GdiFlush());
  std::vector<uint32_t> pixels(static_cast<size_t>(width) * height);
  std::memcpy(pixels.data(), bits, pixels.size() * sizeof(uint32_t));
  for (auto& pixel : pixels) pixel &= 0xffffff; // Desktop alpha is unspecified.
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return pixels;
}

bool CaptureUnchanged(const RECT& area, const std::vector<uint32_t>& baseline,
                      int cycle, const char* phase) {
  assert(SUCCEEDED(DwmFlush()));
  const auto actual = Capture(area);
  size_t changed = 0;
  for (size_t i = 0; i < actual.size(); ++i) if (actual[i] != baseline[i]) ++changed;
  if (changed) std::cerr << "FAIL: captured pixels changed; cycle=" << cycle
                         << " phase=" << phase << " pixels=" << changed << '\n';
  return changed == 0; // No tolerance that could miss a compact notification.
}
}  // namespace

int main() {
  std::cout << "windows_build=" << CaptureWindowsBuild()
            << " stable_surface=" << UseStableCaptureSurface() << '\n';
  if (!SlotNotificationCaptureSupported(CaptureWindowsBuild())) {
    std::cout << "SKIP: requires Windows 10 2004+; no window/text shown\n";
    return 0;
  }
  SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW type{};
  type.lpfnWndProc = WindowProc;
  type.hInstance = instance;
  type.lpszClassName = L"Helper.SlotNotification.SurfaceTest";
  assert(RegisterClassW(&type));
  WNDCLASSW backdrop_type = type;
  backdrop_type.lpfnWndProc = BackgroundProc;
  backdrop_type.lpszClassName = L"Helper.SlotNotification.CaptureBackdrop";
  assert(RegisterClassW(&backdrop_type));
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  assert(GetMonitorInfoW(MonitorFromPoint(POINT{}, MONITOR_DEFAULTTOPRIMARY), &monitor));
  const RECT area{monitor.rcWork.left + 40, monitor.rcWork.top + 40,
                  monitor.rcWork.left + 440, monitor.rcWork.top + 160};
  assert(area.right <= monitor.rcWork.right && area.bottom <= monitor.rcWork.bottom);
  HWND foreground = GetForegroundWindow();
  HWND backdrop = CreateWindowExW(SlotNotificationSurface::kExStyle,
      backdrop_type.lpszClassName, L"", WS_POPUP, area.left, area.top, 400, 120,
      nullptr, nullptr, instance, nullptr);
  assert(backdrop);
  ShowWindow(backdrop, SW_SHOWNOACTIVATE);
  assert(RedrawWindow(backdrop, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW));
  assert(SUCCEEDED(DwmFlush()));
  const auto baseline = Capture(area);
  assert(baseline.front() == 0x001050b4); // Known underlay, not a black/empty capture.

  // Compare the actual common configuration entry points on separate HWNDs.
  // The main-style probe deliberately has no private pixels and is never shown.
  HWND main_probe = CreateWindowExW(SlotNotificationSurface::kExStyle, type.lpszClassName,
      L"", static_cast<DWORD>(FramelessWindowStyle(WS_OVERLAPPEDWINDOW)),
      area.left, area.top, 100, 40, nullptr, nullptr, instance, nullptr);
  assert(main_probe);
  std::string main_error;
  assert(ConfigureTransparentComposition(main_probe, &main_error));
  DWORD error = ERROR_SUCCESS;
  assert(ExcludeFromCapture(main_probe, true, &error));
  assert(Verify(main_probe, true));
  BOOL main_nc = TRUE;
  assert(SUCCEEDED(DwmGetWindowAttribute(main_probe, DWMWA_NCRENDERING_ENABLED, &main_nc, sizeof(main_nc))));

  State state;
  HWND window = CreateWindowExW(SlotNotificationSurface::kExStyle, type.lpszClassName,
      L"", WS_POPUP, area.left, area.top, 1, 1, nullptr, nullptr, instance, &state);
  assert(window);
  SlotSurfaceError surface_error;
  assert(SlotNotificationSurface::Configure(window, &surface_error));
  BOOL overlay_nc = TRUE;
  assert(SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_NCRENDERING_ENABLED, &overlay_nc, sizeof(overlay_nc))));
  assert(main_nc == FALSE && overlay_nc == main_nc);
  assert(ExcludeFromCapture(window, true, &error));
  state.setter_succeeded = true;
  assert(Verify(window, true));
  assert(!(GetWindowLongPtrW(window, GWL_EXSTYLE) & (WS_EX_LAYERED | 0x00200000)));
  bool capture_ok = true;
  DWORD objects = 0;
  for (int cycle = 0; cycle < 32; ++cycle) {
    const int width = 80 + cycle % 3 * 20; // Region and size really change.
    const int height = 24;
    std::vector<uint32_t> pixels(static_cast<size_t>(width) * height, 0);
    for (int y = 2; y < height - 2; ++y)
      for (int x = 2; x < width - 2; ++x)
        pixels[static_cast<size_t>(y) * width + x] = (x % 4) ? 0xffffffff : 0x80808080;
    state.allow_paint = false;
    state.setter_succeeded = false;
    const int paints_before = state.paints;
    assert(state.surface.SetFrame(window, pixels, width, height,
                                   area.left + 20, area.top + 20, &surface_error));
    assert(state.paints == paints_before); // No synchronous pre-protection paint.
    const RECT bounds{area.left + 20, area.top + 20,
                      area.left + 20 + width, area.top + 20 + height};
    state.parking.SetRestoreBounds(bounds);
    assert(ExcludeFromCapture(window, true, &error));
    state.setter_succeeded = true;
    assert(Verify(window, true));
    state.allow_paint = true;
    assert(state.parking.Restore(window));
    if (!IsWindowVisible(window)) ShowWindow(window, SW_SHOWNOACTIVATE);
    assert(RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE));
    assert(state.paints > paints_before);
    assert(IsWindowVisible(window) && MonitorFromWindow(window, MONITOR_DEFAULTTONULL));
    assert(GetForegroundWindow() == foreground);
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    assert(GetWindowRgn(window, region) != ERROR);
    assert(!PtInRegion(region, 0, 0) && PtInRegion(region, 2, 2) && PtInRegion(region, 4, 2));
    DeleteObject(region);
    capture_ok = CaptureUnchanged(area, baseline, cycle, "visible") && capture_ok;
    if (UseStableCaptureSurface()) {
      // Rapid replacement while locally visible, not just timeout/reveal.
      state.allow_paint = false;
      assert(state.parking.Park(window));
      state.setter_succeeded = false;
      pixels[static_cast<size_t>(3) * width + 3] = 0; // A different HWND region.
      const int paints_before_replace = state.paints;
      assert(state.surface.SetFrame(window, pixels, width, height,
                                     bounds.left, bounds.top, &surface_error));
      assert(state.paints == paints_before_replace);
      state.parking.SetRestoreBounds(bounds);
      assert(ExcludeFromCapture(window, true, &error));
      state.setter_succeeded = true;
      assert(Verify(window, true));
      state.allow_paint = true;
      assert(state.parking.Restore(window));
      assert(RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE));
      capture_ok = CaptureUnchanged(area, baseline, cycle, "rapid replacement") && capture_ok;
      assert(state.parking.Park(window));
      assert(IsWindowVisible(window));
      assert(!MonitorFromWindow(window, MONITOR_DEFAULTTONULL));
      state.parking.Repark(window);
    } else ShowWindow(window, SW_HIDE);
    FlushHiddenWindowComposition();
    capture_ok = CaptureUnchanged(area, baseline, cycle, "concealed") && capture_ok;
    assert(Verify(window, true));
    const DWORD current = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    if (cycle == 0) objects = current;
    else assert(current == objects);
  }
  if (UseStableCaptureSurface()) assert(state.shows == 1 && state.hides == 0);
  DestroyWindow(window);
  state.surface.Reset();
  DestroyWindow(main_probe);
  DestroyWindow(backdrop);
  UnregisterClassW(type.lpszClassName, instance);
  UnregisterClassW(backdrop_type.lpszClassName, instance);
  if (!capture_ok) return 1; // API success must NOT mask a real capture failure.
  std::cout << "PASS: shared configuration, 32 protected cycles, unchanged GDI capture, stable GDI count\n"
            << "Still requires local visual inspection and actual OBS/screen-sharing output on build 19044.\n";
}
