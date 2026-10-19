# T13：共享预算与普通文字整理

本票以 NoteWorkspace 为公开领域入口。已有配对身份继续使用，既有系统凭据服务/账号/设备槽及笔记库授权不变。尚未部署本票 Worker/migration 或执行真实付费模型验收；本地合成边界通过不代表真实云费用验收。

## 使用路径

工作区或设置的“AI 与共享预算”进入面板。先“预估并预留（不调用模型）”，查看冻结费率，再显式确认发送。完成后可在 App 查看/复制 generation 费用编号、已取得的美元费用与最近一次输入/输出 token；未返回的字段显示未知。首次加最多三次自动重试；重试不是免费撤销，每次先独立申请预算。自动重试耗尽后，无可用结果的失败任务可手动另行预留并重试，同一业务笔记保持相同 ID。刷新/核对费用/页面恢复不会重发模型请求。凭据、余额和预算错误不自动重试。

原文、稳定业务 ID、请求、attempt ID 与冻结报价先写本机 SQLite，再请求共享账本；发送状态在请求模型前写入。正文更新使用已有笔记库受保护的替换/改名日志，原始来源文件保留。普通笔记保持正文、关联、来源顺序，没有摘要或可见属性。模型结果必须来自固定型号、单个完整响应、严格来源 ID/JSON 字段/简短中文标题；不明确或涉及行动的结果停在待确认，不由本票创建待办。文件或笔记在处理期间被人修改时，不覆盖新内容。

## 预算口径

默认共享月上限 30 元，仅原设备可在 App 内显式修改，大于零且最多 30 元。月底按澳门自然月（服务端 UTC+8）切换；所有设备读取同一 D1 账本。已结算金额按请求所属月统计；所有月份尚未核清的预留仍占用当前可用额度，绝不通过跨月/超时/重启自动释放。

预付余额和推理消耗分开。普通 OpenRouter Key 无权读取账户 credits；显示“未知”，不请求管理 Key、不把 Key 的 limit_remaining 显示成余额。美元实际费用来自本次 usage.cost 或 generation.total_cost；人民币预算采用该次冻结参考汇率加 10% 汇率余量保守折算，并另留 25% 预留余量。面板显示美元实际费用和人民币保守折算，不能将其表述成银行卡真实人民币扣款。Sync 订阅不包含在 AI 消耗中；充值金额、手续费及官网自动充值设置须用户在官网核对，App 不自动充值、升级或扩大预算。

10%/25%、单次完整请求上限 20,000 UTF-8 字节、输出上限 1,024 token、报价 10 分钟有效、参考汇率最多 7 天，是本次保守实现决策，不声称这些具体数字已由用户逐一批准。预留按完整 JSON 请求字节作输入 token 上界，加 512 token 余量，再计最大输出；向上整数舍入，避免二进制小数出现 +1 nano-USD。服务商异常实际费用超出预留时如实记录、允许剩余额度为负、暂停后来任务，不能剪裁账单制造硬上限保证。其他软件直接使用同一 Key 的消费不在此 App 账本内。

## 固定模型与公开报价

唯一模型 deepseek/deepseek-v4.1-flash。Worker 只读取公开模型 endpoints 与 ECB XML，不接收用户原文或 OpenRouter Key。选择支持当前结构化响应/输出上限/推理参数、在线且不高于输入 $0.60/百万和输出 $2.40/百万的同型号路由；拒绝额外每请求费。请求固定 provider.only，allow_fallbacks=false、require_parameters=true，并设置 max_price，含 request=0。无兼容报价、费率超过此版本上限、汇率过旧/无效时暂停；不静默换型号或放宽价格。报价持久化包含模型、路由、价格、汇率日期/余量及 SHA-256 版本。

ECB 为参考信息，不能保证支付结算汇率；只用于保守预算折算。每次 settle 使用该 attempt 原来的冻结汇率，不能用晚到的最新汇率重算历史。

## 原子性与未知费用

