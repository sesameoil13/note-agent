import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var workspaceChannel: FlutterMethodChannel?
  private var scopedVaultURL: URL?
  private let bookmarkKey = "noteAgent.vaultBookmark"

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    minSize = NSSize(width: 640, height: 640)
    title = "笔记工作区"
    RegisterGeneratedPlugins(registry: controller)

    let channel = FlutterMethodChannel(
      name: "dev.noteagent/workspace",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "restoreLocation": self.restoreLocation(result)
      case "chooseLocation": self.chooseLocation(result)
      case "openInObsidian": self.openInObsidian(call.arguments, result)
      default: result(FlutterMethodNotImplemented)
      }
    }
    workspaceChannel = channel
    super.awakeFromNib()
  }

  private func localDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )
    let directory = support.appendingPathComponent("dev.noteagent/workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func restoreLocation(_ result: FlutterResult) {
    do {
      var location = ["localDirectory": try localDirectory().path]
      if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil, bookmarkDataIsStale: &stale
        )
        try activateVault(url)
        if stale { try persistBookmark(url) }
        location["vaultDirectory"] = url.path
      }
      result(location)
    } catch {
      result(FlutterError(code: "directory_access", message: "笔记库授权已失效或目录不可用，请重新选择。", details: nil))
    }
  }

  private func chooseLocation(_ result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "选择测试笔记库"
    panel.message = "请选择新的测试目录。原始文字与 Markdown 笔记会写入此目录。"
    panel.prompt = "使用此笔记库"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self = self else { return }
      guard response == .OK, let url = panel.url else { result(nil); return }
      do {
        let local = try self.localDirectory()
        try self.persistBookmark(url)
        try self.activateVault(url)
        result(["localDirectory": local.path, "vaultDirectory": url.path])
      } catch {
        result(FlutterError(code: "directory_access", message: "无法获得笔记库读写授权，请选择可写目录。", details: nil))
      }
    }
  }

  private func persistBookmark(_ url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
    )
    UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
  }

  private func activateVault(_ url: URL) throws {
    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(domain: "NoteWorkspace", code: 1)
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
      url.stopAccessingSecurityScopedResource()
      throw NSError(domain: "NoteWorkspace", code: 2)
    }
    let previous = scopedVaultURL
    scopedVaultURL = url
    previous?.stopAccessingSecurityScopedResource()
  }

  private func openInObsidian(_ arguments: Any?, _ result: FlutterResult) {
    guard let values = arguments as? [String: String], let path = values["path"],
          let vault = scopedVaultURL else {
      result(FlutterError(code: "note_path", message: "请先选择笔记库。", details: nil))
      return
    }
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let root = vault.resolvingSymlinksInPath().path + "/"
    guard file.path.hasPrefix(root), FileManager.default.fileExists(atPath: file.path) else {
      result(FlutterError(code: "note_path", message: "笔记文件尚未写入或不在当前笔记库中。", details: nil))
      return
    }
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: file.path)]
    guard let url = components.url,
          NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
          NSWorkspace.shared.open(url) else {
      result(FlutterError(code: "obsidian_unavailable", message: "未能打开 Obsidian，请确认已安装并将此目录作为笔记库打开。", details: nil))
      return
    }
    result(nil)
  }

  deinit { scopedVaultURL?.stopAccessingSecurityScopedResource() }
}
