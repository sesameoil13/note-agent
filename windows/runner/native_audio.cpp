#include "native_audio.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <propidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <filesystem>
#include <utility>
#include <vector>

#include "native_paths.h"

// winbase.h maps GetCurrentTime() to GetTickCount(); the Media Engine method
// of the same name must not be rewritten.
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

constexpr long long kMaximumRecordingMs = 600000;  // Ten minutes, as macOS.
constexpr UINT32 kAacBytesPerSecond = 12000;  // 96 kbit/s, the encoder minimum.
constexpr unsigned long long kMaximumSourceBytes = 256ull * 1024 * 1024;
const DWORD kFirstAudio =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
const DWORD kMediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);

const char kDeniedMessage[] =
    "麦克风权限未开启。请在 Windows 设置 → 隐私和安全性 → 麦克风中开启"
    "“麦克风访问权限”和“允许桌面应用访问你的麦克风”，然后重试。";

struct Failure {
  std::string code;
  std::string message;
};

std::string Hex(HRESULT status) {
  char buffer[16];
  snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(status));
  return buffer;
}

const std::string* StringArgument(const EncodableValue* arguments,
                                  const char* name) {
  const auto* values =
      arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!values) return nullptr;
  const auto entry = values->find(EncodableValue(name));
  return entry == values->end() ? nullptr
                                : std::get_if<std::string>(&entry->second);
}

bool HasExtension(const std::filesystem::path& path, const wchar_t* extension) {
  return native_paths::SamePath(path.extension().native(), extension);
}

std::optional<std::wstring> Subdirectory(const wchar_t* name) {
  const auto local = native_paths::LocalDirectory();
  if (!local) return std::nullopt;
  return native_paths::ExistingPath(
      (std::filesystem::path(*local) / name).native(), true);
}

// The microphone's exact capability: <workspace>\recordings\<name>.m4a. The
// file itself may not exist yet; its directory must, without redirection.
std::optional<std::wstring> RecordingPath(const EncodableValue* arguments) {
  const auto* text = StringArgument(arguments, "path");
  const auto wide = text ? native_paths::Utf16(*text) : std::nullopt;
  const auto root = Subdirectory(L"recordings");
  if (!wide || !root) return std::nullopt;
  const std::filesystem::path path(*wide);
  const auto parent = native_paths::ExistingPath(path.parent_path().native(), true);
  const auto name = path.filename().native();
  if (!parent || !native_paths::SamePath(*parent, *root) || name.empty() ||
      name.find_first_of(L"\\/:") != std::wstring::npos ||
      !HasExtension(path, L".m4a")) {
    return std::nullopt;
  }
  const auto exact = (std::filesystem::path(*root) / name).native();
  const auto existing = native_paths::ExistingPath(exact, false);
  if (existing && !native_paths::SamePath(*existing, exact)) return std::nullopt;
  return exact;
}

// Import-only originals (audio-sources\<id>\<file>) or captured recordings.
std::optional<std::wstring> SourcePath(const EncodableValue* arguments) {
  const auto* text = StringArgument(arguments, "path");
  const auto wide = text ? native_paths::Utf16(*text) : std::nullopt;
  if (!wide) return std::nullopt;
  const auto file = native_paths::ExistingPath(*wide, false);
  wchar_t full[MAX_PATH * 4];
  const DWORD length = GetFullPathNameW(wide->c_str(), MAX_PATH * 4, full, nullptr);
  if (!file || length == 0 || length >= MAX_PATH * 4 ||
      !native_paths::SamePath(*file, std::wstring(full, length))) {
    return std::nullopt;  // Missing, or reached through a link.
  }
  const std::filesystem::path path(*file);
  const auto sources = Subdirectory(L"audio-sources");
  const auto recordings = Subdirectory(L"recordings");
  const bool imported =
      sources && native_paths::SamePath(
                     path.parent_path().parent_path().native(), *sources);
  const bool captured =
      recordings &&
      native_paths::SamePath(path.parent_path().native(), *recordings) &&
      HasExtension(path, L".m4a");
  if (!imported && !captured) return std::nullopt;
  return *file;
}

