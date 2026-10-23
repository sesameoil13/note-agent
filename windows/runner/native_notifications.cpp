#include "native_notifications.h"

// clang-format off
#include <unknwn.h>
#include <NotificationActivationCallback.h>
#include <shellapi.h>
#include <shobjidl.h>
// clang-format on
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "native_paths.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
namespace notifications = winrt::Windows::UI::Notifications;

namespace {

constexpr wchar_t kAppId[] = L"dev.noteagent.workspace";
constexpr wchar_t kDisplayName[] = L"笔记工作区";
constexpr wchar_t kGroup[] = L"note-agent";
constexpr wchar_t kToastArgument[] = L"-ToastActivated";
// {CBF85C56-35BE-4A74-94AF-61ED4CCDBA26}
constexpr GUID kActivatorId = {
    0xcbf85c56, 0x35be, 0x4a74, {0x94, 0xaf, 0x61, 0xed, 0x4c, 0xcd, 0xba, 0x26}};
constexpr wchar_t kActivatorText[] = L"{CBF85C56-35BE-4A74-94AF-61ED4CCDBA26}";
constexpr UINT kInteractionMessage = WM_APP + 0x4E1;
constexpr UINT kNetworkMessage = WM_APP + 0x4E2;
constexpr size_t kStoreLimit = 4 * 1024 * 1024;

std::atomic<HWND> g_window{nullptr};
DWORD g_class_cookie = 0;

// ---- Small durable stores under %LOCALAPPDATA%\dev.noteagent\notifications.

std::optional<std::wstring> StorePath(const wchar_t* name) {
  const auto directory = native_paths::AppDirectory(L"notifications");
  if (!directory) return std::nullopt;
  return *directory + L"\\" + name;
}

std::vector<std::string> ReadLines(const wchar_t* name) {
  std::vector<std::string> lines;
  const auto path = StorePath(name);
  const auto text = path ? native_paths::ReadSmallFile(*path, kStoreLimit)
                         : std::nullopt;
  if (!text) return lines;
  size_t start = 0;
  while (start < text->size()) {
    const size_t end = text->find('\n', start);
    const size_t stop = end == std::string::npos ? text->size() : end;
    if (stop > start) lines.push_back(text->substr(start, stop - start));
    start = stop + 1;
  }
  return lines;
}

bool WriteLines(const wchar_t* name, const std::vector<std::string>& lines) {
  const auto path = StorePath(name);
  if (!path) return false;
  std::string text;
  for (const auto& line : lines) text += line + "\n";
  return native_paths::ReplaceFileDurably(*path, text);
}

// Appends one record and flushes it before the toast action is acknowledged.
bool AppendLine(const wchar_t* name, const std::string& line) {
  const auto path = StorePath(name);
  if (!path) return false;
  HANDLE file = CreateFileW(path->c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  const std::string record = line + "\n";
  DWORD written = 0;
  const bool ok = WriteFile(file, record.data(),
                            static_cast<DWORD>(record.size()), &written,
                            nullptr) &&
                  written == record.size() && FlushFileBuffers(file);
  CloseHandle(file);
  return ok;
}

// ---- Encoding.

std::string PercentEncode(const std::string& text) {
  constexpr char digits[] = "0123456789ABCDEF";
  std::string encoded;
  for (const unsigned char byte : text) {
    if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
        (byte >= '0' && byte <= '9') || byte == '-' || byte == '.' ||
        byte == '_' || byte == '~' || byte == ':') {
      encoded += static_cast<char>(byte);
    } else {
      encoded += '%';
      encoded += digits[byte >> 4];
      encoded += digits[byte & 15];
    }
  }
  return encoded;
}

int HexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

std::optional<std::string> PercentDecode(const std::string& text) {
  std::string decoded;
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] != '%') {
      decoded += text[i];
      continue;
    }
    if (i + 2 >= text.size()) return std::nullopt;
    const int high = HexValue(text[i + 1]);
    const int low = HexValue(text[i + 2]);
    if (high < 0 || low < 0) return std::nullopt;
    decoded += static_cast<char>(high * 16 + low);
    i += 2;
  }
  return decoded;
}

struct Interaction {
  std::string id;
  std::string action;
  std::map<std::string, std::string> payload;
};

// Arguments: action=<a>&id=<id>&p.<key>=<value>..., every part percent-encoded.
std::string EncodeArguments(const std::string& action, const std::string& id,
                            const EncodableMap& payload) {
  std::string text = "action=" + PercentEncode(action) + "&id=" + PercentEncode(id);
  for (const auto& [key, value] : payload) {
    const auto* k = std::get_if<std::string>(&key);
    const auto* v = std::get_if<std::string>(&value);
    if (k && v) text += "&p." + PercentEncode(*k) + "=" + PercentEncode(*v);
  }
  return text;
}

