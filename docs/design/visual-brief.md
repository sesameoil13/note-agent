# 刚体 / RIGID BODY — 概念图生成简报

**读者**：负责生成概念图的 agent（人类、模型均可）。
**产出**：一组风格统一的产品概念图，用于一个笔记类 app。
**本文件是唯一事实来源**：规格、色值、材质、提示词模板都在这里。不要自行发明色值或材质，不要从其他来源补风格。

---

## 0 一句话

> 世界是 **8px 的离散晶格**，所有东西都是被铸造出来的实体。
> **像素不是怀旧滤镜，是制造公差。**

方向代号 **刚体 / RIGID BODY**。标语：**低分辨率，高密度。**

这不是"复古像素游戏"，是"工业级低分辨率渲染"。区分这两者是本简报的全部意义。

---

## 1 怎么用这份文档

1. 读第 2 节（一致性锚点），确认每个 prompt 都会原样粘贴它。
2. 读第 3–7 节（规格）。规格即约束，不是建议。
3. 从第 9 节挑一个镜头，按第 10 节的模板拼出 prompt，用第 8 节的负向词收尾。
4. 生成后过第 11 节的验收清单。**每一条都必须勾上**；有任一条不合格就重生成，不要交付勉强合格的图。
5. 全部镜头生成完后，把它们并排看一遍：如果它们不像同一个人在同一天做的，说明锚点被稀释了，回去补齐。

**完成标准**：第 9 节清单中的每个镜头，都有一张通过第 11 节全部 10 项验收的图。

---

## 2 一致性锚点（每个 prompt 原样粘贴，不改写）

这四行是跨镜头、跨 agent 保持统一的关键。任何改写都会导致风格漂移。

```
RENDER: hard-edged 8px lattice quantization, orthographic flat composition,
        no anti-aliasing, strokes only 1px / 2px / 4px, flat solid fills,
        dithered tone steps only, absolutely no gradients
LIGHT:  single hard directional key light from upper-left 45°, hard-edged
        2px offset shadow with no blur, matte industrial finish, no specular
PALETTE: base #101215 #1C2024 #EDE7DB #767C82, exactly one accent clash pair
         from the sanctioned list, ratio 70/20/8/2
FEEL:   brutalist product-design realism, precision-machined, restrained and
        confident, generous intentional negative space, quietly unsettling
```

**一句话记忆点**：*hard-edged, matte, quantized, rationed color.*

---

## 3 三条渲染铁律

机械地保证不落入卡通感。这三条没有例外。

### 铁律一 · 零形变律
任何物体在被撞击、被拖拽、被放下时，**形变恒为 0%**。
卡通感的根源是挤压拉伸（squash & stretch）。力量只通过**位移 + dither 尘粒 + 定格帧**表达。
→ 在静止画面里：物体是刚硬的，边缘笔直，**没有一处鼓起或凹陷**。

### 铁律二 · 晶格从属律
一切位置、尺寸、间距、描边都必须是 8 的整数倍。
描边只有 **1 / 2 / 4** 三档，**永远不用 3**。
圆角只有 **0** 和 **8px** 两档，没有"稍微圆一点"。
→ 在静止画面里：所有边缘都落在同一条隐形网格上，视线能感觉到秩序。

### 铁律三 · 容器 8-bit，内容高清律
**用户写的正文和插入的图片，绝不做像素化、绝不做抖动。**
量化只发生在"壳体"上——边框、按钮、面板、图标、状态。
→ 这个对比是本方案最高级的一处：文字是严肃清晰的，只有包裹它的机器是低分辨率的。它同时杀死了卡通感。

---

## 4 色板

### 4.1 基座（占画面 70%）

| 名称 | Hex | 用途 |
|---|---|---|
| 石墨 GRAPHITE | `#101215` | 主背景。冷调近黑，**不要纯黑** |
| 板岩 SLATE | `#1C2024` | 容器、分区、抬升面 |
| 骨白 BONE | `#EDE7DB` | 正文墨色。暖白，**不要 #FFFFFF** |
| 尘 ASH | `#767C82` | 元数据、禁用态、次级信息 |

### 4.2 强调（占画面 30%，六选一二）

| 名称 | Hex | 唯一含义 |
|---|---|---|
| 酸 ACID | `#CDFF3A` | 焦点 / 选中 |
| 氧化 OXIDE | `#FF4A18` | 危险 / 删除 / 逾期 |
| 群青 ULTRA | `#2740FF` | 链接 / 引用 |
| 陶瓷 CERAMIC | `#35D0C0` | 同步 / 连接 |
| 碘 IODINE | `#7A3FD1` | 标签 / 自动生成 |
| 硫 SULFUR | `#FFC61A` | 时间 / 优先级 |

**颜色的唯一职责是表达功能状态。装饰性用色即俗气。**

### 4.3 允许的撞色配对（**一屏只允许一对**）