ComPtr<IMFSourceReader> OpenReader(const std::wstring& path) {
  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    return nullptr;
  }
  return reader;
}

std::optional<long long> DurationMs(IMFSourceReader* reader) {
  PROPVARIANT value;
  PropVariantInit(&value);
  if (FAILED(reader->GetPresentationAttribute(kMediaSource, MF_PD_DURATION,
                                              &value))) {
    return std::nullopt;
  }
  const long long duration = value.vt == VT_UI8
                                 ? static_cast<long long>(value.uhVal.QuadPart)
                                 : -1;
  PropVariantClear(&value);
  if (duration <= 0) return std::nullopt;
  return (duration + 5000) / 10000;
}

bool SelectPcmOutput(IMFSourceReader* reader) {
  ComPtr<IMFMediaType> type;
  return SUCCEEDED(MFCreateMediaType(&type)) &&
         SUCCEEDED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio)) &&
         SUCCEEDED(type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM)) &&
         SUCCEEDED(reader->SetStreamSelection(
             static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE)) &&
         SUCCEEDED(reader->SetStreamSelection(kFirstAudio, TRUE)) &&
         SUCCEEDED(reader->SetCurrentMediaType(kFirstAudio, nullptr, type.Get()));
}

// Reads until one decoded buffer with data arrives, from the current position.
bool DecodesAt(IMFSourceReader* reader, std::optional<long long> position) {
  if (position) {
    PROPVARIANT value;
    PropVariantInit(&value);
    value.vt = VT_I8;
    value.hVal.QuadPart = *position;
    const HRESULT moved = reader->SetCurrentPosition(GUID_NULL, value);
    PropVariantClear(&value);
    if (FAILED(moved)) return false;
  }
  for (int attempt = 0; attempt < 64; ++attempt) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(kFirstAudio, 0, nullptr, &flags, &timestamp,
                                  &sample)) ||
        (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM))) {
      return false;
    }
    DWORD bytes = 0;
    if (sample && SUCCEEDED(sample->GetTotalLength(&bytes)) && bytes > 0) {
      return true;
    }
  }
  return false;
}

// Duration of a finalized original that also decodes from its start.
std::optional<long long> InspectRecording(const std::wstring& path) {
  auto reader = OpenReader(path);
  if (!reader) return std::nullopt;
  const auto duration = DurationMs(reader.Get());
  if (!duration || !SelectPcmOutput(reader.Get()) ||
      !DecodesAt(reader.Get(), std::nullopt)) {
    return std::nullopt;
  }
  return duration;
}

