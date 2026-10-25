#ifndef RUNNER_NATIVE_NOTIFICATIONS_H_
#define RUNNER_NATIVE_NOTIFICATIONS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Windows toast boundary on channel dev.noteagent/notifications, matching the
// macOS/Android NotificationPort + NotificationInteractionPort contract.
// Scheduling confirms that Windows accepted a toast, never that it was seen.
class NativeNotifications {
 public:
  // Registers the per-user app identity and toast activator. Must run on the
  // UI thread before any window exists, including launches made by Windows
  // for a toast button while the App was closed.
  static void PrepareProcess();
  static void ReleaseProcess();
  // True when Windows started this process only to deliver a toast action.
  static bool LaunchedForToast(const wchar_t* command_line);

  NativeNotifications(flutter::BinaryMessenger* messenger, HWND window);
  ~NativeNotifications();

  NativeNotifications(const NativeNotifications&) = delete;
  NativeNotifications& operator=(const NativeNotifications&) = delete;

  // Handles toast-activation, wake and network-return window messages.
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);
  void Notify(const char* method);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HANDLE network_hint_ = nullptr;
};

#endif  // RUNNER_NATIVE_NOTIFICATIONS_H_