std::optional<Interaction> DecodeArguments(const std::string& text) {
  Interaction interaction;
  size_t start = 0;
  while (start <= text.size()) {
    const size_t end = text.find('&', start);
    const std::string part =
        text.substr(start, end == std::string::npos ? std::string::npos : end - start);
    const size_t equals = part.find('=');
    if (equals == std::string::npos) return std::nullopt;
    const auto key = PercentDecode(part.substr(0, equals));
    const auto value = PercentDecode(part.substr(equals + 1));
    if (!key || !value) return std::nullopt;
    if (*key == "action") {
      interaction.action = *value;
    } else if (*key == "id") {
      interaction.id = *value;
    } else if (key->rfind("p.", 0) == 0) {
      interaction.payload[key->substr(2)] = *value;
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (interaction.id.rfind("note-agent:", 0) != 0 ||
      interaction.payload.find("kind") == interaction.payload.end() ||
      (interaction.action != "default" && interaction.action != "complete" &&
       interaction.action != "snooze")) {
    return std::nullopt;
  }
  return interaction;
}

std::wstring Xml(const std::wstring& text) {
  std::wstring escaped;
  for (const wchar_t c : text) {
    switch (c) {
      case L'&': escaped += L"&amp;"; break;
      case L'<': escaped += L"&lt;"; break;
      case L'>': escaped += L"&gt;"; break;
      case L'"': escaped += L"&quot;"; break;
      case L'\'': escaped += L"&apos;"; break;
      default: escaped += c;
    }
  }
  return escaped;
}

std::wstring Wide(const std::string& text) {
  return native_paths::Utf16(text).value_or(L"");
}

// Toast tags/ids are short; the long revisioned id maps to a stable hash.
std::wstring Tag(const std::string& id) {
  unsigned long long hash = 1469598103934665603ULL;
  for (const unsigned char byte : id) {
    hash ^= byte;
    hash *= 1099511628211ULL;
  }
  wchar_t buffer[17];
  swprintf(buffer, 17, L"%016llx", hash);
  return buffer;
}

// accepted.txt lines: <tag>\t<id>, for ids Windows accepted and not cancelled.
std::map<std::wstring, std::string> AcceptedIds() {
  std::map<std::wstring, std::string> accepted;
  for (const auto& line : ReadLines(L"accepted.txt")) {
    const size_t tab = line.find('\t');
    if (tab == std::string::npos) continue;
    accepted[Wide(line.substr(0, tab))] = line.substr(tab + 1);
  }
  return accepted;
}

bool SaveAccepted(const std::map<std::wstring, std::string>& accepted) {
  std::vector<std::string> lines;
  for (const auto& [tag, id] : accepted) {
    lines.push_back(native_paths::Utf8(tag) + "\t" + id);
  }
  return WriteLines(L"accepted.txt", lines);
}

notifications::ToastNotifier Notifier() {
  return notifications::ToastNotificationManager::CreateToastNotifier(kAppId);
}

std::string Permission(notifications::NotificationSetting setting) {
  return setting == notifications::NotificationSetting::Enabled ? "allowed"
                                                                : "denied";
}

void RemoveToast(const notifications::ToastNotifier& notifier,
                 const std::wstring& tag) {
  for (const auto& scheduled : notifier.GetScheduledToastNotifications()) {
    if (scheduled.Id() == tag) notifier.RemoveFromSchedule(scheduled);
  }
  notifications::ToastNotificationManager::History().Remove(tag, kGroup, kAppId);
}

const std::string* StringValue(const EncodableMap& values, const char* name) {
  const auto entry = values.find(EncodableValue(name));
  return entry == values.end() ? nullptr
                               : std::get_if<std::string>(&entry->second);
}

// ---- COM activator Windows calls for toast clicks and buttons.

class ToastActivator : public INotificationActivationCallback {
 public:
  STDMETHODIMP QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    if (id == __uuidof(IUnknown) ||
        id == __uuidof(INotificationActivationCallback)) {
      *object = static_cast<INotificationActivationCallback*>(this);
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
  // Records the response durably first; the workspace applies T20 lifecycle
  // rules later, so stale, repeated or late responses are ignored there.
  STDMETHODIMP Activate(LPCWSTR, LPCWSTR arguments,
                        const NOTIFICATION_USER_INPUT_DATA*, ULONG) override {
    const std::string text = arguments ? native_paths::Utf8(arguments) : "";
    const auto interaction = DecodeArguments(text);
    if (!interaction || !AppendLine(L"interactions.txt", text)) {
      return S_OK;  // Unknown/invalid toasts are ignored, not trusted.
    }
    // Clicking the toast body opens the note; buttons stay in the background.
    const HWND window = g_window.load();
    if (window) {
      PostMessageW(window, kInteractionMessage,
                   interaction->action == "default" ? 1 : 0, 0);
    }
    return S_OK;
  }

 private:
  std::atomic<ULONG> references_{1};
};

class ActivatorFactory : public IClassFactory {
 public:
  STDMETHODIMP QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    if (id == __uuidof(IUnknown) || id == __uuidof(IClassFactory)) {
      *object = static_cast<IClassFactory*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return 2; }   // Static lifetime.
  STDMETHODIMP_(ULONG) Release() override { return 1; }
  STDMETHODIMP CreateInstance(IUnknown* outer, REFIID id, void** object) override {
    if (outer) return CLASS_E_NOAGGREGATION;
    auto* activator = new ToastActivator();
    const HRESULT status = activator->QueryInterface(id, object);
    activator->Release();
    return status;
  }
  STDMETHODIMP LockServer(BOOL) override { return S_OK; }
};

ActivatorFactory g_factory;

bool SetValue(HKEY root, const std::wstring& key, const wchar_t* name,
              const std::wstring& value) {
  return RegSetKeyValueW(root, key.c_str(), name, REG_SZ, value.c_str(),
                         static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

// ---- Network return (Windows 10 2004+), loaded dynamically.

struct ConnectivityHint {
  int level;
  int cost;
  BOOLEAN approaching_data_limit;
  BOOLEAN over_data_limit;
  BOOLEAN roaming;
};
using HintCallback = void(WINAPI*)(PVOID, ConnectivityHint);
using NotifyHint = DWORD(WINAPI*)(HintCallback, PVOID, BOOLEAN, PHANDLE);
using CancelNotify = DWORD(WINAPI*)(HANDLE);
constexpr int kInternetAccess = 3;  // NetworkConnectivityLevelHintInternetAccess
std::atomic<int> g_last_level{-1};

void WINAPI OnConnectivityHint(PVOID, ConnectivityHint hint) {
  const int previous = g_last_level.exchange(hint.level);
  const HWND window = g_window.load();
  if (hint.level == kInternetAccess && previous != kInternetAccess &&
      previous != -1 && window) {
    PostMessageW(window, kNetworkMessage, 0, 0);
  }
}

}  // namespace

void NativeNotifications::PrepareProcess() {
  // Without a package identity Windows finds the toast sender and its COM
  // activator through these per-user keys; nothing machine-wide is changed.
  wchar_t executable[MAX_PATH * 4];
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH * 4);
  if (length == 0 || length >= MAX_PATH * 4) return;
  const std::wstring app_key =
      std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppId;
  SetValue(HKEY_CURRENT_USER, app_key, L"DisplayName", kDisplayName);
  SetValue(HKEY_CURRENT_USER, app_key, L"CustomActivator", kActivatorText);
  SetValue(HKEY_CURRENT_USER,
           std::wstring(L"Software\\Classes\\CLSID\\") + kActivatorText +
               L"\\LocalServer32",
           nullptr,
           L"\"" + std::wstring(executable, length) + L"\" " + kToastArgument);
  SetCurrentProcessExplicitAppUserModelID(kAppId);
  CoRegisterClassObject(kActivatorId, &g_factory, CLSCTX_LOCAL_SERVER,
                        REGCLS_MULTIPLEUSE, &g_class_cookie);
}

void NativeNotifications::ReleaseProcess() {
  if (g_class_cookie) CoRevokeClassObject(g_class_cookie);
  g_class_cookie = 0;
}

bool NativeNotifications::LaunchedForToast(const wchar_t* command_line) {
  return command_line && wcsstr(command_line, kToastArgument) != nullptr;
}

NativeNotifications::NativeNotifications(flutter::BinaryMessenger* messenger,
                                         HWND window) {
  g_window = window;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dev.noteagent/notifications",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  if (HMODULE library = GetModuleHandleW(L"iphlpapi.dll")
                            ? GetModuleHandleW(L"iphlpapi.dll")
                            : LoadLibraryW(L"iphlpapi.dll")) {
    const auto notify = reinterpret_cast<NotifyHint>(reinterpret_cast<void*>(
        GetProcAddress(library, "NotifyNetworkConnectivityHintChange")));
    if (notify) notify(&OnConnectivityHint, nullptr, TRUE, &network_hint_);
  }
}

NativeNotifications::~NativeNotifications() {
  g_window = nullptr;
  if (network_hint_) {
    if (HMODULE library = GetModuleHandleW(L"iphlpapi.dll")) {
      const auto cancel = reinterpret_cast<CancelNotify>(reinterpret_cast<void*>(
          GetProcAddress(library, "CancelMibChangeNotify2")));
      if (cancel) cancel(network_hint_);
    }
    network_hint_ = nullptr;
  }
  channel_->SetMethodCallHandler(nullptr);
}

void NativeNotifications::Notify(const char* method) {
  channel_->InvokeMethod(method, nullptr);
}

std::optional<LRESULT> NativeNotifications::HandleMessage(UINT message,
                                                          WPARAM wparam,
                                                          LPARAM) {
  switch (message) {
    case kInteractionMessage:
      if (wparam == 1 && g_window.load()) {
        const HWND window = g_window.load();
        ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(window);
      }
      Notify("interactionAvailable");
      return 0;
    case kNetworkMessage:
      Notify("networkAvailable");
      return 0;
    case WM_POWERBROADCAST:
      // Sent once for every resume; the App re-checks reminder plans.
      if (wparam == PBT_APMRESUMEAUTOMATIC) Notify("systemResumed");
      return std::nullopt;
  }
  return std::nullopt;
}

void NativeNotifications::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const auto* values = call.arguments()
                           ? std::get_if<EncodableMap>(call.arguments())
                           : nullptr;
  try {
    const auto& method = call.method_name();
    if (method == "inspect") {
      auto notifier = Notifier();
      const auto accepted = AcceptedIds();
      EncodableList pending, delivered, ids;
      for (const auto& scheduled : notifier.GetScheduledToastNotifications()) {
        const auto found = accepted.find(std::wstring(scheduled.Id()));
        if (found != accepted.end()) pending.push_back(EncodableValue(found->second));
      }
      for (const auto& toast :
           notifications::ToastNotificationManager::History().GetHistory(kAppId)) {
        const auto found = accepted.find(std::wstring(toast.Tag()));
        if (found != accepted.end()) delivered.push_back(EncodableValue(found->second));
      }
      for (const auto& entry : accepted) ids.push_back(EncodableValue(entry.second));
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("permission"), EncodableValue(Permission(notifier.Setting()))},
          {EncodableValue("pending"), EncodableValue(pending)},
          {EncodableValue("delivered"), EncodableValue(delivered)},
          {EncodableValue("accepted"), EncodableValue(ids)},
          // Windows has no exact-alarm grant; a sleeping PC shows due toasts
          // after waking, which the App re-checks on systemResumed.
          {EncodableValue("exactTiming"), EncodableValue(true)},
      }));
    } else if (method == "requestPermission") {
      // Windows never prompts desktop apps; this explicit button opens the
      // system page so the user can allow toasts, and reports the truth.
      const auto setting = Notifier().Setting();
      if (setting != notifications::NotificationSetting::Enabled &&
          setting != notifications::NotificationSetting::DisabledByGroupPolicy) {
        ShellExecuteW(nullptr, L"open", L"ms-settings:notifications", nullptr,
                      nullptr, SW_SHOWNORMAL);
      }
      result->Success(EncodableValue(Permission(setting)));
    } else if (method == "takeInteractions") {
      const auto* kind = values ? StringValue(*values, "kind") : nullptr;
      const auto* vault = values ? StringValue(*values, "vault") : nullptr;
      if (!kind) {
        result->Error("notification_arguments", "通知类型无效。");
        return;
      }
      EncodableList taken;
      std::vector<std::string> kept;
      for (const auto& line : ReadLines(L"interactions.txt")) {
        const auto interaction = DecodeArguments(line);
        if (!interaction) continue;
        const auto& payload = interaction->payload;
        const auto vault_entry = payload.find("vault");
        const bool matches =
            payload.at("kind") == *kind &&
            (!vault || (vault_entry != payload.end() && vault_entry->second == *vault));
        if (!matches) {
          kept.push_back(line);
          continue;
        }
        EncodableMap map;
        for (const auto& [key, value] : payload) {
          map[EncodableValue(key)] = EncodableValue(value);
        }
        taken.push_back(EncodableValue(EncodableMap{
            {EncodableValue("id"), EncodableValue(interaction->id)},
            {EncodableValue("actionIdentifier"), EncodableValue(interaction->action)},
            {EncodableValue("payload"), EncodableValue(map)},
        }));
      }
      if (!taken.empty() && !WriteLines(L"interactions.txt", kept)) {
        result->Error("notification_store", "通知操作记录暂时无法读取，将在下次核对时重试。");
        return;
      }
      result->Success(EncodableValue(taken));
    } else if (method == "schedule") {
      const auto* id = values ? StringValue(*values, "id") : nullptr;
      const auto* title = values ? StringValue(*values, "title") : nullptr;
      const auto* body = values ? StringValue(*values, "body") : nullptr;
      const auto time_entry = values ? values->find(EncodableValue("timeMs"))
                                     : EncodableMap::const_iterator();
      const auto payload_entry = values ? values->find(EncodableValue("payload"))
                                        : EncodableMap::const_iterator();
      const auto immediate_entry = values ? values->find(EncodableValue("immediate"))
                                          : EncodableMap::const_iterator();
      const EncodableMap* payload =
          values && payload_entry != values->end()
              ? std::get_if<EncodableMap>(&payload_entry->second)
              : nullptr;
      const bool* immediate =
          values && immediate_entry != values->end()
              ? std::get_if<bool>(&immediate_entry->second)
              : nullptr;
      std::optional<long long> millis;
      if (values && time_entry != values->end()) {
        if (const auto* small = std::get_if<int32_t>(&time_entry->second)) millis = *small;
        if (const auto* large = std::get_if<int64_t>(&time_entry->second)) millis = *large;
      }
      if (!id || id->rfind("note-agent:", 0) != 0 || !title || !body ||
          !payload || !immediate || !millis) {
        result->Error("notification_arguments", "提醒计划无效。");
        return;
      }
      auto notifier = Notifier();
      if (notifier.Setting() != notifications::NotificationSetting::Enabled) {
        result->Error("notification_denied", "系统通知未允许，计划仍保留在 App。");
        return;
      }
      const auto* kind = StringValue(*payload, "kind");
      std::wstring xml =
          L"<toast launch=\"" +
          Xml(Wide(EncodeArguments("default", *id, *payload))) +
          L"\"><visual><binding template=\"ToastGeneric\"><text>" + Xml(Wide(*title)) +
          L"</text><text>" + Xml(Wide(*body)) + L"</text></binding></visual>";
      if (kind && *kind == "actionReminder") {
        xml += L"<actions><action content=\"完成\" activationType=\"background\" arguments=\"" +
               Xml(Wide(EncodeArguments("complete", *id, *payload))) +
               L"\"/><action content=\"稍后提醒\" activationType=\"background\" arguments=\"" +
               Xml(Wide(EncodeArguments("snooze", *id, *payload))) + L"\"/></actions>";
      }
      xml += L"</toast>";
      winrt::Windows::Data::Xml::Dom::XmlDocument document;
      document.LoadXml(xml);
      const std::wstring tag = Tag(*id);
      RemoveToast(notifier, tag);  // A reschedule replaces, never duplicates.
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::system_clock::now().time_since_epoch())
                           .count();
      if (*immediate || *millis <= now + 1000) {
        notifications::ToastNotification toast(document);
        toast.Tag(tag);
        toast.Group(kGroup);
        notifier.Show(toast);
      } else {
        const auto when = winrt::clock::from_sys(std::chrono::system_clock::time_point(
            std::chrono::duration_cast<std::chrono::system_clock::duration>(
                std::chrono::milliseconds(*millis))));
        notifications::ScheduledToastNotification scheduled(document, when);
        scheduled.Id(tag);
        scheduled.Tag(tag);
        scheduled.Group(kGroup);
        notifier.AddToSchedule(scheduled);
      }
      auto accepted = AcceptedIds();
      accepted[tag] = *id;
      if (!SaveAccepted(accepted)) {
        result->Error("notification_schedule", "提醒已交给系统，但本机记录未保存，请重试核对。");
        return;
      }
      result->Success();
    } else if (method == "cancel") {
      const auto* id = values ? StringValue(*values, "id") : nullptr;
      if (!id || id->rfind("note-agent:", 0) != 0) {
        result->Error("notification_arguments", "提醒标识无效。");
        return;
      }
      const std::wstring tag = Tag(*id);
      RemoveToast(Notifier(), tag);
      auto accepted = AcceptedIds();
      if (accepted.erase(tag) > 0 && !SaveAccepted(accepted)) {
        result->Error("notification_cancel", "提醒已取消，但本机记录未保存，请重试核对。");
        return;
      }
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const winrt::hresult_error& error) {
    result->Error("notification_system",
                  "Windows 通知不可用：" + native_paths::Utf8(std::wstring(error.message())));
  } catch (...) {
    result->Error("notification_system", "Windows 通知暂时不可用，计划仍保留在 App。");
  }
}
