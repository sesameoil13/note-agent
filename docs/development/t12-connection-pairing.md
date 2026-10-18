# T12：OpenRouter 连接与安全设备配对

本票为 GitHub #13 的本地实现。主规格与 ADR 0001 继续适用；配对只传递服务配置与设备身份，不修改笔记库授权，不证明笔记或附件已同步。

## 当前验证

- 公开 `NoteWorkspace.connection`：免费 Key 元数据检测、安全存储边界写入／恢复、无效替换保留原连接、未创建成功的配对可取消。
- 两个独立工作区通过真实本机 Workerd + D1 HTTP 边界，完成一次性配对、两端验证码核对、原设备批准、HKDF/AES-GCM 配置传递，分别保留各自的真实测试库。
- 接收密文被篡改时拒绝配置；安全存储拒绝写入时不确认消耗；确认请求失败后仍诚实显示已保存的 Key，可重启恢复后继续确认。
- 服务 HTTP 测试：首次启用只创建一个原设备、权限受限的设备令牌、并发认领只成功一个、拒绝／过期不能接收配置、重复确认幂等、首次启用错误有频率限制；延迟请求体不能延长有效期或撤销已确认配对。
- macOS debug 构建通过。Keychain 适配已编译；真实 Keychain 写入／恢复、原生 App 界面、两实际 App 实例及远程 Free 服务验收仍待执行。
- Android Keystore 和 Windows DPAPI 为源代码实现，未作原生设备或构建通过声明。Android SDK 工作仍按用户决定暂缓；Windows 环境门槛未解除。
- Wrangler `deploy --dry-run` 通过，当前只产生本机打包产物。未授权或部署 Cloudflare、创建远程 D1、升级套餐、调用收费模型或向聊天收集 Key。

## App 与安全存储

“连接与设备”在工作区顶部可进入，尚未选择笔记库时也可进入。Key 只在 App 的遮蔽输入框填写；检测只请求 `GET https://openrouter.ai/api/v1/key`，禁止重定向，不发送笔记，不调用模型。管理／Provisioning Key 元数据会被拒绝。凭据错误不自动循环重试，界面不回显 Key 或服务原始错误。

