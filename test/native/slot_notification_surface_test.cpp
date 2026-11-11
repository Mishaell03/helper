// Windows-only. Uses the real production renderer, DWM and affinity APIs.
#include "../../windows/runner/slot_notification_surface.h"
#include "../../windows/runner/slot_notification_policy.h"
#include "../../windows/runner/capture_exclusion.h"

#include <cassert>
#include <iostream>

namespace {
struct State {
  SlotNotificationSurface surface;
  int paints = 0;
  bool failed = false;
  bool setter_succeeded = false;
};
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto* state = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    state = static_cast<State*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
  }
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_POINTERACTIVATE) return PA_NOACTIVATE;
  if (message == WM_NCCALCSIZE || message == WM_NCPAINT) return 0;
  if (message == WM_ERASEBKGND) return 1;
  if (message == WM_PAINT && state) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    if (!state->surface.empty()) {
      DWORD affinity = WDA_NONE;
      const BOOL readable = GetWindowDisplayAffinity(window, &affinity);
      const DWORD query_error = readable ? ERROR_SUCCESS : GetLastError();
      assert(SlotNotificationProtectionConfirmed(state->setter_succeeded, readable != FALSE,
                                                 affinity, query_error, false));
      SlotSurfaceError error;
      state->failed = !dc || !state->surface.Paint(dc, &error);
      ++state->paints;
    }
    EndPaint(window, &paint);
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}

// Reproduce the PREVIOUS rendering configuration using only one blank pixel.
// A failure here is diagnostic, not an expected assertion on every Windows build.
void ProbeLegacy(HINSTANCE instance, const wchar_t* name) {
  HWND window = CreateWindowExW(SlotNotificationSurface::kExStyle | WS_EX_LAYERED,
      name, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, instance, nullptr);
  assert(window);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = 1; info.bmiHeader.biHeight = -1;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  assert(bitmap);
  *static_cast<DWORD*>(bits) = 0;
  HDC dc = CreateCompatibleDC(nullptr);
  assert(dc);
  HGDIOBJ previous = SelectObject(dc, bitmap);
  SIZE size{1, 1}; POINT source{};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  const BOOL updated = UpdateLayeredWindow(window, nullptr, nullptr, &size, dc, &source, 0, &blend, ULW_ALPHA);
  const DWORD update_error = updated ? ERROR_SUCCESS : GetLastError();
  DWORD protection_error = ERROR_SUCCESS;
  const bool protected_window = updated && ExcludeFromCapture(window, false, &protection_error);
  std::cout << "legacy: UpdateLayeredWindow=" << updated << " error=" << update_error
            << " SetWindowDisplayAffinity=" << (updated ? (protected_window ? "true" : "false") : "skipped")
            << " error=" << protection_error << '\n';
  assert(!IsWindowVisible(window));
  SelectObject(dc, previous); DeleteDC(dc); DeleteObject(bitmap);
  DestroyWindow(window);
}
}  // namespace

int main() {
  using Version = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto get_version = reinterpret_cast<Version>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  const DWORD build = get_version && get_version(&version) == 0 ? version.dwBuildNumber : 0;
  std::cout << "windows_build=" << build << '\n';
  if (!SlotNotificationCaptureSupported(build)) {
    std::cout << "SKIP: WDA_EXCLUDEFROMCAPTURE requires Windows 10 2004+; no window/text shown\n";
    return 0;
  }
  WNDCLASSW type{};
  type.lpfnWndProc = WindowProc;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"Helper.SlotNotification.SurfaceTest";
  assert(RegisterClassW(&type));
  HWND foreground = GetForegroundWindow();
  ProbeLegacy(type.hInstance, type.lpszClassName);
  State state;
  HWND window = CreateWindowExW(SlotNotificationSurface::kExStyle, type.lpszClassName,
      L"", WS_POPUP, 100, 100, 1, 1, nullptr, nullptr, type.hInstance, &state);
  assert(window);
  assert(!(GetWindowLongPtrW(window, GWL_EXSTYLE) & (WS_EX_LAYERED | 0x00200000)));
  SlotSurfaceError surface_error;
  const bool configured = SlotNotificationSurface::Configure(window, &surface_error);
  DWORD error = ERROR_SUCCESS;
  const bool protected_window = configured && ExcludeFromCapture(window, false, &error);
  state.setter_succeeded = protected_window;
  DWORD affinity = WDA_NONE;
  bool verified = false;
  const char* failed_api = configured ? "SetWindowDisplayAffinity" : surface_error.operation;
  if (protected_window) {
    if (!GetWindowDisplayAffinity(window, &affinity)) {
      error = GetLastError();
      failed_api = "GetWindowDisplayAffinity";
      verified = SlotNotificationProtectionConfirmed(protected_window, false, affinity, error, false);
      if (verified) std::cout << "GetWindowDisplayAffinity unavailable for non-layered HWND; "
                                 "Set(0x11) succeeded, readback error=" << error << '\n';
    } else {
      verified = affinity == WDA_EXCLUDEFROMCAPTURE;
      failed_api = "VerifyAffinity(expected 0x11)";
    }
  }
  if (!verified) {
    assert(!IsWindowVisible(window));
    std::cerr << "FAIL: new DWM path; api=" << failed_api
              << " win32=" << (configured ? error : surface_error.win32)
              << " hr=" << surface_error.hresult << " affinity=" << affinity << '\n';
    DestroyWindow(window);
    UnregisterClassW(type.lpszClassName, type.hInstance);
    return 1;
  }
  std::vector<uint32_t> pixels(40 * 16, 0);
  pixels[1 * 40 + 1] = 0xffffffff; // Non-sensitive synthetic paint, not block text.
  pixels[2 * 40 + 2] = 0x80808080;
  assert(state.surface.SetFrame(window, pixels, 40, 16, 100, 100, &surface_error));
  HRGN region = CreateRectRgn(0, 0, 0, 0);
  assert(GetWindowRgn(window, region) != ERROR);
  assert(!PtInRegion(region, 0, 0));
  assert(PtInRegion(region, 1, 1));
  assert(PtInRegion(region, 2, 2));
  assert(!PtInRegion(region, 20, 10));
  DeleteObject(region);
  ShowWindow(window, SW_SHOWNOACTIVATE);
  assert(RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE));
  assert(IsWindowVisible(window) && state.paints > 0 && !state.failed);
  assert(GetForegroundWindow() == foreground);
  const DWORD objects = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  for (int i = 0; i < 32; ++i) {
    assert(state.surface.SetFrame(window, pixels, 40, 16, 100, 100, &surface_error));
    assert(RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE));
    const BOOL readable = GetWindowDisplayAffinity(window, &affinity);
    const DWORD query_error = readable ? ERROR_SUCCESS : GetLastError();
    assert(SlotNotificationProtectionConfirmed(protected_window, readable != FALSE, affinity, query_error, false));
    assert(GetForegroundWindow() == foreground && !state.failed);
  }
  assert(GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) == objects);
  ShowWindow(window, SW_HIDE);
  DestroyWindow(window);
  state.surface.Reset();
  UnregisterClassW(type.lpszClassName, type.hInstance);
  std::cout << "PASS: protected non-layered WM_PAINT path, alpha hit region, no activation or GDI leaks\n";
}
