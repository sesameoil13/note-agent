#ifndef RUNNER_NATIVE_AUDIO_H_
#define RUNNER_NATIVE_AUDIO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

struct IMFMediaEngine;
struct StartSignal;
class PlaybackNotify;

// Windows microphone/player boundary on channel dev.noteagent/audio. Captures
// the default input through Media Foundation into a private AAC/M4A original;
// nothing is uploaded and no AI is invoked here.
class NativeAudio {
 public:
  explicit NativeAudio(flutter::BinaryMessenger* messenger);
  ~NativeAudio();

  NativeAudio(const NativeAudio&) = delete;
  NativeAudio& operator=(const NativeAudio&) = delete;

  // Finalizes any capture and stops playback before the process may end.
  void FinishForExit();

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);
  void StartRecording(const std::wstring& path, std::unique_ptr<Result> result);
  void FinishRecording();
  flutter::EncodableValue Snapshot();
  void CaptureLoop(std::wstring path, std::shared_ptr<StartSignal> start);
  bool Play(const std::wstring& path, std::string* error);
  void StopPlayback();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool media_foundation_ = false;

  // Capture state shared with the worker thread.
  std::mutex mutex_;
  std::thread worker_;
  std::atomic<bool> paused_{false};
  std::atomic<bool> stop_requested_{false};
  std::string phase_ = "stopped";
  long long duration_ms_ = 0;
  double level_ = 0;
  std::optional<std::string> error_;

  // Playback (platform thread only).
  IMFMediaEngine* engine_ = nullptr;
  PlaybackNotify* notify_ = nullptr;
};

#endif  // RUNNER_NATIVE_AUDIO_H_