1. `酸 #CDFF3A` × `氧化 #FF4A18` — 招牌撞色，刺但不艳。**默认选它**
2. `群青 #2740FF` × `酸 #CDFF3A` — 冷电对毒绿
3. `陶瓷 #35D0C0` × `氧化 #FF4A18` — 工业安全色
4. `碘 #7A3FD1` × `硫 #FFC61A` — 只用于空状态与大标题

### 4.4 配比律 70 / 20 / 8 / 2

70% 基座 ／ 20% 单一主强调 ／ 8% 第二撞色 ／ 2% 纯骨白高光。
**撞色是稀缺资源。** 均匀撒色是最典型的俗气来源。

---

## 5 材质词表（六种，不增不减）

材质即语义。一种材质对应一种唯一含义，绝不做纯装饰。

| 材质 | 物理行为 | 语义 | 画面特征 |
|---|---|---|---|
| **铸铁** Cast Iron | 重、低弹、高摩擦、闷响 | 正式笔记 | 哑光深灰块面，边缘有 1px 高光棱线 |
| **磁石** Magnet | 相互吸引、自动对齐格点 | 标签 / 关联 | 深色块面带极细的极性刻线 |
| **干砂** Dry Sand | 会流、有休止角、不稳定 | 未保存草稿 | 用 25%/50%/75% dither 堆出的倾斜堆体 |
| **玻璃** Glass | 脆、沿晶格碎裂 | 删除 / 危险 | 沿 8px 格裂成方块的碎片，棱边为骨白 1px |
| **沥青** Bitumen | 缓慢下沉、可回拉、自愈 | 归档 | 极暗的块体，底部有拉丝状的黏滞拖尾 |
| **弹簧钢** Spring Steel | 蓄力、单次回弹 | 待办 / 勾选 | 细长条，受压处有等距的 4px 折线 |

---

## 6 光与质感

- **单一硬光源**，永远从左上 45°。
- 阴影 = **1px 硬边偏移块**（偏移 2 或 4px）。**不模糊、半透明不可见、不发光。**
  这是"丝网印刷式错版硬影"，不是投影。
- **无高光、无辉光、无玻璃反光、无镜头光晕、无景深虚化。** 表面一律哑光工业质感。
- **Dither 是唯一的色阶系统**，四档，全部以 8px 为单元格：
  `25% 疏点` / `50% 棋盘` / `75% 密点` / `100% 实心`
  用于表达高度、禁用、衰变。
- **dither 永不出现在文字下方。**

---

## 7 字体

| 层级 | 字体 | 规格 |
|---|---|---|
| 正文 | 工业 grotesk（Inter Tight / Söhne / Neue Haas） | 16px，行高 24px |
| 元数据 / 数值 / ID | 等宽（ABC Diatype Mono / NB International Mono） | 12–13px |
| 显示 / 空状态 / 大数字 | 超粗 grotesk，全大写，字距 -2% | 24 / 32 / 48 / 64 |

**像素感来自渲染规则，不来自字体。**
小字与数字上允许因 hinting 自然产生的 1px 直角——那是"精密"，不是"复古"。

---

## 8 负向提示词（每次生成都要带上）

图像模型对排除项敏感，这一块是硬护栏。同时记住正向目标是：**hard-edged, matte, quantized, rationed color.**

```
AVOID: cartoon, cute, mascot, smiling face, rounded corners, pill shapes,
soft blurred shadow, gaussian blur, glow, bloom, lens flare, bokeh,
depth of field, CRT scanlines, retro arcade cabinet, pixel font, bitmap
display font, Press Start 2P, VT323, chiptune aesthetic, 8-bit game
screenshot, gradient, neon, synthwave, magenta and cyan duo, vaporwave,
pastel, NES palette, glossy plastic, chrome, brushed metal sheen,
isometric voxel, minecraft, low-poly 3D render, skeuomorphic paper,
sticky notes, hand-drawn doodles, washi tape, grunge texture, film grain,
photorealism, hyperrealistic, 4k octane render
```

**关于文字**：不要指望图像模型生成可读的中文。让正文区域保持为**清晰的暖白字形块**（形似文字但不必可读），或直接留白。可读的标签只保留短英文/数字，如 `NOTE 0417`、`ARCHIVE`、`SYNC`。

---

## 9 镜头清单

每个镜头给：编号、画面意图、指定材质、指定撞色对、建议画幅。

