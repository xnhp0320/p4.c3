# v0 子集定义与第一阶段实施计划（草案）

日期：2026-10-08。本文记录讨论收敛后的 v0 语言子集、`extract_end` 扩展语义与实施顺序。
它是设计的起点而非终点；任何条目的修改都应同步更新本文。
上位定位见 [project-vision.md](project-vision.md)，方案背景见
[incremental-header-rebuild-evaluation.md](incremental-header-rebuild-evaluation.md)
与 [parser-deparser-plan-review.md](parser-deparser-plan-review.md)。

## 1. 决策记录

**前端：** 自研 C3 前端，不依赖 p4c。词法/语法解析已有；语义分析只实现 v0 子集所需的最小集合。
复用 p4c（JSON IR 桥接）是两个明确触发条件出现时才重新讨论的备选：

1. 需要运行标准 benchmark 程序（v1model/PSA 规模）以支撑“接近手写 C”的性能声明；
2. 差分测试中自研前端的语义 bug 开始伪装成 planner bug（桥接同时充当语义对照）。

两个前端共存的前提是共享同一份布局规划 IR；下游不接触 AST。

**扩展规则：** 任何语言扩展必须保持可静态分析性——不引入指针、无界循环之外的别名机制、
不透明的运行时决定输出结构。扩展优先用 extern + annotation 表达，语法扩展是最后手段。

**核心创新不变：** 基于程序级布局/值分析的构包代码生成，目标是性能接近手写 C 并优于
SWX 的通用 gather 路径。衡量对象是与手写 C 在相同报文行为下的对比，而非与 SWX 解释路径的对比。

## 2. v0 语言子集

子集是**设计出来的语言边界**，不是"目前碰巧能解析的部分"。子集之外的程序必须得到明确诊断，
不允许静默降级为错误代码。

### 2.1 Header 类型

- 字节对齐的定长 header（`bit<W>` 字段，W 为 8 的倍数）。
- 有界 header stack：元素数静态有界，每个元素是独立实例；`emit(hdr.stack)` 按下标顺序
  输出全部 valid 元素。
- varbit header：实际长度为运行时值，记入 packet ctx。v0 按字节处理 varbit 内容。

### 2.2 Parser

- State/transition 直接翻译为 label/goto。
- **允许回边（循环解析路径）**，退出条件可以依赖报文数据；每次提取保留边界检查，
  短包进入 reject 路径。
- 同一变量跨迭代重复 `extract`：按 spec 语义，变量持有**最后一次**提取的值；
  此前各次消费的字节仅计入 cursor 推进。被消费但未被 emit 的字节不自动进入输出。
- 需要保留全部迭代的结构化内容时用 header stack；需要保留原始字节区域时用
  `extract_end`（见 §3）。
- Parser 消费终点（cursor）独立记录，不能由"存活 header 长度之和"推算 payload 锚点。

### 2.3 Deparser：guarded emit

Deparser 是**直线 emit 序列**，每个 emit 带一个可选条件（guard）：

- 隐式规则（spec 语义）：`emit` 对 invalid header 是 no-op。因此输出选择 =
  `valid ∧ guard`，guard 缺省为 true。`if (h.isValid()) emit(h)` 是冗余写法，
  编译器可折叠为无 guard 的 emit。
- 显式 guard 可以引用 deparser 时刻可得的任意值（metadata、header 字段），
  但必须无副作用。
- 每个 header 实例至多 emit 一次。
- 输出顺序固定为声明顺序；guard 只决定存在与否，不改变次序。
- 输出总长度 O 是运行时值（由 valid∧guard 掩码与 varbit 长度决定），
  布局公式 `S' = S + I − O` 不变。

以下情形**不支持并给出诊断**：

- 同一实例重复 emit（需要值版本建模）；
- emit 已被覆盖的旧值（`saved = A; A.f = v; emit(saved)` 这类值版本问题）；
- deparser 中的循环或数据相关的 emit 次序。

### 2.4 提交模型

- **单次提交**：物理重构只发生在 deparser，control 阶段的 ctx 只维护 validity、
  字段值与偏移，不维护物理位置。action 边界的提前重构不在 v0 范围。
- 布局计划采用"固定 payload、只移动受影响前缀"策略与同序区间调度
  （见 incremental-header-rebuild-evaluation.md §6）。
- 不满足同序条件时回退到 gather-to-scratch；回退路径的触发条件必须可生成。

### 2.5 Mbuf 快路径入口条件

对 DPDK direct mbuf，快路径入口谓词为：

- 可写：`RTE_MBUF_DIRECT(m) && rte_mbuf_refcnt_read(m) == 1`
- 连续：parser 消费的 I 字节位于首段内（`rte_pktmbuf_data_len(m) >= I`）
- 容量：增长时 `O − I <= rte_pktmbuf_headroom(m)`