std::optional<EncodableMap> InspectSource(const std::wstring& path,
                                          std::string* error) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  LARGE_INTEGER size{};
  unsigned char magic[12] = {};
  DWORD read = 0;
  const bool opened = file != INVALID_HANDLE_VALUE;
  const bool sized = opened && GetFileSizeEx(file, &size) &&
                     size.QuadPart > 0 &&
                     static_cast<unsigned long long>(size.QuadPart) <=
                         kMaximumSourceBytes;
  const bool headed = sized && ReadFile(file, magic, sizeof(magic), &read,
                                        nullptr) && read >= 4;
  if (opened) CloseHandle(file);
  if (!sized) {
    *error = "原件为空或超过本机 256 MB 检查上限，原件已保留。";
    return std::nullopt;
  }
  std::string container;
  if (headed && read >= 8 && std::memcmp(magic + 4, "ftyp", 4) == 0) {
    container = "M4A";
  } else if (headed && read >= 12 && std::memcmp(magic, "RIFF", 4) == 0 &&
             std::memcmp(magic + 8, "WAVE", 4) == 0) {
    container = "WAV";
  } else if (headed && (std::memcmp(magic, "ID3", 3) == 0 ||
                        (magic[0] == 0xFF && (magic[1] & 0xE0) == 0xE0))) {
    container = "MP3";
  } else {
    *error = "没有可识别的音频容器，原件已保留。";
    return std::nullopt;
  }
  auto reader = OpenReader(path);
  ComPtr<IMFMediaType> native;
  GUID subtype = GUID_NULL;
  UINT32 rate = 0;
  UINT32 channels = 0;
  if (!reader ||
      FAILED(reader->GetNativeMediaType(kFirstAudio, 0, &native)) ||
      FAILED(native->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
      FAILED(native->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)) ||
      FAILED(native->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels))) {
    *error = "音频格式信息不完整，原件已保留。";
    return std::nullopt;
  }
  std::string codec;
  if (container == "M4A" && subtype == MFAudioFormat_AAC) {
    codec = "AAC";
  } else if (container == "MP3" && subtype == MFAudioFormat_MP3) {
    codec = "MP3";
  } else if (container == "WAV" && subtype == MFAudioFormat_PCM) {
    codec = "PCM";
  } else {
    *error = "此平台当前支持 AAC / M4A、MP3、PCM / WAV；此原件格式尚不支持。";
    return std::nullopt;
  }
  const auto duration = DurationMs(reader.Get());
  if (!duration || *duration > 86400000LL || rate < 8000 || rate > 384000 ||
      channels < 1 || channels > 32) {
    *error = "音频时长或参数无效，原件已保留。";
    return std::nullopt;
  }
  // Decode bounded windows, including the tail, rather than the whole file.
  const long long total = *duration * 10000;
  if (!SelectPcmOutput(reader.Get()) || !DecodesAt(reader.Get(), 0LL) ||
      !DecodesAt(reader.Get(), total / 2) ||
      !DecodesAt(reader.Get(), std::max(0LL, total - 5000000LL))) {
    *error = "音频数据无法解码，原件可能不完整。";
    return std::nullopt;
  }
  return EncodableMap{
      {EncodableValue("container"), EncodableValue(container)},
      {EncodableValue("codec"), EncodableValue(codec)},
      {EncodableValue("durationMs"), EncodableValue(static_cast<int64_t>(*duration))},
      {EncodableValue("sampleRate"), EncodableValue(static_cast<int32_t>(rate))},
      {EncodableValue("channels"), EncodableValue(static_cast<int32_t>(channels))},
  };
}

std::wstring JournalPath(const std::wstring& original) {
  return original + L".done";
}

// Converts device frames (float32 / PCM16 / PCM32, any channel count) to mono
// PCM16 at an AAC-encodable rate, with linear resampling where needed.
class MonoConverter {
 public:
  MonoConverter(UINT32 rate, UINT32 channels, UINT32 bits, bool is_float,
                UINT32 target)
      : channels_(channels),
        bits_(bits),
        float_(is_float),
        step_(static_cast<double>(rate) / static_cast<double>(target)) {}

  // Appends converted samples to |output|; returns the input RMS level.
  double Convert(const BYTE* data, DWORD bytes, std::vector<int16_t>* output) {
    const size_t sample_bytes = bits_ / 8;
    const size_t frame_bytes = sample_bytes * channels_;
    if (frame_bytes == 0) return 0;
    const size_t frames = bytes / frame_bytes;
    double squares = 0;
    for (size_t frame = 0; frame < frames; ++frame) {
      double mono = 0;
      for (UINT32 channel = 0; channel < channels_; ++channel) {
        const BYTE* at = data + frame * frame_bytes + channel * sample_bytes;
        mono += Sample(at);
      }
      mono /= channels_;
      squares += mono * mono;
      const double index = static_cast<double>(input_index_);
      while (next_ <= index) {
        const double fraction = next_ - (index - 1.0);
        const double value = previous_ + (mono - previous_) * fraction;
        const double clamped = std::clamp(value, -1.0, 1.0);
        output->push_back(static_cast<int16_t>(std::lround(clamped * 32767.0)));
        next_ += step_;
      }
      previous_ = mono;
      ++input_index_;
    }
    return frames == 0 ? 0 : std::sqrt(squares / static_cast<double>(frames));
  }

