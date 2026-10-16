import Foundation

/// Headless native adapter probe; the same implementation is compiled in-app.
@main
struct AudioInspectionProbe {
  static func main() {
    do {
      guard CommandLine.arguments.count == 3 else { throw NSError(domain:"probe",code:1) }
      let inspector = PrivateAudioSourceInspector(workspace:URL(fileURLWithPath:CommandLine.arguments[1]))
      let result = try inspector.inspect(CommandLine.arguments[2])
      let json = try JSONSerialization.data(withJSONObject:result, options:[.sortedKeys])
      print(String(data:json,encoding:.utf8)!)
    } catch {
      FileHandle.standardError.write(Data(error.localizedDescription.utf8))
      exit(1)
    }
  }
}
