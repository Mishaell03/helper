#include "../../windows/runner/task_view_chord.h"

#include <cassert>
#include <iostream>

int main() {
  TaskViewChord chord;
  assert(!chord.Key(0x09, true));  // Tab without Win.
  assert(!chord.Key(0x09, false));
  assert(!chord.Key(0x5b, true));
  assert(!chord.Key('A', true));  // Not a general keyboard recorder.
  assert(chord.Key(0x09, true));
  assert(!chord.Key(0x09, true)); // Auto-repeat must not repeat Hide/Pause.
  assert(!chord.Key(0x09, false));
  assert(chord.Key(0x09, true));
  assert(!chord.Key(0x09, false));
  assert(!chord.Key(0x5b, false));
  assert(!chord.Key(0x09, true));
  assert(!chord.Key(0x09, false));
  assert(!chord.Key(0x5c, true));
  assert(chord.Key(0x09, true)); // Right Win is supported too.
  assert(!chord.Key(0x09, false));
  assert(!chord.Key(0x5c, false));
  assert(!chord.Key(0x09, true));
  std::cout << "PASS: left/right Win+Tab, repeat suppression, unrelated keys\n";
}