 private:
  double Sample(const BYTE* at) const {
    if (float_) {
      float value;
      std::memcpy(&value, at, sizeof(value));
      return std::isfinite(value) ? static_cast<double>(value) : 0.0;
    }
    if (bits_ == 16) {
      int16_t value;
      std::memcpy(&value, at, sizeof(value));
      return value / 32768.0;
    }
    int32_t value;
    std::memcpy(&value, at, sizeof(value));
    return value / 2147483648.0;
  }

  UINT32 channels_;
  UINT32 bits_;
  bool float_;
  double step_;
  double next_ = 0;
  double previous_ = 0;
  long long input_index_ = 0;
};

}  // namespace

struct StartSignal {
  std::mutex mutex;
  std::condition_variable changed;
  bool done = false;
  std::optional<Failure> failure;
};

// Media Engine event sink; called on Media Foundation work-queue threads.
class PlaybackNotify : public IMFMediaEngineNotify {
 public:
  STDMETHODIMP QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    if (id == __uuidof(IUnknown) || id == __uuidof(IMFMediaEngineNotify)) {
      *object = static_cast<IMFMediaEngineNotify*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++references_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG remaining = --references_;
    if (remaining == 0) delete this;
    return remaining;
  }
  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR, DWORD) override {
    if (event == MF_MEDIA_ENGINE_EVENT_ENDED) ended = true;
    if (event == MF_MEDIA_ENGINE_EVENT_ERROR) failed = true;
    return S_OK;
  }
  std::atomic<bool> ended{false};
  std::atomic<bool> failed{false};

 private:
  std::atomic<ULONG> references_{1};
};

NativeAudio::NativeAudio(flutter::BinaryMessenger* messenger) {
  media_foundation_ = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_FULL));
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dev.noteagent/audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

NativeAudio::~NativeAudio() {
  channel_->SetMethodCallHandler(nullptr);
  FinishForExit();
  if (media_foundation_) MFShutdown();
}

void NativeAudio::FinishForExit() {
  // Closing the window or ending the session finalizes the container, so the
  // next launch recovers a complete original under the same identity.
  FinishRecording();
  StopPlayback();
}

void NativeAudio::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const auto& method = call.method_name();
  if (!media_foundation_) {
    result->Error("audio", "Windows 媒体组件不可用，无法录音或回放。");
    return;
  }
  if (method == "startRecording") {
    const auto path = RecordingPath(call.arguments());
    if (!path) {
      result->Error("audio", "原音频必须位于本机录音目录。");
      return;
    }
    StartRecording(*path, std::move(result));
  } else if (method == "pauseRecording") {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == "recording") {
      paused_ = true;
      phase_ = "paused";
      level_ = 0;
    }
    result->Success();
  } else if (method == "resumeRecording") {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == "paused") {
      paused_ = false;
      phase_ = "recording";
    }
    result->Success();
  } else if (method == "recordingSnapshot") {
    result->Success(Snapshot());
  } else if (method == "stopRecording") {
    FinishRecording();
    result->Success(Snapshot());
  } else if (method == "recoverRecording") {
    // Recording never outlives this process on Windows; only a container the
    // recorder finalized itself (window close, session end) is trusted.
    const auto path = RecordingPath(call.arguments());
    const auto journal = path ? native_paths::ReadSmallFile(JournalPath(*path), 64)
                              : std::nullopt;
    const auto duration = journal ? InspectRecording(*path) : std::nullopt;
    if (!duration) {
      result->Success();
      return;
    }
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("phase"), EncodableValue("stopped")},
        {EncodableValue("durationMs"),
         EncodableValue(static_cast<int64_t>(*duration))},
    }));
  } else if (method == "inspectRecording") {
    const auto path = RecordingPath(call.arguments());
    const auto duration = path ? InspectRecording(*path) : std::nullopt;
    if (!duration) {
      result->Error("audio", "原音频尚不可回放，现有文件已保留。");
      return;
    }
    result->Success(EncodableValue(static_cast<int64_t>(*duration)));
  } else if (method == "inspectAudioSource") {
    const auto path = SourcePath(call.arguments());
    if (!path) {
      result->Error("audio_inspection",
                    "音频检查仅允许本机私有来源目录内的完整原件。");
      return;
    }
    std::string error;
    const auto metadata = InspectSource(*path, &error);
    if (!metadata) {
      result->Error("audio_inspection", error);
      return;
    }
    result->Success(EncodableValue(*metadata));
  } else if (method == "play" || method == "playAudioSource") {
    const bool original = method == "play";
    const auto path = original ? RecordingPath(call.arguments())
                               : SourcePath(call.arguments());
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (phase_ != "stopped") {
        result->Error("audio", "请先结束录音再回放。");
        return;
      }
    }
    std::string error = original ? "无法回放此原音频，文件仍保留在本机。"
                                 : "无法回放此原音频，原件已保留。";
    if (!path || !Play(*path, &error)) {
      result->Error("audio", error);
      return;
    }
    result->Success();
  } else if (method == "stopPlayback") {
    StopPlayback();
    result->Success();
  } else if (method == "playbackSnapshot") {
    const bool playing = engine_ && notify_ && !notify_->ended &&
                         !notify_->failed && !engine_->IsPaused() &&
                         !engine_->IsEnded();
    const double seconds = engine_ ? engine_->GetCurrentTime() : 0.0;
    const auto position = static_cast<int64_t>(
        std::llround(std::isfinite(seconds) ? seconds * 1000.0 : 0.0));
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("isPlaying"), EncodableValue(playing)},
        {EncodableValue("positionMs"), EncodableValue(position)},
    }));
  } else {
    result->NotImplemented();
  }
}

