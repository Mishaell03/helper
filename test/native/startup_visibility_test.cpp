#include "../../windows/runner/startup_visibility.h"

#include <cassert>
#include <iostream>

int main() {
  StartupVisibility background(true);
  assert(!background.may_show());
  assert(!background.FinishStartup());
  assert(!background.may_show());
  background.Reveal();  // Explicit global toggle.
  assert(background.may_show());
  background.Hide();
  assert(!background.may_show());
  assert(!background.FinishStartup());

  StartupVisibility normal(false);
  assert(!normal.may_show());
  assert(normal.FinishStartup());
  assert(normal.may_show());
  normal.Hide();
  assert(!normal.FinishStartup());
  assert(!normal.may_show());

  // Startup finishing after an early hotkey must neither show nor hide again.
  for (const bool hidden : {true, false}) {
    StartupVisibility early_show(hidden);
    early_show.Reveal();
    assert(!early_show.FinishStartup());
    assert(early_show.may_show());
    StartupVisibility early_hide(hidden);
    early_hide.Reveal();
    early_hide.Hide();
    assert(!early_hide.FinishStartup());
    assert(!early_hide.may_show());
  }
  std::cout << "PASS: hidden autostart, normal launch, explicit reveal, startup/hotkey races\n";
}
