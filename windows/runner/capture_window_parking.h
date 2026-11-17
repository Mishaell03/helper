#ifndef RUNNER_CAPTURE_WINDOW_PARKING_H_
#define RUNNER_CAPTURE_WINDOW_PARKING_H_

#include <windows.h>

// Keep WS_VISIBLE / display affinity intact while placing a hidden panel wholly
// outside the virtual desktop. No opacity tricks and no protection reset.
class CaptureWindowParking {
 public:
  bool Park(HWND window);
  bool Restore(HWND window);
  bool parked() const { return parked_; }
  // A notification can replace/resize its frame while parked. Its next reveal
  // must use the new logical bounds, never persist the off-screen coordinates.
  void SetRestoreBounds(const RECT& bounds) { if (parked_) restore_ = bounds; }
  void ConstrainPosition(WINDOWPOS* position) const;
  void Repark(HWND window) const;

 private:
  RECT restore_{};
  bool parked_ = false;
};

#endif  // RUNNER_CAPTURE_WINDOW_PARKING_H_