void NativeAudio::StartRecording(const std::wstring& path,
                                 std::unique_ptr<Result> result) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ != "stopped") {
      result->Error("audio", "请先结束当前录音。");
      return;
    }
  }
  if (worker_.joinable()) worker_.join();  // A finished (capped/failed) run.
  if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    result->Error("audio", "此录音原文件已存在，请重新开始。");
    return;
  }
  StopPlayback();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    duration_ms_ = 0;
    level_ = 0;
    error_.reset();
  }
  paused_ = false;
  stop_requested_ = false;
  auto start = std::make_shared<StartSignal>();
  worker_ = std::thread(&NativeAudio::CaptureLoop, this, path, start);
  std::unique_lock<std::mutex> lock(start->mutex);
  // Opening the device and reading its first buffer proves access; Windows
  // privacy settings deny desktop apps there rather than with a prompt.
  if (!start->changed.wait_for(lock, std::chrono::seconds(10),
                               [&] { return start->done; })) {
    lock.unlock();
    stop_requested_ = true;
    worker_.join();
    result->Error("microphone_unavailable",
                  "麦克风没有响应，请检查输入设备后重试。");
    return;
  }
  if (start->failure) {
    const auto failure = *start->failure;
    lock.unlock();
    worker_.join();
    result->Error(failure.code, failure.message);
    return;
  }
  result->Success();
}

void NativeAudio::FinishRecording() {
  stop_requested_ = true;
  if (worker_.joinable()) worker_.join();
}

EncodableValue NativeAudio::Snapshot() {
  std::lock_guard<std::mutex> lock(mutex_);
  EncodableMap value = {
      {EncodableValue("phase"), EncodableValue(phase_)},
      {EncodableValue("durationMs"),
       EncodableValue(static_cast<int64_t>(duration_ms_))},
      {EncodableValue("level"),
       EncodableValue(phase_ == "recording" ? level_ : 0.0)},
  };
  if (error_) value[EncodableValue("error")] = EncodableValue(*error_);
  return EncodableValue(value);
}

