#include "secure_credentials.h"
#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
std::string Argument(const Map* args, const char* name, const std::string& fallback = "") {
  if (!args) return fallback;
  auto it = args->find(Value(name));
  if (it == args->end()) return fallback;
  const auto* value = std::get_if<std::string>(&it->second);
  if (!value) throw std::runtime_error("Invalid argument");
  return *value;
}
std::filesystem::path Location(const std::string& slot) {
  PWSTR root = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &root))) throw std::runtime_error("No local storage");
  auto directory = std::filesystem::path(root) / L"dev.noteagent" / L"secure-connection";
  CoTaskMemFree(root);
  std::filesystem::create_directories(directory);
  return directory / (slot + ".dpapi");
}
}
SecureCredentials::SecureCredentials(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger, "dev.noteagent/credentials", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    try {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto slot = Argument(args, "slot", "default");
      if (!std::regex_match(slot, std::regex("^[a-zA-Z0-9_-]{1,40}$"))) throw std::runtime_error("Invalid slot");
      const auto path = Location(slot);
      if (call.method_name() == "read") {
        if (!std::filesystem::exists(path)) { result->Success(); return; }
        if (std::filesystem::file_size(path) > 20000) throw std::runtime_error("Invalid store");
        std::ifstream file(path, std::ios::binary);
        std::vector<BYTE> sealed((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        if (sealed.empty() || file.bad()) throw std::runtime_error("Read failed");
        DATA_BLOB input{static_cast<DWORD>(sealed.size()), sealed.data()}, plain{};
        if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &plain)) throw std::runtime_error("DPAPI unavailable");
        std::string value(reinterpret_cast<char*>(plain.pbData), plain.cbData);
        SecureZeroMemory(plain.pbData, plain.cbData); LocalFree(plain.pbData);
        result->Success(Value(value));
      } else if (call.method_name() == "write") {
        auto value = Argument(args, "value");
        if (value.size() > 16384) throw std::runtime_error("Invalid store size");
        DATA_BLOB input{static_cast<DWORD>(value.size()), reinterpret_cast<BYTE*>(value.data())}, sealed{};
        if (!CryptProtectData(&input, L"Note Agent connection", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &sealed)) throw std::runtime_error("DPAPI unavailable");
        SecureZeroMemory(value.data(), value.size());
        const auto temp = std::filesystem::path(path.wstring() + L".tmp");
        std::ofstream file(temp, std::ios::binary | std::ios::trunc);
        file.write(reinterpret_cast<const char*>(sealed.pbData), sealed.cbData);
        LocalFree(sealed.pbData);
        file.flush(); const bool written = file.good(); file.close();
        if (!written || !MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) throw std::runtime_error("Save failed");
        result->Success();
      } else if (call.method_name() == "delete") {
        std::filesystem::remove(path); result->Success();
      } else { result->NotImplemented(); }
    } catch (...) { result->Error("secure_store", "系统安全存储暂时不可用，请解锁设备后重试。"); }
  });
}
