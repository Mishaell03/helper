#ifndef RUNNER_TASK_VIEW_GUARD_H_
#define RUNNER_TASK_VIEW_GUARD_H_

#include <windows.h>
#include <functional>
#include "task_view_chord.h"

class TaskViewGuard {
 public:
  explicit TaskViewGuard(std::function<void()> before_task_view);
  ~TaskViewGuard();
  bool active() const { return hook_ != nullptr; }
  // Used only when automation already swallowed the physical Win key down.
  // Hide first, then deliver one complete Win+Tab chord after input is unblocked.
  void ReplaySuppressedChord(UINT win_key);

 private:
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam);
  static TaskViewGuard* instance_;
  HHOOK hook_ = nullptr;
  std::function<void()> before_task_view_;
  TaskViewChord chord_;
  bool swallow_tab_up_ = false;
  UINT swallow_win_up_ = 0;
};

#endif  // RUNNER_TASK_VIEW_GUARD_H_
