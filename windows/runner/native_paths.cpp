#include "native_paths.h"

#include <shlobj.h>

#include <filesystem>
#include <utility>
#include <vector>

namespace native_paths {

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
      nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string converted(static_cast<size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), converted.data(),
                          length, nullptr, nullptr) == 0) {
    return {};
  }
  return converted;
}

std::optional<std::wstring> Utf16(const std::string& text) {
  if (text.empty() || text.find('\0') != std::string::npos) return std::nullopt;
  const int length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return std::nullopt;
  std::wstring converted(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), converted.data(),
                          length) == 0) {
    return std::nullopt;
  }
  return converted;
}

std::optional<std::wstring> ExistingPath(const std::wstring& path,
                                         bool directory) {
  HANDLE handle = CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return std::nullopt;
  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(handle, &information) ||
      ((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) !=
          directory) {
    CloseHandle(handle);
    return std::nullopt;
  }
  const DWORD length =
      GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED);
  std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1);
  const DWORD written =
      length == 0 ? 0
                  : GetFinalPathNameByHandleW(
                        handle, buffer.data(),
                        static_cast<DWORD>(buffer.size()), FILE_NAME_NORMALIZED);
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

std::optional<std::wstring> AppDirectory(const wchar_t* child) {
  PWSTR known = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &known))) {
    CoTaskMemFree(known);
    return std::nullopt;
  }
  const auto directory = std::filesystem::path(known) / L"dev.noteagent" / child;
  CoTaskMemFree(known);
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return std::nullopt;
  return ExistingPath(directory.native(), true);
}

std::optional<std::wstring> LocalDirectory() {
  return AppDirectory(L"workspace");
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
  return left.size() == right.size() &&
         CompareStringOrdinal(left.data(), static_cast<int>(left.size()),
                              right.data(), static_cast<int>(right.size()),
                              TRUE) == CSTR_EQUAL;
}

bool ReplaceFileDurably(const std::wstring& path, const std::string& bytes) {
  const std::wstring temp = path + L".tmp";
  HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool ok =
      (bytes.empty() ||
       (WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                  &written, nullptr) &&
        written == bytes.size())) &&
      FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(temp.c_str());
    return false;
  }
  return MoveFileExW(temp.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

std::optional<std::string> ReadSmallFile(const std::wstring& path,
                                         size_t limit) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::nullopt;
  LARGE_INTEGER size{};
  std::optional<std::string> result;
  if (GetFileSizeEx(file, &size) && size.QuadPart >= 0 &&
      static_cast<unsigned long long>(size.QuadPart) <= limit) {
    std::string bytes(static_cast<size_t>(size.QuadPart), '\0');
    DWORD read = 0;
    if (bytes.empty() ||
        (ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read,
                  nullptr) &&
         read == bytes.size())) {
      result = std::move(bytes);
    }
  }
  CloseHandle(file);
  return result;
}

}  // namespace native_paths
