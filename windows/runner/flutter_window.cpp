#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  secure_credentials_ = std::make_unique<SecureCredentials>(flutter_controller_->engine()->messenger());
  workspace_platform_ = std::make_unique<WorkspacePlatform>(
      flutter_controller_->engine()->messenger(), GetHandle());
  native_audio_ = std::make_unique<NativeAudio>(
      flutter_controller_->engine()->messenger());
  native_notifications_ = std::make_unique<NativeNotifications>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  native_audio_.reset();  // Finalizes an in-progress recording.
  native_notifications_.reset();
  secure_credentials_.reset();
  workspace_platform_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (native_notifications_) {
    if (const auto handled =
            native_notifications_->HandleMessage(message, wparam, lparam)) {
      return *handled;
    }
  }

  switch (message) {
    case WM_ENDSESSION:
      // Sign-out/shutdown may end the process without destroying the window.
      if (wparam && native_audio_) native_audio_->FinishForExit();
      break;
    case WM_GETMINMAXINFO: {
      auto* size = reinterpret_cast<MINMAXINFO*>(lparam);
      size->ptMinTrackSize = {640, 640};
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
