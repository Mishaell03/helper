#include "../../windows/runner/typing_cadence.h"

#include <cassert>
#include <iostream>
#include <set>

int main() {
  for (const uint32_t cpm : {300u, 1000u, 2000u}) {
    TypingCadence cadence(42);
    std::set<uint32_t> delays;
    bool faster = false;
    bool slower = false;
    bool pause = false;
    for (int i = 0; i < 10000; ++i) {
      const auto delay = cadence.Next(cpm, L'a');
      assert(delay >= 15 && delay <= 1500);
      delays.insert(delay);
      faster |= delay < 60000u / cpm;
      slower |= delay > 60000u / cpm;
      pause |= delay > 2 * (60000u / cpm);
    }
    assert(delays.size() > 20 && faster && slower && pause);
    for (const wchar_t punctuation : {L',', L'.', L'!', L'?', L'\n'}) {
      TypingCadence plain(17), punctuated(17);
      assert(punctuated.Next(cpm, punctuation) > plain.Next(cpm, L'a'));
    }
    cadence.Reset();
    assert(cadence.Next(cpm) >= 15);
  }
  std::cout << "PASS: variable cadence, faster/slower bursts, pauses, punctuation, bounds\n";
}
