#include "workspace_platform.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <filesystem>
#include <optional>
#include <utility>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
constexpr wchar_t kRegistryKey[] = L"Software\\NoteAgent";
constexpr wchar_t kVaultValue[] = L"VaultDirectory";

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                       text.data(), static_cast<int>(text.size()),
                                       nullptr, 0, nullptr, nullptr);
  if (length == 0) return {};
  std::string converted(length, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), converted.data(),
                          length, nullptr, nullptr) == 0) return {};
  return converted;
}

std::optional<std::wstring> Utf16(const std::string& text) {
  if (text.empty() || text.find('\0') != std::string::npos) return std::nullopt;
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       text.data(), static_cast<int>(text.size()),
                                       nullptr, 0);
  if (length == 0) return std::nullopt;
  std::wstring converted(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), converted.data(),
                          length) == 0) return std::nullopt;
  return converted;
}

std::string EncodeQueryValue(const std::wstring& path) {
  constexpr char digits[] = "0123456789ABCDEF";
  std::string encoded;
  for (const unsigned char byte : Utf8(path)) {
    if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
        (byte >= '0' && byte <= '9') || byte == '-' || byte == '.' ||
        byte == '_' || byte == '~') {
      encoded += static_cast<char>(byte);
    } else {
      encoded += '%';
      encoded += digits[byte >> 4];
      encoded += digits[byte & 15];
    }
  }
  return encoded;
}

// Resolve junctions/symlinks from an existing handle, not a string prefix alone.
std::optional<std::wstring> ExistingPath(const std::wstring& path,
                                       bool directory) {
  HANDLE handle = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING,
                             FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return std::nullopt;
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(handle, &information) ||
      ((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) !=
          directory) {
    CloseHandle(handle);
    return std::nullopt;
  }
  const DWORD length = GetFinalPathNameByHandleW(handle, nullptr, 0,
                                                FILE_NAME_NORMALIZED);
  std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1);
  const DWORD written = length == 0 ? 0 : GetFinalPathNameByHandleW(
      handle, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED);
  CloseHandle(handle);
  if (written == 0 || written >= buffer.size()) return std::nullopt;
  std::wstring resolved(buffer.data(), written);
  if (resolved.rfind(L"\\\\?\\UNC\\", 0) == 0) {
    resolved = L"\\\\" + resolved.substr(8);
  } else if (resolved.rfind(L"\\\\?\\", 0) == 0) {
    resolved.erase(0, 4);
  }
  return resolved;
}

std::optional<std::wstring> LocalDirectory() {
  PWSTR known = nullptr;
  const HRESULT status = SHGetKnownFolderPath(FOLDERID_LocalAppData,
                                              KF_FLAG_CREATE, nullptr, &known);
  if (FAILED(status)) return std::nullopt;
  const auto directory = std::filesystem::path(known) /
                         L"dev.noteagent" / L"workspace";
  CoTaskMemFree(known);
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return std::nullopt;
  return ExistingPath(directory.native(), true);
}

bool ReadVault(std::wstring* path) {
  DWORD bytes = 0;
  LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kRegistryKey, kVaultValue,
                               RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
    path->clear();
    return true;
  }
  if (status != ERROR_SUCCESS || bytes < sizeof(wchar_t) ||
      bytes > 32768 * sizeof(wchar_t) || bytes % sizeof(wchar_t) != 0) {
    return false;
  }
  std::vector<wchar_t> value(bytes / sizeof(wchar_t));
  status = RegGetValueW(HKEY_CURRENT_USER, kRegistryKey, kVaultValue,
                        RRF_RT_REG_SZ, nullptr, value.data(), &bytes);
  if (status != ERROR_SUCCESS || value.back() != L'\0') return false;
  *path = value.data();
  return !path->empty();
}

bool PersistVault(const std::wstring& path) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = RegSetValueExW(
      key, kVaultValue, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(path.c_str()),
      static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

EncodableValue Location(const std::wstring& local,
                        const std::wstring& vault) {
  EncodableMap location = {
      {EncodableValue("localDirectory"), EncodableValue(Utf8(local))}};
  if (!vault.empty()) {
    location[EncodableValue("vaultDirectory")] = EncodableValue(Utf8(vault));
  }
  return EncodableValue(location);
}
}  // namespace

