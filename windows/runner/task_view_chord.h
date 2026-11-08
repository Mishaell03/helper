#ifndef RUNNER_TASK_VIEW_CHORD_H_
#define RUNNER_TASK_VIEW_CHORD_H_

// Only tracks Win and Tab, never stores text or unrelated key events.
class TaskViewChord {
 public:
  bool Key(unsigned key, bool down) {
    if (key == 0x5b) left_win_ = down;
    if (key == 0x5c) right_win_ = down;
    if (key != 0x09) return false;
    const bool pressed = down && !tab_;
    tab_ = down;
    return pressed && (left_win_ || right_win_);
  }
 private:
  bool left_win_ = false;
  bool right_win_ = false;
  bool tab_ = false;
};

#endif  // RUNNER_TASK_VIEW_CHORD_H_
