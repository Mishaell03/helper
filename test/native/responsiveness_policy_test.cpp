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
  std::cout << "PASS: watchdog startup grace, hidden state, Dart/native stalls, monotonic bounds\n";
}
