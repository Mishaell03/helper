#include "window_composition.h"

#include <dwmapi.h>
#include <iostream>

namespace {
bool Check(HRESULT result, const char* operation, std::string* error) {
  if (SUCCEEDED(result)) return true;
  *error = std::string(operation) + " (HRESULT " +
      std::to_string(static_cast<long>(result)) + ")";
  return false;
}
}  // namespace

bool ConfigureTransparentComposition(HWND window, std::string* error) {
  BOOL enabled = FALSE;
  if (!Check(DwmIsCompositionEnabled(&enabled),
             "Не удалось проверить композицию Windows", error)) return false;
  if (!enabled) {
    *error = "Композиция рабочего стола Windows отключена. Прозрачное окно недоступно.";
    return false;
  }

  // Remove native non-client surfaces and animated show/hide snapshots. Flutter
  // paints the rounded, semi-transparent panel itself, not the window manager.
  const MARGINS margins{};
  if (!Check(DwmExtendFrameIntoClientArea(window, &margins),
             "Не удалось сбросить нативную рамку окна", error)) return false;
  const DWMNCRENDERINGPOLICY policy = DWMNCRP_DISABLED;
  if (!Check(DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY,
                                  &policy, sizeof(policy)),
             "Не удалось отключить нативную отрисовку рамки", error)) return false;
  const BOOL disable_transitions = TRUE;
  if (!Check(DwmSetWindowAttribute(window, DWMWA_TRANSITIONS_FORCEDISABLED,
                                  &disable_transitions, sizeof(disable_transitions)),
             "Не удалось отключить анимации окна", error)) return false;

  // Enable alpha AFTER resetting frame attributes. An empty region preserves
  // per-pixel alpha without a blurred/Accent/Mica desktop backdrop surface.
  HRGN region = CreateRectRgn(0, 0, -1, -1);
  if (!region) {
    *error = "Не удалось создать область прозрачности окна.";
    return false;
  }
  DWM_BLURBEHIND blur{};
  blur.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  blur.fEnable = TRUE;
  blur.hRgnBlur = region;
  const HRESULT alpha = DwmEnableBlurBehindWindow(window, &blur);
  DeleteObject(region);
  if (!Check(alpha, "Не удалось включить прозрачную композицию окна", error)) return false;
  return true;
}

void FlushHiddenWindowComposition() {
  // Commit removal of the protected surface before a subsequent show. Do not
  // repaint other applications, clear display affinity or sleep the UI thread.
  const HRESULT result = DwmFlush();
  if (FAILED(result)) {
    std::cerr << "DwmFlush after hide failed: " << static_cast<long>(result) << std::endl;
  }
}