| # | 镜头 | 画面意图 | 材质 | 撞色对 | 画幅 |
|---|---|---|---|---|---|
| 01 | **主界面 · 晶格重力** | 笔记列表，卡片按质量沉降在格点上，疏密不均 | 铸铁 | 酸×氧化 | 16:10 |
| 02 | **拖拽中** | 一张铸铁卡悬停在两格之间，下方是落点预览与 dither 尘粒 | 铸铁 | 酸×氧化 | 16:10 |
| 03 | **删除确认** | 卡片沿晶格裂成 8px 方块正在下落，氧化色警告边 | 玻璃 | 氧化×骨白 | 16:10 |
| 04 | **标签磁合** | 数枚磁石标签正被吸附到格点，吸附范围以 dither 显现 | 磁石 | 碘×陶瓷 | 1:1 |
| 05 | **草稿塌落** | 未保存内容堆成有休止角的砂堆，底部正在溢出 | 干砂 | 酸×骨白 | 16:10 |
| 06 | **归档下沉** | 面板缓慢沉入下方，底部有黏滞拉丝，格状进度条 | 沥青 | 群青×酸 | 16:10 |
| 07 | **待办回弹** | 一条弹簧钢待办被勾选，回弹至定格帧，等距折线受压 | 弹簧钢 | 酸×氧化 | 1:1 |
| 08 | **搜索磁扫** | 结果从格点逐个弹出点亮，顺序即相关度，未及处为暗格 | 磁石 | 酸×氧化 | 16:10 |
| 09 | **编辑器 · 高清对照** | 8-bit 壳体包裹全然清晰的正文，示范铁律三 | 铸铁 | 骨白×群青 | 16:10 |
| 10 | **材质谱系板** | 六种材质并置的规格图，各带名称与物理注记 | 全部 | 单色基座为主 | 3:2 |
| 11 | **色板与撞色板** | 四个基座色块 + 六个强调色块 + 四组配对示例 | — | 全部（作为样本） | 1:1 |
| 12 | **空状态** | 全屏几乎空白，一个巨大全大写标题，极克制的负空间 | 铸铁 | 碘×硫 | 16:10 |

---

## 10 Prompt 模板

把方括号槽位按第 9 节的表格填好，再接第 2 节锚点与第 8 节负向词。

```
[SHOT]
<subject, one sentence — 来自第 9 节的"画面意图">

[COMPOSITION]
<画幅> aspect ratio. Orthographic flat composition, brutalist layout,
confident use of negative space, graphic hierarchy carried by scale and
solid fills rather than surface detail.

[MATERIAL]
<第 9 节指定的材质及其画型特征>

[CONSISTENCY ANCHOR]
RENDER: hard-edged 8px lattice quantization, no anti-aliasing, strokes only
        1px / 2px / 4px, flat solid fills, dithered tone steps only, no gradients
LIGHT:  single hard directional key light from upper-left 45°, hard-edged 2px
        offset shadow with no blur, matte industrial finish, no specular
PALETTE: base #101215 #1C2024 #EDE7DB #767C82, exactly one accent clash pair
         (<配对>), ratio 70/20/8/2
FEEL:   brutalist product-design realism, precision-machined, restrained and
        confident, generous intentional negative space, quietly unsettling

[TYPE]
Industrial grotesk for display in uppercase, monospace for numerals and IDs,
crisp fully legible body text inside the panels. Quantization applies to the
chrome and the containers, never to the user's own content.

[AVOID]
<粘贴第 8 节全文>
```

---

## 11 验收清单

每张图逐条过。**任何一条不合格，重新生成，不要交付勉强合格的图。**

- [ ] 1. 所有边缘落在 8px 网格上，描边只有 1 / 2 / 4px
- [ ] 2. 画面中**没有任何一处**挤压、拉伸、鼓起的形变
- [ ] 3. 阴影是硬边偏移块，**没有一处模糊**；无辉光、无光晕、无景深
- [ ] 4. **没有线性渐变**；明暗过渡只由 dither 点阵承担
- [ ] 5. 同屏**只有一对**强调撞色，且落在允许的四组之内
- [ ] 6. 强调色仅在状态变化处出现，没有均匀撒色
- [ ] 7. 出现**像素字体**了吗？出现即废
- [ ] 8. 用户正文保持清晰，未被像素化或抖动（镜头 09 尤须确认）
- [ ] 9. 材质与语义一一对应，未出现第 5 节之外的材质
- [ ] 10. 整体感觉是**精密工业**，而不是可爱、怀旧或热闹

---

## 12 出处与坐标

色彩与质感方法论取自 Bungie《Marathon》(2026) 的 "graphic realism" 美术方向，官方美术负责人的三条支柱为 **product design realism / graphic design boldness / Marathon weirdness**，内部口号 "make weird cool"，并明确采用 **restrained palettes, purposeful accents** 与 **coherence, not simulation**，以标签、标记、图案和图形层级建立可读性而非表面复杂度。

- [Bungie Marathon Art Blast — ArtStation Magazine](https://magazine.artstation.com/2026/06/bungie-marathon-art-blast/)
- [Marathon (2026) video game — Fonts In Use / Abstract Fonts](https://news.abstractfonts.com/fontsinuse/marathon-2026-video-game)
- [Bungie's art director explains Marathon's controversial new look — Creative Bloq](https://www.creativebloq.com/3d/video-game-design/bungies-art-director-explains-marathons-controversial-art-style)

**本简报只借用其方法论，不复制其资产、字体或具体配色。** 上文色值为本项目自定。
