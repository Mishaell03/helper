#ifndef RUNNER_TYPING_CADENCE_H_
#define RUNNER_TYPING_CADENCE_H_

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>

// Timing only: never sleeps or queues input. The Windows message loop remains
// available for emergency Stop, focus checks and application hotkeys.
class TypingCadence {
 public:
  explicit TypingCadence(uint32_t seed) : random_(seed) {}

  void Reset() { burst_remaining_ = 0; }

  uint32_t Next(uint32_t cpm, wchar_t previous = 0) {
    if (burst_remaining_ == 0) {
      burst_remaining_ = std::uniform_int_distribution<int>(8, 24)(random_);
      burst_pace_ = Between(0.65, 1.25);
    }
    --burst_remaining_;
    double delay = 60000.0 / std::max(uint32_t{1}, cpm) *
        burst_pace_ * Between(0.65, 1.35);
    if (std::uniform_int_distribution<int>(0, 99)(random_) < 5) {
      delay += 60000.0 / std::max(uint32_t{1}, cpm) * Between(2.0, 5.0);
    }
    if (previous == L'\r' || previous == L'\n') {
      delay += Between(180.0, 650.0);
    } else if (previous == L'.' || previous == L'!' || previous == L'?' ||
               previous == L'\x2026') {
      delay += Between(100.0, 400.0);
    } else if (previous == L',' || previous == L';' || previous == L':') {
      delay += Between(40.0, 160.0);
    }
    return static_cast<uint32_t>(std::clamp(std::lround(delay), 15L, 1500L));
  }

 private:
  double Between(double min, double max) {
    return std::uniform_real_distribution<double>(min, max)(random_);
  }
  std::mt19937 random_;
  int burst_remaining_ = 0;
  double burst_pace_ = 1.0;
};

#endif  // RUNNER_TYPING_CADENCE_H_