WorkspacePlatform::WorkspacePlatform(flutter::BinaryMessenger* messenger,
                                     HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dev.noteagent/workspace",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

WorkspacePlatform::~WorkspacePlatform() {
  channel_->SetMethodCallHandler(nullptr);
}

void WorkspacePlatform::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  if (call.method_name() == "restoreLocation") {
    RestoreLocation(std::move(result));
  } else if (call.method_name() == "chooseLocation") {
    ChooseLocation(std::move(result));
  } else if (call.method_name() == "openInObsidian") {
    OpenInObsidian(call.arguments(), std::move(result));
  } else {
    result->NotImplemented();
  }
}

void WorkspacePlatform::RestoreLocation(std::unique_ptr<Result> result) {
  const auto local = LocalDirectory();
  if (!local) {
    result->Error("location", "无法打开本机存储位置。");
    return;
  }
  std::wstring saved;
  if (!ReadVault(&saved)) {
    result->Error("directory_access", "无法恢复笔记库位置，请重新选择。");
    return;
  }
  if (!saved.empty()) {
    const auto directory = ExistingPath(saved, true);
    if (!directory) {
      result->Error("directory_access", "笔记库目录不可用，请重新选择。");
      return;
    }
    vault_directory_ = *directory;
  }
  result->Success(Location(*local, vault_directory_));
}

void WorkspacePlatform::ChooseLocation(std::unique_ptr<Result> result) {
  ComPtr<IFileOpenDialog> dialog;
  HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(status)) status = dialog->GetOptions(&options);
  if (SUCCEEDED(status)) {
    status = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                                FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
  }
  if (SUCCEEDED(status)) status = dialog->SetTitle(L"选择测试笔记库");
  if (SUCCEEDED(status)) status = dialog->SetOkButtonLabel(L"使用此笔记库");
  if (SUCCEEDED(status)) status = dialog->Show(window_);
  if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success();
    return;
  }
  ComPtr<IShellItem> selected;
  if (SUCCEEDED(status)) status = dialog->GetResult(&selected);
  PWSTR selected_path = nullptr;
  if (SUCCEEDED(status)) {
    status = selected->GetDisplayName(SIGDN_FILESYSPATH, &selected_path);
  }
  const auto directory = SUCCEEDED(status) && selected_path
      ? ExistingPath(selected_path, true) : std::nullopt;
  CoTaskMemFree(selected_path);
  const auto local = LocalDirectory();
  if (!directory || !local || !PersistVault(*directory)) {
    result->Error("directory_access", "无法使用此笔记库，请选择可访问的目录。");
    return;
  }
  vault_directory_ = *directory;
  result->Success(Location(*local, vault_directory_));
}

void WorkspacePlatform::OpenInObsidian(
    const EncodableValue* arguments, std::unique_ptr<Result> result) {
  const auto* values = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  const std::string* path = nullptr;
  if (values) {
    const auto entry = values->find(EncodableValue("path"));
    if (entry != values->end()) path = std::get_if<std::string>(&entry->second);
  }
  const auto wide_path = path ? Utf16(*path) : std::nullopt;
  const auto file = wide_path ? ExistingPath(*wide_path, false) : std::nullopt;
  const auto vault = vault_directory_.empty() ? std::nullopt :
      ExistingPath(vault_directory_, true);
  std::wstring root = vault.value_or(L"");
  if (!root.empty() && root.back() != L'\\') root += L'\\';
  if (!file || root.empty() || file->size() <= root.size() ||
      CompareStringOrdinal(file->data(), static_cast<int>(root.size()),
                           root.data(), static_cast<int>(root.size()), TRUE) !=
          CSTR_EQUAL) {
    result->Error("note_path", "笔记文件尚未写入或不在当前笔记库中。");
    return;
  }
  const auto uri = Utf16("obsidian://open?path=" + EncodeQueryValue(*file));
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  launch.hwnd = window_;
  launch.lpVerb = L"open";
  launch.lpFile = uri->c_str();
  launch.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&launch)) {
    result->Error("obsidian_unavailable",
                  "未能打开 Obsidian，请确认已安装并将此目录作为笔记库打开。");
    return;
  }
  result->Success();
}