void NativeAudio::CaptureLoop(std::wstring path,
                              std::shared_ptr<StartSignal> start) {
  const HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool started = false;
  auto signal = [&](std::optional<Failure> failure) {
    std::lock_guard<std::mutex> lock(start->mutex);
    start->failure = std::move(failure);
    start->done = true;
    start->changed.notify_all();
  };
  auto device_failure = [&](HRESULT status) {
    if (status == E_ACCESSDENIED) {
      return Failure{"microphone_denied", kDeniedMessage};
    }
    return Failure{"microphone_unavailable",
                   "未找到可用的麦克风或无法打开输入设备，请检查设备后重试。（" +
                       Hex(status) + "）"};
  };

  ComPtr<IMFAttributes> device_attributes;
  ComPtr<IMFMediaSource> source;
  ComPtr<IMFSourceReader> reader;
  ComPtr<IMFMediaType> request;
  ComPtr<IMFMediaType> current;
  HRESULT status = MFCreateAttributes(&device_attributes, 2);
  if (SUCCEEDED(status)) {
    status = device_attributes->SetGUID(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID);
  }
  if (SUCCEEDED(status)) {
    // The default communications-agnostic input chosen in Windows Sound.
    status = device_attributes->SetUINT32(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ROLE, eConsole);
  }
  if (SUCCEEDED(status)) {
    status = MFCreateDeviceSource(device_attributes.Get(), &source);
  }
  if (SUCCEEDED(status)) {
    status = MFCreateSourceReaderFromMediaSource(source.Get(), nullptr, &reader);
  }
  for (const GUID& subtype : {MFAudioFormat_Float, MFAudioFormat_PCM}) {
    if (FAILED(status)) break;
    request.Reset();
    HRESULT chosen = MFCreateMediaType(&request);
    if (SUCCEEDED(chosen)) chosen = request->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(chosen)) chosen = request->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(chosen)) {
      chosen = reader->SetCurrentMediaType(kFirstAudio, nullptr, request.Get());
    }
    if (SUCCEEDED(chosen)) break;
    if (subtype == MFAudioFormat_PCM) status = chosen;
  }
  GUID subtype = GUID_NULL;
  UINT32 rate = 0;
  UINT32 channels = 0;
  UINT32 bits = 0;
  if (SUCCEEDED(status)) status = reader->GetCurrentMediaType(kFirstAudio, &current);
  if (SUCCEEDED(status)) status = current->GetGUID(MF_MT_SUBTYPE, &subtype);
  if (SUCCEEDED(status)) status = current->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
  if (SUCCEEDED(status)) status = current->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
  if (SUCCEEDED(status)) status = current->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits);
  const bool is_float = subtype == MFAudioFormat_Float;
  const bool supported = rate >= 8000 && channels >= 1 && channels <= 32 &&
                         ((is_float && bits == 32) ||
                          (subtype == MFAudioFormat_PCM &&
                           (bits == 16 || bits == 32)));
  if (SUCCEEDED(status) && !supported) status = MF_E_INVALIDMEDIATYPE;

  // The first buffer proves the OS granted access before any file exists.
  ComPtr<IMFSample> first;
  for (int attempt = 0; SUCCEEDED(status) && !first && attempt < 200; ++attempt) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    status = reader->ReadSample(kFirstAudio, 0, nullptr, &flags, &timestamp, &first);
    if (SUCCEEDED(status) &&
        (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM))) {
      status = MF_E_END_OF_STREAM;
    }
  }
  if (SUCCEEDED(status) && !first) status = MF_E_END_OF_STREAM;

  // Encoder: mono AAC-LC at 44.1/48 kHz; other device rates are resampled.
  const UINT32 target = rate == 44100 || rate == 48000 ? rate : 48000;
  ComPtr<IMFByteStream> stream;
  ComPtr<IMFAttributes> writer_attributes;
  ComPtr<IMFSinkWriter> writer;
  ComPtr<IMFMediaType> output;
  ComPtr<IMFMediaType> input;
  DWORD writer_stream = 0;
  bool file_created = false;
  if (FAILED(status)) {
    signal(device_failure(status));
  } else {
    status = MFCreateFile(MF_ACCESSMODE_READWRITE, MF_OPENMODE_FAIL_IF_EXIST,
                          MF_FILEFLAGS_NONE, path.c_str(), &stream);
    file_created = SUCCEEDED(status);
    if (SUCCEEDED(status)) status = MFCreateAttributes(&writer_attributes, 2);
    if (SUCCEEDED(status)) {
      status = writer_attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                                          MFTranscodeContainerType_MPEG4);
    }
    if (SUCCEEDED(status)) {
      status = writer_attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    }
    if (SUCCEEDED(status)) {
      status = MFCreateSinkWriterFromURL(L".m4a", stream.Get(),
                                         writer_attributes.Get(), &writer);
    }
    if (SUCCEEDED(status)) status = MFCreateMediaType(&output);
    if (SUCCEEDED(status)) status = output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(status)) status = output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    if (SUCCEEDED(status)) status = output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(status)) status = output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, target);
    if (SUCCEEDED(status)) status = output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
    if (SUCCEEDED(status)) {
      status = output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAacBytesPerSecond);
    }
    if (SUCCEEDED(status)) {
      status = output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
    }
    if (SUCCEEDED(status)) status = writer->AddStream(output.Get(), &writer_stream);
    if (SUCCEEDED(status)) status = MFCreateMediaType(&input);
    if (SUCCEEDED(status)) status = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(status)) status = input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    if (SUCCEEDED(status)) status = input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(status)) status = input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, target);
    if (SUCCEEDED(status)) status = input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
    if (SUCCEEDED(status)) status = input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 2);
    if (SUCCEEDED(status)) {
      status = input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, target * 2);
    }
    if (SUCCEEDED(status)) {
      status = writer->SetInputMediaType(writer_stream, input.Get(), nullptr);
    }
    if (SUCCEEDED(status)) status = writer->BeginWriting();
    if (FAILED(status)) {
      writer.Reset();
      if (stream) stream->Close();
      stream.Reset();
      if (file_created) DeleteFileW(path.c_str());
      signal(Failure{"audio", "无法启动 Windows 音频编码，请重试。（" +
                                  Hex(status) + "）"});
    } else {
      started = true;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        phase_ = "recording";
      }
      signal(std::nullopt);
    }
  }

  if (started) {
    MonoConverter converter(rate, channels, bits, is_float, target);
    const long long maximum_frames = kMaximumRecordingMs * target / 1000;
    long long written = 0;
    std::optional<std::string> failure;
    std::vector<int16_t> converted;
    ComPtr<IMFSample> sample = first;
    while (!stop_requested_ && written < maximum_frames) {
      if (!sample) {
        DWORD flags = 0;
        LONGLONG timestamp = 0;
        status = reader->ReadSample(kFirstAudio, 0, nullptr, &flags, &timestamp,
                                    &sample);
        if (FAILED(status) || (flags & (MF_SOURCE_READERF_ERROR |
                                        MF_SOURCE_READERF_ENDOFSTREAM))) {
          failure = "录音设备中断，现有原文件已保留，请回放核对。";
          break;
        }
        if (!sample) continue;
      }
      ComPtr<IMFMediaBuffer> buffer;
      BYTE* data = nullptr;
      DWORD length = 0;
      converted.clear();
      double level = 0;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer)) &&
          SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
        // Paused audio is read and discarded so the device stays open and
        // time freezes; samples are re-timed from the written frame count.
        if (!paused_) level = converter.Convert(data, length, &converted);
        buffer->Unlock();
      }
      sample.Reset();
      const long long room = maximum_frames - written;
      if (static_cast<long long>(converted.size()) > room) {
        converted.resize(static_cast<size_t>(room));
      }
      if (!converted.empty()) {
        const DWORD bytes = static_cast<DWORD>(converted.size() * sizeof(int16_t));
        ComPtr<IMFMediaBuffer> pcm;
        ComPtr<IMFSample> encoded;
        BYTE* target_data = nullptr;
        HRESULT write = MFCreateMemoryBuffer(bytes, &pcm);
        if (SUCCEEDED(write)) write = pcm->Lock(&target_data, nullptr, nullptr);
        if (SUCCEEDED(write)) {
          std::memcpy(target_data, converted.data(), bytes);
          pcm->Unlock();
          write = pcm->SetCurrentLength(bytes);
        }
        if (SUCCEEDED(write)) write = MFCreateSample(&encoded);
        if (SUCCEEDED(write)) write = encoded->AddBuffer(pcm.Get());
        const long long frames = static_cast<long long>(converted.size());
        if (SUCCEEDED(write)) write = encoded->SetSampleTime(written * 10000000LL / target);
        if (SUCCEEDED(write)) {
          write = encoded->SetSampleDuration(
              (written + frames) * 10000000LL / target -
              written * 10000000LL / target);
        }
        if (SUCCEEDED(write)) write = writer->WriteSample(writer_stream, encoded.Get());
        if (FAILED(write)) {
          failure = "音频编码未完成，现有原文件已保留。（" + Hex(write) + "）";
          break;
        }
        written += frames;
      }
      std::lock_guard<std::mutex> lock(mutex_);
      duration_ms_ = written * 1000 / target;
      if (!paused_) level_ = std::min(1.0, level);
    }
    // Finalize writes the MP4 index; without it the original is interrupted.
    const HRESULT finalized = writer->Finalize();
    writer.Reset();
    if (stream) stream->Close();
    stream.Reset();
    if (FAILED(finalized) && !failure) {
      failure = "音频编码未完成，现有原文件已保留。（" + Hex(finalized) + "）";
    }
    if (!failure && written > 0) {
      native_paths::ReplaceFileDurably(
          JournalPath(path),
          "durationMs=" + std::to_string(written * 1000 / target) + "\n");
    }
    std::lock_guard<std::mutex> lock(mutex_);
    duration_ms_ = written * 1000 / target;
    level_ = 0;
    phase_ = "stopped";
    if (failure) error_ = failure;
  }
  reader.Reset();
  if (source) source->Shutdown();
  source.Reset();
  if (SUCCEEDED(apartment)) CoUninitialize();
}