0002_budget.sql 新增预算表，不改/清除 devices、pairing 或既有 schema。单条 INSERT...SELECT 在 D1 内检查共享已结算+所有未结算预留，唯一 attempt/generation 约束防止重复占款/重复收费；并发设备不能各取一份完整剩余额度。重复 prepare 沿用同一操作和尝试；发送通过 reserved→sent 的条件更新仅允许一次。只有未发送 reserved 能释放；sent/uncertain 不能作为取消退款。费用核对可先读取本设备 attempt：账本明确 reserved/released/未准入时才按未发送释放或关闭任务；若发送与释放并发，以 D1 条件更新返回的最终状态为准。

外部推理与 D1 没有跨服务原子事务。模型可能已收到而本机没收到响应时，保留占款；重启不自动重发。若有 generation ID，手动“核对费用”使用普通 Key 的官方 generation 查询，暂时 404/网络错误保持预留。重复相同回执不重复结算；不同回执/同一 generation 被不同尝试使用会阻止新收费任务，不覆盖原账单。没有 generation ID 的未知请求不能凭空证明免费；提示用户核对官网，保留占款。此票不提供未经核实的“清零未知费用”按钮。后续故障支持/人工对账必须保留审计证据，不能自动退款。

服务端共享账本只保存不含原文的预算与设备标识。API Key 保留在原有系统安全存储，直接用于本机到 OpenRouter 的 HTTPS。模型和回执响应不跳转，有大小/网络时间限制；这些网络超时不代表供应商已取消或免费。测试替代仅限显式启用的 loopback HTTP；生产文本 endpoint 固定为 OpenRouter HTTPS。

## 验证和后续人工验收

test/cloud_budget_test.dart 从公开 NoteWorkspace 驱动真实本机文件/SQLite，经本机 Workerd/D1 和合成外部模型、ECB HTTP 边界验证。tools/budget-worker-fixture.mjs 仅本地测试入口替换时钟，生产 Worker 没有该路由。覆盖三端并发、重复准备/结算、重启、跨月、未知账单、有限重试、手动重试、未发送取消、坏格式、凭据失败及人类文件编辑。原配对 HTTP 与全量 Flutter 回归继续运行。

生产迁移/部署、Free 资源与 CPU 实测、真实普通 Key/模型兼容性和实际费用需 root 在独立审查后验证。执行 migration 0002 和新 Worker 前保留既有真实 Owner，不重新 activation。使用原本隔离的远程验收 App/库和正确设备槽，不覆盖在用主 App。首次真实样本先在 App 将月上限降到小额，再预估、确认一次短文字、在 OpenRouter 官网核对 generation 与费用、重复核对不重复消费。未知回执或不支持参数时停止并保留原文/预留，不临时提高额度或改型号。

## 官方资料（2026-10-20 澳门时间复核）

- [模型公开 endpoints](https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints)：动态目录；费率不是永久常量。
- [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection)：only、fallback、参数支持与 max_price；prompt/completion 上限单位为美元/百万 token。
- [账户 credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits)：要求 management key，普通 Key 不适用。
- [Generation 回执](https://openrouter.ai/docs/api/api-reference/generations/get-request-&-usage-metadata-for-a-generation)：按 generation ID 查询 total_cost。
- [ECB 参考汇率说明](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html)与 [XML](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml)：工作日发布，信息参考，不能宣称真实支付汇率。
- [D1 Database API](https://developers.cloudflare.com/d1/worker-api/d1-database/)及 [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)：本地原子性测试不替代远程 Free CPU/配额验收。

本地检查（2026-10-20，已合入 integration9981 的手机历史修复）：135 项 Flutter 全量测试通过，其中15项预算工作区测试；analyze 无问题；原配对 HTTP 5 项、Prettier 与隔离 Wrangler4.151.0 dry-run 均通过。Worker25.01KiB，gzip6.38KiB。无远程部署和真实推理记录；Mac 同身份更新包另以固定提交归档、源码差异及实际签名清单交付，构建不启动 App。
