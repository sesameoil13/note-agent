import AVFoundation
import Cocoa
import AudioToolbox
#if canImport(FlutterMacOS)
import FlutterMacOS

/// macOS microphone/player system boundary. Originals never leave this device here.
final class NativeAudio: NSObject, AVAudioRecorderDelegate {
  private var channel: FlutterMethodChannel?
  private var recorder: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private var duration: TimeInterval = 0
  private var phase = "stopped"
  private var recordingError: String?
  private var limitTimer: Timer?
  private var requestingAccess = false
  private var inspectingSource = false
  private let inspectionQueue = DispatchQueue(label: "dev.noteagent.audio-inspection")

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(name: "dev.noteagent/audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "startRecording":
        guard phase == "stopped", !requestingAccess else { throw audioError("请先结束当前录音。") }
        let url = try originalURL(call.arguments)
        requestingAccess = true
        authorize { [weak self] granted in
          guard let self = self else { return }
          self.requestingAccess = false
          guard granted else {
            result(FlutterError(code: "microphone_denied", message: "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 Note Agent，然后重试。", details: nil))
            return
          }
          do {
            try self.start(url)
            result(nil)
          } catch { result(self.flutterError(error)) }
        }
      case "pauseRecording":
        if phase == "recording" {
          recorder?.pause()
          duration = recorder?.currentTime ?? duration
          phase = "paused"
        }
        result(nil)
      case "resumeRecording":
        if phase == "paused" {
          guard recorder?.record() == true else { throw audioError("无法继续录音，现有原文件已保留。") }
          phase = "recording"
        }
        result(nil)
      case "recordingSnapshot": result(snapshot())
      case "stopRecording":
        finish()
        result(snapshot())
      case "inspectRecording":
        let audio = try AVAudioPlayer(contentsOf: originalURL(call.arguments))
        guard audio.prepareToPlay(), audio.duration > 0 else { throw audioError("原音频尚不可回放，现有文件已保留。") }
        result(Int((audio.duration * 1000).rounded()))
      case "inspectAudioSource":
        guard !inspectingSource else {
          result(FlutterError(code: "inspection_busy", message: "已有音频正在检查，请稍后重试。", details: nil))
          return
        }
        let path = try sourcePath(call.arguments)
        let inspector = try sourceInspector()
        // Resolve and validate scope before leaving the channel handler.
        _ = try inspector.sourceURL(path)
        inspectingSource = true
        inspectionQueue.async { [weak self] in
          let inspected = Result { try inspector.inspect(path) }
          DispatchQueue.main.async {
            self?.inspectingSource = false
            switch inspected {
            case .success(let metadata): result(metadata)
            case .failure(let error): result(FlutterError(code: "audio_inspection", message: error.localizedDescription, details: nil))
            }
          }
        }
      case "playAudioSource":
        guard phase == "stopped" else { throw audioError("请先结束录音再回放。") }
        player?.stop()
        let source = try sourceInspector().sourceURL(sourcePath(call.arguments))
        let audio = try AVAudioPlayer(contentsOf: source)
        guard audio.prepareToPlay(), audio.play() else { throw audioError("无法回放此原音频，原件已保留。") }
        player = audio
        result(nil)
      case "play":
        guard phase == "stopped" else { throw audioError("请先结束录音再回放。") }
        player?.stop()
        let audio = try AVAudioPlayer(contentsOf: originalURL(call.arguments))
        guard audio.prepareToPlay(), audio.play() else { throw audioError("无法回放此原音频，文件仍保留在本机。") }
        player = audio
        result(nil)
      case "stopPlayback": player?.stop(); player = nil; result(nil)
      case "playbackSnapshot":
        result(["isPlaying": player?.isPlaying ?? false, "positionMs": Int(((player?.currentTime ?? 0) * 1000).rounded())])
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(flutterError(error)) }
  }

  private func authorize(_ completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default: completion(false)
    }
  }

  private func start(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw audioError("此录音原文件已存在，请重新开始。") }
    player?.stop()
    player = nil
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 22050.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32000,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]
    let audio = try AVAudioRecorder(url: url, settings: settings)
    audio.delegate = self
    audio.isMeteringEnabled = true
    guard audio.prepareToRecord(), audio.record() else { throw audioError("无法启动麦克风，请检查输入设备后重试。") }
    recorder = audio
    phase = "recording"
    duration = 0
    recordingError = nil
    limitTimer?.invalidate()
    limitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self = self, self.phase == "recording" else { return }
      // AVAudioRecorder currentTime excludes paused time.
      if (self.recorder?.currentTime ?? 0) >= 300 { self.finish() }
    }
  }

  private func finish() {
    if phase != "stopped" {
      duration = recorder?.currentTime ?? duration
      phase = "stopped"
      recorder?.stop() // Closes the encoded container before Dart persists a saved result.
    }
    limitTimer?.invalidate()
    limitTimer = nil
  }

  private func snapshot() -> [String: Any] {
    if phase != "stopped" { duration = recorder?.currentTime ?? duration }
    recorder?.updateMeters()
    let power = recorder?.averagePower(forChannel: 0) ?? -160
    let level = phase == "recording" ? min(1.0, pow(10.0, Double(power) / 20.0)) : 0.0
    var value: [String: Any] = ["phase": phase, "durationMs": Int((duration * 1000).rounded()), "level": level]
    if let error = recordingError { value["error"] = error }
    return value
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    guard recorder === self.recorder else { return }
    if !flag { recordingError = "录音意外中断，现有原文件已保留，请回放核对。" }
    if phase != "stopped" { finish() }
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    guard recorder === self.recorder else { return }
    recordingError = "音频编码未完成，现有原文件已保留。\(error?.localizedDescription ?? "")"
    finish()
  }

  private func sourcePath(_ arguments: Any?) throws -> String {
    guard let arguments = arguments as? [String: Any], let path = arguments["path"] as? String else { throw audioError("缺少原音频位置。") }
    return path
  }
  private func sourceInspector() throws -> PrivateAudioSourceInspector {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return PrivateAudioSourceInspector(workspace: support.appendingPathComponent("dev.noteagent/workspace", isDirectory: true))
  }

  private func originalURL(_ arguments: Any?) throws -> URL {
    guard let arguments = arguments as? [String: Any], let path = arguments["path"] as? String else { throw audioError("缺少原音频位置。") }
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let root = support.appendingPathComponent("dev.noteagent/workspace/recordings", isDirectory: true).resolvingSymlinksInPath()
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent() == root, url.pathExtension == "m4a" else { throw audioError("原音频必须位于本机录音目录。") }
    return url
  }

  private func audioError(_ message: String) -> NSError { NSError(domain: "NoteAgentAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  private func flutterError(_ error: Error) -> FlutterError { FlutterError(code: "audio", message: error.localizedDescription, details: nil) }

  deinit { limitTimer?.invalidate(); recorder?.stop(); player?.stop() }
}

#endif

/// Import-only, bounded inspection of complete workspace-owned originals.
/// Separate from the microphone's exact recordings/<id>.m4a capability.
struct PrivateAudioSourceInspector {
  let workspace: URL
  private func failure(_ message: String) -> NSError {
    NSError(domain: "NoteAgentAudioInspection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  func sourceURL(_ path: String) throws -> URL {
    let root = workspace.appendingPathComponent("audio-sources", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let recordings = workspace.appendingPathComponent("recordings", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let literal = URL(fileURLWithPath: path).standardizedFileURL
    let url = literal.resolvingSymlinksInPath()
    let imported = url.deletingLastPathComponent().deletingLastPathComponent() == root && literal == url
    let captured = url.deletingLastPathComponent() == recordings && url.pathExtension == "m4a" && literal == url
    guard imported || captured else { throw failure("音频检查仅允许本机私有来源目录内的完整原件。") }
    return url
  }
  func inspect(_ path: String) throws -> [String: Any] {
    let url = try sourceURL(path)
    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard size.isRegularFile == true, let bytes = size.fileSize, bytes > 0, bytes <= 256 * 1024 * 1024 else {
      throw failure("原件为空或超过本机 256 MB 检查上限，原件已保留。")
    }
    var file: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file = file else { throw failure("没有可识别的音频容器，原件已保留。") }
    defer { AudioFileClose(file) }
    var type: AudioFileTypeID = 0
    var typeSize = UInt32(MemoryLayout.size(ofValue: type))
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout.size(ofValue: format))
    guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &typeSize, &type) == noErr,
      AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr else {
      throw failure("音频格式信息不完整，原件已保留。")
    }
    let container: String
    let codec: String
    switch (type, format.mFormatID) {
    case (kAudioFileM4AType, kAudioFormatMPEG4AAC), (kAudioFileMPEG4Type, kAudioFormatMPEG4AAC): container = "M4A"; codec = "AAC"
    case (kAudioFileMP3Type, kAudioFormatMPEGLayer3): container = "MP3"; codec = "MP3"
    case (kAudioFileWAVEType, kAudioFormatLinearPCM): container = "WAV"; codec = "PCM"
    default: throw failure("此平台当前支持 AAC / M4A、MP3、PCM / WAV；此原件格式尚不支持。")
    }
    let audio = try AVAudioFile(forReading: url)
    let rate = audio.processingFormat.sampleRate
    let duration = Double(audio.length) / rate
    guard rate.isFinite, rate >= 8000, rate <= 384000, duration.isFinite, duration > 0, duration <= 86400,
      audio.processingFormat.channelCount >= 1, audio.processingFormat.channelCount <= 32,
      let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
      throw failure("音频时长或参数无效，原件已保留。")
    }
    // Decode bounded windows, including the tail, rather than loading the file.
    for position in [AVAudioFramePosition(0), audio.length / 2, max(0, audio.length - 4096)] {
      audio.framePosition = position
      try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, audio.length - position)))
      guard buffer.frameLength > 0 else { throw failure("音频数据无法解码，原件可能不完整。") }
    }
    return ["container": container, "codec": codec, "durationMs": Int((duration * 1000).rounded()),
      "sampleRate": Int(rate.rounded()), "channels": Int(audio.processingFormat.channelCount)]
  }
}