bool NativeAudio::Play(const std::wstring& path, std::string* error) {
  StopPlayback();
  if (!InspectRecording(path)) return false;
  ComPtr<IMFMediaEngineClassFactory> factory;
  ComPtr<IMFAttributes> attributes;
  ComPtr<IMFMediaEngine> engine;
  ComPtr<IMFMediaEngineEx> extended;
  ComPtr<IMFByteStream> stream;
  auto* notify = new PlaybackNotify();
  HRESULT status = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (SUCCEEDED(status)) status = MFCreateAttributes(&attributes, 1);
  if (SUCCEEDED(status)) status = attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify);
  if (SUCCEEDED(status)) {
    status = factory->CreateInstance(MF_MEDIA_ENGINE_AUDIOONLY, attributes.Get(),
                                     &engine);
  }
  if (SUCCEEDED(status)) status = engine.As(&extended);
  if (SUCCEEDED(status)) {
    status = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                          MF_FILEFLAGS_NONE, path.c_str(), &stream);
  }
  if (SUCCEEDED(status)) {
    BSTR url = SysAllocString(path.c_str());
    status = url ? extended->SetSourceFromByteStream(stream.Get(), url)
                 : E_OUTOFMEMORY;
    SysFreeString(url);
  }
  if (SUCCEEDED(status)) status = engine->Play();
  if (FAILED(status)) {
    if (engine) engine->Shutdown();
    notify->Release();
    *error += "（" + Hex(status) + "）";
    return false;
  }
  engine_ = engine.Detach();
  notify_ = notify;
  return true;
}

void NativeAudio::StopPlayback() {
  if (engine_) {
    engine_->Pause();
    engine_->Shutdown();
    engine_->Release();
    engine_ = nullptr;
  }
  if (notify_) {
    notify_->Release();
    notify_ = nullptr;
  }
}
