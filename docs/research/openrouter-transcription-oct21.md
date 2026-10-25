# T17 前置研究：OpenRouter 录音转写

核对日：2026-10-21（Asia/Taipei）。本报告只调查公开接口，不实现 T17，不代表真实上传、普通话质量、费用或长录音验收通过。本次未读取用户录音、App 数据或凭据，未调用任何收费模型。

## 结论与规格约束

不可变规格第 143 行的候选 `openai/whisper-large-v3-turbo` **当前真实存在**，输出模态为 `transcription`；它使用专门的转写接口，并非只能在聊天接口输入音频。当前无需为“候选不存在”而换模型。[公开转写目录](https://openrouter.ai/api/v1/models?output_modalities=transcription)、[候选模型页面](https://openrouter.ai/openai/whisper-large-v3-turbo/api)。

保持一个 OpenRouter 账户、一份普通 Key；文字整理继续固定 `deepseek/deepseek-v4.1-flash`。用户故事 21—23 要求简体中文、原音保留、完整转写可找回；转写不能以摘要替代。普通话、简繁体、数字与待办关键时间识别均尚待实际样本验收。模型页面的多语言或速度宣传不构成本产品质量证明。

**最大实现差异是路由与价格约束**：不能直接复制 T13 聊天接口的固定 provider、禁止 fallback 或 `max_price` 机制，宣称转写也具备相同的远程价格封顶。当前 STT 文档明确 `order`、`only`、`ignore` 不应用；本次取得的 STT OpenAPI 中 provider 仅列 `zdr`、`data_collection`、`options`，未列 `max_price` 或 `allow_fallbacks`。[STT 文档](https://openrouter.ai/docs/guides/overview/multimodal/stt)、[转写 OpenAPI](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md)。

## 已确认的请求契约

| 项目 | 当前公开契约 |
| --- | --- |
| 地址与认证 | `POST https://openrouter.ai/api/v1/audio/transcriptions`；`Authorization: Bearer <普通 OpenRouter Key>`，与聊天相同认证 |
| JSON | `Content-Type: application/json`，`model` 和 `input_audio` 必填；内联音频为 `input_audio.data` 原始 base64 字符串及匹配的 `format`，不加 data URI 前缀 |
| 文件上传 | 支持 OpenAI 形状的 multipart：`file`、`model`，可加 `language` 等字段 |
| 输出 | 默认 `response_format: json`；`verbose_json` 视 provider 能力增加时间段等信息；`text`、`srt`、`vtt` 格式不支持 |
| 中文提示 | `language` 接收 ISO-639-1，故中文提示应为 `zh`；这不保证输出简体，也不承诺无漏字 |

来源：[请求参考](https://openrouter.ai/docs/api/api-reference/stt/create-transcription)。上表是公开契约核对；真实候选对参数的接受情况尚未执行。首版建议先请求完整 `text`，不要额外开启 diarization/keyterms 等可产生附加费用、候选未承诺支持的选项。

SDK 可直接接入：官方 TypeScript 客户端有 `stt.createTranscription`、`createTranscriptionMultipart`，Python 客户端有对应 snake_case 方法；既有 OpenAI 客户端可改 base URL 为 `https://openrouter.ai/api/v1` 使用文件上传。Flutter 不必增设另一个账户或运行 Python：可由已有本机 HTTPS 适配器构造同一公开 HTTP 请求。这是实现建议，不是已验证的 Dart SDK 能力。[TypeScript SDK](https://openrouter.ai/docs/client-sdks/typescript/sdks/stt/README.md)、[Python SDK](https://openrouter.ai/docs/client-sdks/python/sdks/stt/README.md)。SDK 暴露重试配置，接入时必须禁止绕过 App 预算的隐式自动重发。

## 容器、体积、十分钟与超时

当前 STT 文档列出 `m4a`（`audio/mp4`）、`aac`（`audio/aac`）、WAV、MP3、FLAC、OGG、WebM，且明确具体 provider 支持有差异。M4A 是容器，不能把其中 AAC 音轨误标为裸 AAC；应依据原文件真实容器声明。Groq 官方明确接收 M4A、WAV、MP3，但这不证明经 OpenRouter 自动选到的每条路由均接受本产品的实际编码文件。[STT 格式表](https://openrouter.ai/docs/guides/overview/multimodal/stt#supported-audio-formats)、[Groq 文件限制](https://console.groq.com/docs/speech-to-text#audio-file-limitations)。

| 边界 | 已确认事实或计算 |
| --- | --- |
| 5 MB | 不是本次找到的 OpenRouter 全局 STT 上限；不要把旧研究中的 5 MB 当 API 定律 |
| multipart | 公开上限 25 MB；不要用 Groq 自家 dev tier 的 100 MB 推导 OpenRouter 也支持 |
| 更大内联 JSON | 当前主文档只为部分 OpenAI/Groq 路由说明可超过 25 MB；其他 provider 仍可能拒绝。不能据此承诺该候选全部路由均可大文件上传 |
| 十分钟 | 没有找到该候选公开的“最多十分钟”或保证十分钟完成的承诺。音频长度和处理耗时是两回事 |
| 超时 | STT 主文档写上游约 60 秒处理超时，不是 60 秒音频长度限制。真实十分钟是否在时限内尚待测 |

来源：[当前 STT 上传与处理限制](https://openrouter.ai/docs/guides/overview/multimodal/stt#openai-compatible-multipart-requests)。计算示例（非测量）：本仓库 Android 录音目标 32 kbit/s 的 600 秒 AAC 约 2.4 MB，加容器开销；base64 约增至 4/3。WAV 若为 16 kHz、16-bit、单声道，600 秒约 19.2 MB；若为 22.05 kHz 则约 26.46 MB，可能跨 multipart 上限。实际文件仍以元数据、字节数与解码验证为准；不能由时长推定体积。

**官方资料存在新旧差异**：2026-09-24 更新的博客仍写“不支持音频 URL、不能指定 data policy”；当前主文档及 OpenAPI 已列 `input_audio.url`、`provider.zdr` 与 `data_collection`。本报告按当前主文档/OpenAPI记录；URL 仍须模型/provider 支持，且没有必要为本 App 把私人音频公开托管。研究不建议 URL 上传路径。[旧博客](https://openrouter.ai/blog/tutorials/transcription-on-openrouter/)、[当前 OpenAPI](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md)。

接口返回一次同步 JSON；本次未找到专用 STT 的异步 job 提交/轮询契约。`X-Generation-Id` 是费用追踪号，不是可轮询恢复转写正文的 job ID。客户端超时或断线也不能证明上游未处理、免费或已取消。后续若分段，应保留原音、段顺序/范围、各段结果与费用；只补失败段，不重新发送已成功段，重叠音频也应计入预留。这些是产品设计建议，分段长度与是否首版必需需真实长样本后判断。[同步流程说明](https://openrouter.ai/blog/tutorials/transcription-on-openrouter/)。

## 当前价格、回执与预算风险

2026-10-21 05:47 UTC 无凭据 GET 的候选 endpoints 结果：

| 路由 | `pricing.prompt` | 计价口径 | 600 秒纯转写算例 |
| --- | --- | --- | --- |
| `deepinfra/us` | `0.00000333` | USD / 音频秒 | USD 0.001998 |
| `groq` | `0.0000111111111111` | USD / 音频秒 | 约 USD 0.00666667 |

来源：[OpenRouter 实时候选 endpoints](https://openrouter.ai/api/v1/models/openai/whisper-large-v3-turbo/endpoints)。Whisper 的 `prompt` 在这里表示音频秒价，不能按文字 token 单价换算；Groq 自家公布每小时 USD 0.04、最低计费 10 秒，DeepInfra 自家公布每分钟 USD 0.00020，与此数量级一致，但自家约束是否逐项透传至 OpenRouter 不能代替真实回执。[Groq](https://console.groq.com/docs/speech-to-text)、[DeepInfra](https://deepinfra.com/openai/whisper-large-v3-turbo/api)。这是瞬时公开研究价，不是固定报价；没有调用、充值或收费操作。

**回执能力与未承诺项分开**：

- 当前 STT 参考描述 `usage.cost` 为 USD 实际费用，并描述 `usage.seconds` 及 token 字段；主文档另列 `X-Generation-Id` 响应头。没有文档保证响应正文存在聊天形状的 `id`。[响应字段与头](https://openrouter.ai/docs/guides/overview/multimodal/stt#response-format)。
- OpenAPI 的 `STTResponse.required` 只有 `text`，`usage` 和它的 `cost` 不是必填。因此不能在成功转写但缺失费用时补零结算，也不能声称每次必得回执编号。[STT schema](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md)。
- 官方通用 `GET /api/v1/generation?id=…` 接收 Bearer Key，返回 `total_cost` 等元数据。结合 STT 的 generation 响应头，**可以设计为用该号核对费用**；但本次没有真实 STT 请求，尚未验证 STT generation 是否可查询、何时可见、与 `usage.cost` 是否一致。不能将 T13 聊天实测记为转写实测。[Generation 查询契约](https://openrouter.ai/docs/api/api-reference/generations/get-request-&-usage-metadata-for-a-generation)。

**建议，非接口保证**：冻结当前全部已知可路由 provider 的最高已知秒价、计费时长余量、汇率与报价版本；目录出现未知单位/额外费用/未知路由或报价失效则拒绝准入。保留与 T13 相同的共享账本原子预留及 sent/uncertain 占款机制，每次重试独立预留，不因重启/超时/月切释放；费用核对不重发录音。若实际费用超预留，如实记账并暂停后续准入。

以上只能降低风险：STT 没有已证实的服务端 `max_price` 或 pin-provider 契约，预留到发送之间的价格/路由变化仍可能超报价，不能宣称硬封顶。新路由、请求内 fallback 次数与最低计费取整也需核实，不能将“全部已知路由最高价”当成所有未来路由的证明。收费确认页应如实显示这种与文字路径的差别。

若候选以后消失、格式/时限/质量不满足，应在 App 内展示替代模型、价格单位、路由约束与质量待测差别，再由用户确认；不得静默换 `whisper-1`、`gpt-4o-mini-transcribe` 或把音频交给固定文字模型。本次目录中前者 `prompt=0.0001` 秒价，后者 `prompt=0.00000125`、`completion=0.000005` 按 token，不能只比较两个 `prompt` 数字而称后者更便宜。[当前转写目录](https://openrouter.ai/api/v1/models?output_modalities=transcription)。

## 后续适配器与验收建议（尚未实施）

沿用公开工作区入口，增加小型 HTTP 转写适配器，输入为稳定 source ID、原音引用、已核实格式/时长、冻结报价和 attempt ID；返回完整转写、可选用量/费用/响应头编号及明确错误。合成 HTTP seam 覆盖 M4A/WAV/MP3 请求形状与 MIME、格式错配、413/401/402/429、超时、返回非 JSON/超大结果、空文本、缺费用/编号、相互矛盾回执。账本集成覆盖并发准入、原音不动、来源绑定、重启不重发、未知占款、重复对账与超报价暂停。使用合成音频/响应，不让测试依赖真实 Key。

未来经用户在 App 批准后，才用普通话短样本及约十分钟样本核对：原文忠实度、简体输出、时间/数字/专名、开头结尾完整、静音与停顿、处理时限、实际路由与费用、generation 查询、断线未知恢复。保留用户可改的完整转写与原音，后续文字整理另走固定 DeepSeek；不能把转写、摘要和待办提取折为一次不可核对的黑箱操作。

## 公开抓取留痕

本报告唯一持久化研究文稿；不复制旧 catalog 当现状，也不保存任何带凭据请求。

| 无凭据 GET | UTC 时间 | 原始响应字节 | SHA-256 |
| --- | --- | --- | --- |
| `/api/v1/models?output_modalities=transcription` | 2026-10-21 05:47:38 | 27,070 | `9b9566f0b06e6f9b8954d3fd6acd1a45bb8d7b98b98353f6873874711ae7c047` |
| `/api/v1/models/openai/whisper-large-v3-turbo/endpoints` | 2026-10-21 05:47:39 | 2,066 | `89ca1d563479e825c838e05dfd90255a388f484c39b63258938d2f1f200cd760` |

哈希只定位本次动态响应，未声称未来重新 GET 仍相同；实际发起付费前必须重读现价。浏览器抓取 endpoints 曾不可达，本机普通 HTTPS 无凭据 GET 成功；无 TLS 绕过或隐藏账户 API。
