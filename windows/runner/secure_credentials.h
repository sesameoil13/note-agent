#ifndef RUNNER_SECURE_CREDENTIALS_H_
#define RUNNER_SECURE_CREDENTIALS_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
class SecureCredentials {
 public:
  explicit SecureCredentials(flutter::BinaryMessenger* messenger);
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
