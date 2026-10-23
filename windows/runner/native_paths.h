#ifndef RUNNER_NATIVE_PATHS_H_
#define RUNNER_NATIVE_PATHS_H_

#include <windows.h>

#include <optional>
#include <string>

// Shared Windows path/encoding helpers for the runner's native adapters.
namespace native_paths {

std::string Utf8(const std::wstring& text);
std::optional<std::wstring> Utf16(const std::string& text);

// Resolves junctions/symlinks from an existing handle, not a string prefix.
std::optional<std::wstring> ExistingPath(const std::wstring& path,
                                         bool directory);

// %LOCALAPPDATA%\dev.noteagent\<child>, created when missing and resolved.
std::optional<std::wstring> AppDirectory(const wchar_t* child);

// %LOCALAPPDATA%\dev.noteagent\workspace, the private workspace root.
std::optional<std::wstring> LocalDirectory();

// Case-insensitive ordinal equality, as NTFS compares names.
bool SamePath(const std::wstring& left, const std::wstring& right);

// Replaces |path| with |bytes| through a flushed sibling and an atomic rename.
bool ReplaceFileDurably(const std::wstring& path, const std::string& bytes);

// Reads a small file (at most |limit| bytes); nullopt when missing/unreadable.
std::optional<std::string> ReadSmallFile(const std::wstring& path,
                                         size_t limit);

}  // namespace native_paths

#endif  // RUNNER_NATIVE_PATHS_H_
