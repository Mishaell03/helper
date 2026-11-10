#include "../../windows/runner/slot_navigation_policy.h"

#include <cassert>
#include <iostream>

int main() {
  SlotNavigationPolicy policy;
  assert(!policy.enabled(false, false));
  assert(policy.enabled(true, false));
  policy.Show(false);
  policy.Toggle(true, false);
  assert(!policy.enabled(true, false));
  policy.Toggle(true, false);
  assert(policy.enabled(true, false));
  policy.Hide();
  assert(!policy.enabled(false, false));
  policy.Toggle(false, false);
  assert(policy.enabled(false, false));
  policy.Toggle(false, false);
  assert(!policy.enabled(false, false));

  // Normal show resets overrides, but the countdown reveal must not call Show.
  policy.Toggle(false, false);
  policy.Show(false);
  assert(policy.enabled(true, false));
  policy.Disable(); // F6: release before asking Dart to load the selected text.
  assert(!policy.enabled(true, false));
  assert(!policy.enabled(false, false));
  for (int phase = 0; phase < 3; ++phase) { // Countdown, typing and paused.
    policy.Toggle(true, true);
    assert(!policy.enabled(true, true));
    policy.Show(true);
    assert(!policy.enabled(true, true));
    assert(!policy.enabled(true, false)); // No latent enable after completion.
  }
  assert(!policy.enabled(true, false));
  policy.Toggle(true, false);
  assert(policy.enabled(true, false));
  policy.Disable(); // Emergency stop, even without an active insertion.
  assert(!policy.enabled(true, false));
  policy.Hide();
  policy.Show(false);
  assert(policy.enabled(true, false));

  for (int cycle = 0; cycle < 100; ++cycle) {
    policy.Toggle(true, false);
    assert(!policy.enabled(true, false));
    policy.Hide();
    assert(!policy.enabled(false, false));
    policy.Toggle(false, false);
    assert(policy.enabled(false, false));
    policy.Disable();
    assert(!policy.enabled(false, false));
    policy.Show(false);
    assert(policy.enabled(true, false));
  }
  std::cout << "PASS: visibility, F3 overrides, insertion latch, stop and repeated cycles\n";
}