任一不满足即进入定义明确的回退路径。

## 3. `extract_end` 扩展

为循环解析路径保留字节区域的扩展方法（语法上表现为 `packet_in` 的方法，属 extern 级扩展）。

### 3.1 语义

`packet.extract_end(hdr, n)`：

- 从 cursor 处取 n 字节，追加到 varbit header `hdr` 当前内容的**末尾**；cursor 前进 n。
- 对 invalid 的 hdr 首次调用：置 valid，内容即为该 n 字节。
- n 是字节数（v0 按字节处理，不做位级）。
- n 超出剩余报文长度：与 `extract` 相同进入 ParserError 路径。
- 与同一 hdr 的普通 varbit `extract` 混用：允许；普通 extract 的区间视为内容的第一段。

### 3.2 视图化条件（零复制）

累计区域可表示为原报文视图 `(start_offset, len)`，**当且仅当各次追加在源报文中相邻**。
静态可证规则：循环体内，上一次 `extract_end` 结束到下一次 `extract_end` 开始之间消费的
每个字节都被追加到同一累计区。惯用写法：

```p4
state parse_tlv {
    t = packet.lookahead<tlv_len_t>();
    packet.extract_end(hdr.options, 2 + t.len);  // 整个 TLV，含类型/长度头
    transition select(t.type) { 0: accept; default: parse_tlv; }
}
```

lookahead 不移动 cursor，因此各次追加天然相邻。反例（产生间隙，必须物化复制）：

```p4
packet.extract(hdr.tlv_type);                       // 消费但未追加 → 间隙
packet.extract_end(hdr.options, hdr.tlv_type.len);
```

- **连续性由编译期对循环体的静态证明决定，不是运行时检查。** 无法证明时，该累计区
  分配有界 scratch，追加即复制。
- 检测到 gather 模式（可证明不连续）时应给出告警，引导改写为 lookahead 形式：
  输出字节相同，复制成本不同。
- 视图化的累计区**只读**：control 阶段修改其任何字节则先物化。
- `emit` 累计区时按普通区间参与布局规划：视图 → 输入报文的源区间（零复制，
  进入前缀移动机制）；scratch → 生成字节区间。

### 3.3 命名

`extract_end` 字面像"在末尾（报文处）提取"，实际语义是"追加到 header 末尾"。
备选名 `extract_append` / `append`。语义优先于命名，定稿前可再议。

## 4. 参考模型与差分测试（第一个交付物）

先于 planner 实现一个**慢但显然正确**的 deparser：物化每个 valid header，
按 emit 顺序拼接，追加 parser 剩余 payload。它是 v0 语义的可执行定义，也是差分测试的 oracle。

参考模型必须固化以下语义点（各自需要测试用例）：

1. guard 求值与隐式 validity 规则（`valid ∧ guard`）；
2. 循环解析的 last-value-survives 与"消费字节不自动输出"规则；
3. `extract_end`：连续情形（视图路径）与强制 scratch 情形输出逐字节一致；
4. 循环中途短包进入 reject 路径的行为；
5. header stack 按下标顺序 emit。

差分 harness：报文字节输入 → 参考输出与 planner 输出逐字节比较。

## 5. 实施顺序

1. ~~参考模型 + 差分 harness~~ **已实现**（2026-10-08）：字节串解释器（parser 直译 +
   guarded emit deparser + payload 锚定）、子集边界诊断、`p4c3 runref <file.p4> <hex>`
   CLI（输出 `reject` 或输出字节）、`test/refmodel_test.c3` 固化 §4 全部语义点。
   当前限制：control 仅支持直陈语句（action/table 调用给出"超出 v0 子集"诊断），
   差分的 planner 一侧待步骤 3 接入；
2. 最小语义分析：名字解析、位宽解析、常量折叠、validity 跟踪、parser CFG
   （估计 2–3k 行 C3，只覆盖本子集；步骤 1 的解释器已复用其中名字/布局部分）；
3. Planner：固定 payload/前缀移动策略，按变换种类逐个加快路径
   （原样转发 → 前缀删除 → 前缀插入 → 中间增删），每步与参考模型对拍；
4. 测量：与手写 C、SWX helper 在相同报文行为下对比 cycles/packet 与复制字节数。

## 6. v0 明确不做

- 完整 P4_16 类型检查、extern 语义、架构模型；
- action 边界提前重构、header 重排快速路径；
- 位级（非字节对齐）输出的优化路径；
- 跨 segment 报文的快路径；
- 慢路径/控制面描述（远期目标，见 project-vision.md 与讨论记录）。
