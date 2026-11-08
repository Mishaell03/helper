#include "../../windows/runner/responsiveness_policy.h"

#include <cassert>
#include <iostream>

int main() {
  assert(!ResponsivenessTimedOut(10000, 0, 0, false, true)); // Cold startup.
  assert(!ResponsivenessTimedOut(10000, 0, 0, true, false)); // Already hidden.
  assert(!ResponsivenessTimedOut(10000, 9500, 9000, true, true));
  assert(!ResponsivenessTimedOut(10000, 4000, 4000, true, true));
  assert(ResponsivenessTimedOut(10001, 10000, 4000, true, true)); // Dart hung.
  assert(ResponsivenessTimedOut(10001, 4000, 10000, true, true)); // Native hung.
  assert(!ResponsivenessTimedOut(100, 200, 200, true, true)); // No unsigned underflow.
  // Holding a resize border/dialog for longer than the timeout is not a hang
  // while User32 continues dispatching native timer callbacks.
  assert(!ResponsivenessTimedOut(30000, 29900, 1000, true, true, true));
  assert(ResponsivenessTimedOut(30000, 1000, 29900, true, true, true));
  assert(ResponsivenessTimedOut(30000, 1000, 1000, true, true, true));
  // On modal-loop exit Dart gets a fresh grace period, not a permanent bypass.
  assert(!ResponsivenessTimedOut(30000, 30000, 30000, true, true));
  assert(ResponsivenessTimedOut(36001, 36000, 30000, true, true));
  std::cout << "PASS: watchdog startup grace, hidden state, Dart/native stalls, modal resize/dialog, monotonic bounds\n";
}