macOS 的 Key 与首次启用码由有名称、可按下的「填写」动作打开标准 AppKit sheet，以原生 `NSSecureTextField` 编辑并获得初始键盘焦点。空白输入不能确认；取消保留原草稿，确认后只把原文传回既有内存 controller，连接页面只显示「已填写，尚未提交」，仍需用户点击检测保存或启用。当前 SDK 的 Flutter 遮蔽文本虽已在 Dart semantics 中掩码，macOS 辅助功能桥仍会把正在编辑的原文写入普通 `NSTextField`；其 `AppKitView` 又未把嵌入的安全输入加入可发现的原生 AX 子树。因此不能仅检查界面圆点、`find.text`、或消失的 AX 原文来证明保密与可访问性。公开 App UI 回归通过命名辅助功能动作打开系统输入边界，检查取消／空值保留草稿、编辑能到达原连接动作且 Flutter semantics 不含测试 Key；sheet 的真实密码角色、保护值与键盘编辑仍须隔离实际 App 验收。其他平台继续使用 Flutter 的遮蔽输入；可见配对码与复制操作不变。参见 [Apple 安全输入](https://developer.apple.com/documentation/appkit/nssecuretextfield) 与 [AppKit sheet](https://developer.apple.com/documentation/appkit/nsalert)。

整个凭据包（OpenRouter Key、设备随机令牌、未完成配对的随机秘密和恢复状态）只经系统安全存储 Adapter 持久化：

- macOS：Keychain generic password，独立 service/account，`AfterFirstUnlockThisDeviceOnly`，不写 UserDefaults、SQLite 或笔记库。
- Android：Android Keystore 生成 AES-256 key，以随机 nonce 和身份 AAD 做 AES-GCM；私有 preferences 仅含密文。既有 `allowBackup=false` 保留。读取丢失／失效的 Keystore key 时拒绝，不静默换 key。
- Windows：当前登录用户的 DPAPI 加密，`CRYPTPROTECT_UI_FORBIDDEN`；AppData 中仅存原子替换的密文文件。

普通凭据槽为 `default`。原生测试必须使用 `--dart-define=DEVICE_SLOT=t12-native-probe`，集成测试会校验此值，防止碰用户普通凭据。两实际实例验收可分别编译 `DEVICE_SLOT=t12-owner` 与 `DEVICE_SLOT=t12-member`。槽不是权限或凭据，只隔离本机验收身份。

## 配对协议与请求边界

第一台设备已连接 OpenRouter 后，使用产品首次设置提供的一次启用码建立原设备身份。此码是 256-bit 随机的一次授权能力，只允许初始设备登记；它不是 Cloudflare 账户 token。服务仅持有 SHA-256 值，唯一原设备约束和幂等登记防止重复建立原设备。Cloudflare 管理 token 永远只属于制作阶段操作员。

原设备随后生成 128-bit 随机配对 ID 与 256-bit 随机秘密。App 显示 `noteagent-pair://join?...#secret`，含短期服务地址与秘密片段。用户直接传给自己的另一台 App；秘密不出现在 HTTP URL、请求体或服务器日志中。

1. 原设备以自己的 bearer 创建五分钟配对记录。服务只接收从秘密派生的一次认领 token 的 SHA-256。
2. 新设备先把身份、随机 bearer 与未完成配对秘密持久化到自己的系统安全存储，再发送派生认领 token、设备名和 bearer 的 SHA-256。原子状态条件只允许一名认领者；同一设备可以恢复重试。
3. 两端显示绑定秘密、配对 ID、目标设备 ID、目标 bearer 哈希的六位验证码。原设备明确勾选已核对相同验证码后才能批准；App 再检查一次当前目标，阻止目标变化。
4. 原设备用 HKDF-SHA-256 从 256-bit 秘密派生 AES-256-GCM key。密文只包含版本、配对 ID、目标设备 ID 与普通 OpenRouter Key；AAD 绑定配对 ID、目标 ID、目标 bearer 哈希。服务端拿不到解密 key，修改密文／目标会校验失败。
5. 仅目标 bearer 可取密文。新设备校验目标并把 Key 与恢复凭据写入系统安全存储后才确认。D1 的事务批处理同时登记 member 和清除密文。确认丢包可幂等重试。
6. 拒绝／过期删除可用密文，配对码不能再次认领。取消未完成接收保留已收到的 OpenRouter Key，并移除未完成的本机设备身份；原设备可重新生成码。

设备 bearer 是每台独立的 256-bit 随机值，服务只保存哈希。owner 只具有本产品配对批准权，member 只允许检查自身身份；没有云账户管理、任意数据库或全库同步权限。后续状态／预算票需要显式增加经过认证的业务路由，不能拿 Cloudflare 管理 token 当 App token。

请求只接受 native JSON，拒绝 Origin、查询串、超出 8 KiB 的体和非 HTTPS（仅显式测试配置允许 loopback HTTP）；响应不缓存。全路由每 IP 每分钟 120 次，首次启用 5 次、认领 8 次、创建配对 3 次。服务错误返回固定码，不回显请求、SQL、Key 或 bearer。部署配置关闭可观察性日志，不包含完整音频存储、队列或其他付费产品。

## 本地验证命令

先安装 `services/pairing` 的锁定依赖。Node 需要在 PATH，或用 `NOTE_AGENT_NODE` 指向本机 executable。

```sh
flutter test
flutter analyze
flutter build macos --debug
cd services/pairing
pnpm test
pnpm run check
```

由主控协调原生界面／凭据提示后，才运行以下已准备测试，不能由多个实现者同时启动：

```sh
flutter test integration_test/connection_secure_store_test.dart -d macos --dart-define=DEVICE_SLOT=t12-native-probe
```

该原生测试只使用临时笔记库、固定假 Key 和 loopback 元数据夹具；不访问真实 OpenRouter，也不证明真实账户连接或远程配对通过。系统安全存储 test slot 最后清除。只有实际运行结果才能升级此处的验证状态。

## 制作阶段部署：待一次账户授权

目前停止在本机可审阅结果；以下是授权后由制作方执行的步骤，不要求用户终端操作，也不是已经部署的记录。

1. 在 Cloudflare 官方流程完成一次账户登录，核实选定账户是 Workers Free。仅创建一个 Worker 和一个 D1；不启用 Paid、R2、DO、队列或计费升级。登录令牌留在操作员环境，保持日志净化，使用工作区缓存日志路径。
2. 在 `services/pairing` 运行 `node tools/prepare-activation.mjs`，把随机首次启用码保存在忽略且权限 0600 的 `.local/activation-code.txt`，不打印到日志或提交。仅把 `.local/activation-hash.txt` 的值写到 Worker 的 `ENROLLMENT_HASH` secret。
3. `wrangler d1 create note-agent-pairing` 取得实际 UUID，更新 `wrangler.toml` 的占位值。审阅迁移后 `wrangler d1 migrations apply note-agent-pairing --remote`，再部署 Worker。以上会使用远程免费额度，必须等账户授权与 Free 核实后执行。
4. 构建 App 时用 `--dart-define=PAIRING_ENDPOINT=https://实际端点`。此参数只有公共端点，没有账户 token。首次启用码通过安全的制作交付进入第一台 App 的遮蔽输入框；日常其余设备只用 App 内配对。OpenRouter Key 由用户只在 App 内输入。
5. 验收两个独立实际 App 实例：第一台检测 Key／首次启用／生成码，第二台请求加入，两端核对验证码，第一台批准、第二台刷新检测连接；正常退出重开后再次检测。分别核对本机库和系统授权没有变化，不能显示笔记已同步。补测取消、失效码、服务离线后恢复。
6. 在真实 Free Worker 上核对 CPU 与 D1 用量、区域网络、超限响应和服务器状态；本机测试不能证明远程 CPU 低于 10ms。通过后删除临时首次启用明文，保留已用 enrollment hash（不会再创建第二 owner）。记录真实 URL、构建和验收证据，才可关闭 #13。

## Free 边界

2026-10-16 再核实官方文档：Workers Free 每日 100,000 请求、每次 10ms CPU；D1 Free 每日 5m 读行、100k 写行、账户总存储 5GB。D1 用尽免费查询额度返回错误，不能自动升级。数据库查询使用身份／哈希／有效期索引，载荷有界；过期配对与请求计数在创建配对时清理。真实 CPU 和个人账户套餐尚待核实。这些是当时额度，不是永久免费保证。

来源：[Workers 定价](https://developers.cloudflare.com/workers/platform/pricing/)、[D1 定价与超限](https://developers.cloudflare.com/d1/platform/pricing/)、[D1 batch 事务保证](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch)、[OpenRouter Key 元数据](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key)、[Apple Keychain](https://developer.apple.com/documentation/security/keychain-services)、[Android Keystore](https://developer.android.com/privacy-and-security/keystore)、[Windows DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)。
