#ifndef RUNNER_WORKSPACE_PLATFORM_H_
#define RUNNER_WORKSPACE_PLATFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Windows directory selection/persistence and external application boundary.
class WorkspacePlatform {
 public:
  WorkspacePlatform(flutter::BinaryMessenger* messenger, HWND window);
  ~WorkspacePlatform();

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<Result> result);
  void RestoreLocation(std::unique_ptr<Result> result);
  void ChooseLocation(std::unique_ptr<Result> result);
  void ChooseFolder(const flutter::EncodableValue* arguments,
                    std::unique_ptr<Result> result);
  void ChooseSourceFile(const flutter::EncodableValue* arguments, std::unique_ptr<Result> result);
  void RevealLocalSource(const flutter::EncodableValue* arguments,
                         std::unique_ptr<Result> result);
  void OpenInObsidian(const flutter::EncodableValue* arguments,
                      std::unique_ptr<Result> result);

  HWND window_;
  std::wstring vault_directory_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WORKSPACE_PLATFORM_H_
