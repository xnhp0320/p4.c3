# SWX parser/deparser：解释器执行模型与可选 C codegen

调研日期：2026-09-26。当前项目采用自己的简易前端，面向 DPDK；本轮研究 SWX 的实现细节，为 header、parser 和 deparser codegen 提供参考。

后续方案讨论见 [基于静态顺序与运行时布局的 header 重构评估](incremental-header-rebuild-evaluation.md)（2026-09-28），其中对照本文的源码事实，分析 action 边界重构的收益、限制与重排扩展。

**2026-09-27 定位修正：SWX 首先是一套报文处理指令解释器。spec 是其目标 IR/汇编式文本表示，包含资源声明；加载时转换成内部指令，再由执行引擎分派。C codegen 是在这个执行模型上提供的可选原生加速路径。此前以“spec → C”为主线，弱化了解释执行这一根本区别。下文保留源码事实与实验结果，同时明确区分解释器机制和直接生成专用代码的编译器优化。**

源码固定为 DPDK `4f795ddd6a1fbdea97b7b254dea6d8f1f837a681`。本文区分三种证据：**源码确认**、**按生成器推导的 C 形态**、**原始 helper 的局部运行实验**。没有执行完整 SWX `.spec → C → 共享库 → 网卡` 链路，也没有性能测量。实验入口与复现方法见 [research/swx-codegen](../research/swx-codegen/README.md)。前一轮架构分析见 [SWX spec 编译边界](swx-spec-pipeline.md)。

## 1. 先抓住四个关键点

1. SWX 的基本执行路径是指令解释：`rte_swx_pipeline_run → instr_exec → instruction_table[ip->type]`。spec 加载时已经解析，逐包运行不重新解释文本。SWX 看不到 P4 parser/deparser AST。
2. `extract` 建立指向原包的 header view，推进 cursor；后续字段操作通过 view 加偏移访问数据。
3. `emit` 记录来源指针和长度，并合并相邻来源。真正的构包通常在 TX 的 `emit_handler` 中发生。
4. 可选原生 codegen 把指令组生成 C，减少组内分派并暴露常量；生成函数仍接回 SWX 的上下文和分派框架。组内确实执行原生代码，不能把这条加速路径也描述成逐条解释。这里没有自动生成针对任意 header 删除/插入/重排的最小移动计划。

## 2. 源码入口与完整调用链

### 2.1 基本路径：装载 IR，然后解释执行

```text
P4 → p4c-dpdk → SWX spec
                    ↓ 解析、布局注册、操作数解析、局部指令融合
               内部指令数组 + 执行上下文
                    ↓ rte_swx_pipeline_run
               取当前 ip → 按 opcode 分派 → 执行 helper
                    ↑ 更新 ip / 跳转 / 切换上下文
```

最直接的源码证据是 [instr_exec](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7783)：

```c
struct thread *t = &p->threads[p->thread_id];
struct instruction *ip = t->ip;
instr_exec_t instr = p->instruction_table[ip->type];
instr(p);
```

[rte_swx_pipeline_run](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L10696) 循环调用它；普通指令 helper 更新 `t->ip`，跳转指令设置目的位置。这些指令 handler 本身由 C 实现，并不意味着每个输入 pipeline 都已编译成独立原生程序。

因此，`structs[]`、指令操作数描述符、有效位图、emit 区间列表，首先应被理解为通用解释器的运行状态。指令融合减少解释分派成本；它与联合分析具体 P4 程序并静态规划构包，是不同层次的工作。直接生成代码也可能保留动态状态，差异在于哪些选择能在编译期专用化，而不是能否出现数组或运行时函数。

### 2.2 可选路径：指令组生成 C，接回执行框架

下面所有链接都固定到同一提交：

| 文件/入口 | 阅读目的 |
| --- | --- |
| [pipeline_spec_parse](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_spec.c#L2861) | 读取声明及指令文本 |
| [pipeline_spec_configure](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_spec.c#L3500) | 注册结构、header、metadata、action/table，配置 apply |
| [instruction_config](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7469) | 指令翻译、标签检查、局部优化、跳转解析 |
| [rte_swx_pipeline_codegen](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14588) | spec 到 C 的总入口 |
| [instruction_group_list_create](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L13936) | 划分原生代码生成的指令组 |
| [instruction_group_list_codegen](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14402) | 生成常量指令数组与 C 函数 |
| [rte_swx_pipeline_build_from_lib](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14682) | 加载共享库，建立 runtime，接入生成函数 |
| [runtime helpers](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1678) | RX、extract、emit、TX 实际做什么 |

```text
rte_swx_pipeline_codegen(spec, C)
  pipeline_spec_parse
    结构/资源声明 → spec 数据结构
    apply/action 指令 → 字符串列表
  pipeline_spec_configure
    注册布局和对象
    instruction_config
      instr_translate → 数值化指令/操作数
      instr_label_check + instr_verify
      instr_optimize
      instr_jmp_resolve
  instruction_group_list_create
  pipeline_spec_codegen + action codegen + instruction group codegen

宿主 C 编译器：生成共享库

rte_swx_pipeline_build_from_lib
  dlopen / dlsym("pipeline_spec")
  配置 I/O 和 spec，build 执行上下文及存储
  dlsym action_*_run / pipeline_func_*
  pipeline_adjust：用生成函数替换多指令组
  rte_swx_pipeline_run：通过指令分派表执行
```

`apply_block_parse` 先保留指令文本，目标指令的检查发生在后面的配置步骤。`instr_verify` 做的是“以 RX 开头、存在 TX、末尾是 TX 或无条件跳转”等结构检查；它不等同于 P4 语义检查，也不构成对所有路径的包长或内存安全证明。

## 3. 数据表示：逻辑 header 与物理地址如何联系

### 3.1 编译/配置时的布局

[struct_type_register](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L127) 累加字段位宽得到偏移；这里没有宿主 C struct 的自然对齐填充。每个字段宽度必须非零且为 8 的倍数。P4 中的非字节对齐字段，需要上游转换后才能进入此表示。

每个 header 有两个编号：`header_id` 索引有效位和 header 描述符；`struct_id` 索引存储指针。`structs[0]` 保留给 action 参数，因此二者不应混用。当前有效性用 `uint64_t` 表示，注册时限制 header 实例数不超过 64。

### 3.2 每个执行上下文的状态

核心结构见 [header_runtime / header_out_runtime](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L232) 和 [thread](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1059)。

| 状态 | 含义 |
| --- | --- |
| `pkt.pkt` / `pkt.offset` / `pkt.length` | 底层 buffer、当前未消费区域的偏移和长度 |
| `ptr` | 当前解析 cursor，正常路径上等于 buffer + offset |
| `structs[struct_id]` | header/metadata/action 参数等结构的当前存储地址 |
| `headers[id].ptr0` | 该 header 预分配的独立存储位置 |
| `headers[id].n_bytes` | header 当前长度，varbit extract 会更新它 |
| `valid_headers` | header 有效位图 |
| `headers_out[]` | 待输出来源区间，含 `ptr0`、`ptr`、`n_bytes` |
| `n_headers_out` | 合并后的区间数量，不等于 emit 指令数量 |
| `header_storage` | 新建 header 可使用的预分配存储 |
| `header_out_storage` | 通用构包路径用来汇集 header 的 scratch |

[header_build](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L1515) 为每个执行上下文分配上述数组和两块存储。每块存储的大小是所有注册 header 的声明大小之和，包含 varbit 声明的最大大小。当前默认有 16 个执行上下文；这不是 16 个操作系统线程，而是 pipeline 内轮换执行的上下文。

这些分配在 build 时发生。逐包 extract 不需要 malloc。`header_storage` / `header_out_storage` 也不在 mbuf headroom 内。

RX 清零 validity 和输出区间计数，设置 cursor；它不会逐包清空所有 header 存储或重置全部 header 指针。之后 extract 或 validate 会建立所需的有效指针。

## 4. Parser：指令翻译与执行

### 4.1 `extract h.a` 的编译结果

[instr_hdr_extract_translate](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L2080) 查找 header，区分固定长度与可变长度，编码：

```text
type       = INSTR_HDR_EXTRACT
header_id  = a 的有效位/描述符索引
struct_id  = a 的存储指针索引
n_bytes    = a 的声明位宽 / 8
```

它没有生成逐字段加载。固定 extract 的语义可概括为下列伪代码，完整 helper 见 [extract_many_exec](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1987)：

```c
structs[struct_id] = ptr;
valid_headers |= 1ULL << header_id;
ptr += n_bytes;
pkt.offset += n_bytes;
pkt.length -= n_bytes;
```

消耗的是逻辑输入区域；底层 mbuf 的 data_off 尚未在这里更新。原 header 字节仍留在原包内，可通过 `structs[]` 访问。

### 4.2 连续 extract 的合并

[extract_many 优化](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7003) 把连续固定 extract 合并为 `EXTRACT2` 到 `EXTRACT8`：

- 最多合并 8 个，由指令描述符数组容量决定。
- 不越过其他操作，也不把可变长 extract 合入此模式。
- 若中间指令是被跳转引用的目标，则停止合并，避免破坏入口。
- helper 在局部变量中累计 cursor、offset、length、validity，循环结束后统一写回。

这降低分派及状态更新的成本。它没有改变每个 header 各自保存一个 view 的表示，也没有执行整头复制。

### 4.3 字段值什么时候加载，字节序怎么处理

执行比较、赋值或 ALU 指令时，才通过 `structs[id] + field_offset` 访问字段。编译/配置时已把符号解析成 id、offset、width，并根据 header/metadata 的字节序选择指令变体。

例如 [jmpeq 翻译](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L5821) 对“header 字段与立即数相等”会预转换立即数，使执行时可用原始加载加掩码比较；字段之间的比较则按操作数组合选择 HBO/NBO 读取。不能把所有比较都理解为逐包调用一次 ntoh。

[字段读取 helper](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1110) 和 [MOV 宏](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1304) 的常见小字段路径使用 64 位加载、掩码、移位；写入保留同一机器字中的其他字节。它们要求额外关注加载范围、对齐和目标平台，不能直接等价为一个安全的窄字段 load/store。

若 view 指向原包，字段写入就修改原包；若指向 header_storage，则修改独立存储。extract 本身无需预先把整头字段解码到 C struct。

### 4.4 varbit 与 lookahead

- [可变长 extract](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2106)：指令保存固定前缀字节数和 metadata 中的长度操作数位置。执行时计算 `固定长度 + 可变部分字节数`，更新 view、cursor 和 `headers[id].n_bytes`。长度操作数单位是字节。
- [lookahead](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2142)：建立当前 cursor 的 view 并设置有效位，不推进 cursor。它不在这里复制出一个独立快照。上游如果需要 P4 表达式的独立值语义，需要相应降低。

## 5. Parser 的跳转如何成为 C

SWX 已经看不到 P4 state；它看到标签、比较跳转和无条件跳转。标签检查记录引用，局部优化完成后解析跳转目标。

[指令分组](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L13936) 先按可能让出执行上下文的操作划分：RX、table、selector、learner、extern 等单独成组；然后进一步切分跨组跳转的目的位置，使其落在组首。

[跳转 codegen](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14138) 根据跳转类型生成条件：

- 组内跳转：直接输出 C `if (...) goto label`。
- 跨组跳转：设置 `thread` 的指令指针，返回分派器。
- 单指令组沿用现有执行函数；多指令组生成 `pipeline_func_N`。

因此它不是“每个 P4 parser state 对应一个 C 函数”，也不是整个 pipeline 必然变成一个没有执行上下文的 C 函数。

## 6. Deparser：从 emit 到具体构包

### 6.1 新 header 如何获得存储

[validate](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2341) 若发现 header 已有效，则保留原来的 view；若无效，则让 `structs[id]` 指向 `headers[id].ptr0` 并置有效。它不复制原包，也不清零整个 header。

[invalidate](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2368) 仅清除有效位。之后重新 validate 会选择独立存储，不能默认仍保留原来的包内 view。

### 6.2 emit 记录了什么

[emit 翻译](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L2271) 把 header 名转换为指令中的 id。[执行 helper](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2165) 随后：

1. 检查有效位；无效则跳过。
2. 从 `structs[id]` 取得当前来源地址，从 header runtime 取得实际长度。
3. 若来源紧接最后一个输出区间，则扩展该区间；否则追加新区间。
4. 保存计数和长度，暂时不复制字节。

合并根据物理地址相邻性判断，与 header 类型、名字没有直接关系；还可跨不同 emit helper 调用合并。`ptr0` 记录区间首个 header 的默认存储地址，最终用于识别新前缀快路径。

### 6.3 emit 与 TX 的指令融合

[emit_many_tx 优化](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7090) 识别最多 8 个连续 emit 紧接普通 `INSTR_TX` 的模式，不能跨越中间被跳转引用的入口。它生成 `EMIT_TX` / `EMIT2_TX` 等指令。

融合后的 [helper](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2250) 依然先调用 emit_many 收集区间，再调用 TX。融合减少指令开销；最终字节搬移策略仍由下面的 emit_handler 决定。

### 6.4 最终 packet build 的三条路径

设 `P = t->ptr`，即解析完成后的剩余 payload 起点；输出 header 总长为 O。通常输出起点是 `P - O`，payload 的物理地址保持不变。[emit_handler](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1754) 的逻辑是：

| 条件 | 数据移动 | offset / length |
| --- | --- | --- |
| 只有一个来源区间，末端恰为 P | 无复制 | offset 减区间长度，length 加区间长度 |
| 两个来源区间，第二段末端为 P，第一段 `ptr == ptr0` | 把第一段 memcpy 到 `P - O` | offset 减 O，length 加 O |
| 其他情况 | 按输出顺序把每个区间复制到 scratch，再把 scratch 整体复制到 `P - O` | offset 减 O，length 加 O |

没有输出 header 时，通用路径循环为空，保留剩余 payload 即可。任意重排进入通用路径时，先汇集全部来源再回写，避免回写覆盖尚未保存的来源；前提是 scratch、输出空间和区间描述符容量均满足需要。

这里没有 per-packet malloc，也没有自动执行最少 memmove 的依赖调度。

### 6.5 emit 的值版本问题

`emit A; 修改 A; emit A` 会记录两次指向来源的地址，第一次 emit 不创建值快照。局部实验得到两个输出都包含修改后的字节。因而，**原始 SWX emit 接口本身没有提供“调用时冻结字节”的保证**。

这是 raw SWX helper 的行为。是否影响某个 P4 程序，要继续追踪 p4c 是否提前保存版本、是否限制这类 deparser；本次不把它判为 p4c 的端到端错误。对我们的设计而言，需要显式追踪 emit 对应的值版本，不能仅记录一个可变 header 指针。

## 7. `ABC → AC` 的完整追踪

完整说明性输入见 [abc-to-ac.spec](../research/swx-codegen/abc-to-ac.spec)。A=4、B=8、C=4 字节，输出端口通过 metadata 设置为 0。

### 7.1 配置与 codegen

按源码推导，三个连续 extract 合并，两个 emit 与 TX 合并，优化后的指令形态为：

```text
0: RX             m.input_port
1: HDR_EXTRACT3   A:4, B:8, C:4
2: MOV_I          m.output_port, 0
3: HDR_EMIT2_TX   A, C, m.output_port
```

RX 单独成组，后面三条构成多指令组。根据生成器可推导出以下 C 函数形态；**这是源码推导片段，不是本次运行完整 SWX codegen 得到的文件**：

```c
void pipeline_func_1(struct rte_swx_pipeline *p)
{
    struct thread *t = &p->threads[p->thread_id];

    __instr_hdr_extract3_exec(p, t, &pipeline_instructions[1]);
    __instr_mov_i_exec(p, t, &pipeline_instructions[2]);
    __instr_hdr_emit2_tx_exec(p, t, &pipeline_instructions[3]);
    thread_ip_reset(p, t);
    instr_rx_exec(p);
    return;
}
```

`pipeline_instructions` 是生成文件中的 `static const struct instruction[]`，包含 header id、struct id、长度、字段偏移等常量。生成的 C 引用 SWX 内部头文件；宿主 C 编译器可内联 helper、传播常量、展开固定次数循环。是否消除所有数组访问或构包分支，必须看实际机器码，不能只由源码形式推出。

### 7.2 逐包地址变化

实验使用 32 字节初始 headroom，8 字节 payload：

```text
原 buffer 偏移：32       36               44       48          56
                [ A:4 ][      B:8       ][ C:4 ][ payload:8 ]

extract 后：views[A]=32, views[B]=36, views[C]=44
            ptr=48, pkt.offset=48, pkt.length=8

emit 后：输出区间 [32,36)、[44,48)，共 2 段

通用构包：A → scratch[0,4)
          C → scratch[4,8)
          scratch[0,8) → buffer[40,48)

最终：pkt.offset=40, pkt.length=16，payload 仍位于 [48,56)
```

原始 helper 实验记录三次 memcpy，总请求字节数为 4 + 4 + 8 = 16。我们的专用计划可用 `memmove(buffer + 40, buffer + 32, 4)`，保留 C 原址；两者都能得到相同的输出字节，但这不是性能测量。

## 8. 构包后如何写回 mbuf

[ethdev RX](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/port/rte_swx_port_ethdev.c#L113) 将 mbuf 的 buffer、data_off、pkt_len 交给 SWX。解析期间操作的是 `rte_swx_pkt` 和 cursor。

[ethdev TX](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/port/rte_swx_port_ethdev.c#L263) 按长度变化调整首段 data_len，再更新 pkt_len 和 data_off：

```c
m->data_len = (uint16_t)(new_pkt_length + m->data_len - m->pkt_len);
m->pkt_len = new_pkt_length;
m->data_off = (uint16_t)pkt->offset;
```

这里保留后续 segment 的关联，不能简单说整个报文必须只有一个 segment。但 header view、字段加载和回写没有跨 segment 游标，因此被访问/移动的区域仍需要连续可访问；首段是否容纳相应范围必须单独考虑。

加载共享库时，[pipeline_adjust](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14534) 把多指令组替换成自定义指令，分派表指向生成函数；单指令组保留已有 helper 路径。因此，原生生成与 SWX 分派/上下文模型是组合使用的。

## 9. 实验结果与能力边界

实验直接调用固定源码中的 helper，使用缩减结构与合成报文，ASan/UBSan 下断言全部通过。各案例只统计 emit_handler 内调用 memcpy 的请求量，结果见 [原始输出](../research/swx-codegen/results.txt)。

| 输出布局 | 合并后区间数 | memcpy 次数 | 请求复制字节 |
| --- | ---: | ---: | ---: |
| ABC | 1 | 0 | 0 |
| BC，删除前缀 | 1 | 0 | 0 |
| AC，删除中间 B | 2 | 3 | 16 |
| AB，删除最后一个 header C | 1 | 2 | 24 |
| XABC，增加新前缀 | 2 | 1 | 4 |
| AXBC，中间插入 X | 3 | 4 | 40 |
| BAC，交换前两个 header | 3 | 4 | 32 |
| 只保留 payload | 0 | 0 | 0 |

其中 AB 虽然只有一个连续来源区间，但末端不连接 payload，因此也走通用路径。这说明是否有连续来源与是否可以直接复用输出位置，是两个不同条件。

另外验证了：lookahead 不移动 cursor；可变长 extract 用固定长度加 metadata 字节数；重复 validate 保留有效 view，invalidate 后 validate 切换到独立存储；emit 延迟读取来源字节。

需要明确的边界：

- **短包检查：** 固定/可变 extract helper 中没有包长判断。实验设置逻辑 length=2 后执行 extract 4，得到 `4294967294`，说明该处是无检查的无符号减法。未测试完整编译链是否添加上游保护。
- **输出空间：** emit_handler 直接写 `ptr - O`，未在此检查 headroom、可写性或共享 buffer 所有权。
- **字段加载：** 小字段通用路径存在 64 位访问；逻辑字段在包内不代表整个机器字访问都安全。
- **容量：** 输出区间数组按 header 实例数分配，scratch 按声明大小之和分配。重复 emit、动态长度等必须另外证明不超容量；本次重复 emit 用例刻意保持在容量内。
- **编码宽度：** `instr_io.hdr.n_bytes[]` 是 8 位槽，固定 extract 翻译时把长度赋给该槽；复用此格式时需要核对范围检查，不能认为任意大 header 都可直接表示。
- **语义版本：** raw emit 和 lookahead 是 view 操作，不能直接推导完整 P4 的快照/值语义已经得到保证。

这些是确定的局部实现及集成前提，不是对整个 SWX/P4 工具链的完整安全审计。

## 10. 对自研 codegen 的具体启发

| SWX 机制 | 可以借鉴 | 我们仍需解决 |
| --- | --- | --- |
| extract 保存 view | 避免默认整头物化 | 安全读取、别名与值语义、按需标量化 |
| 描述符中的布局常量 | 编译期解析名字和偏移 | 尽量直接生成已知偏移，衡量保留描述符的成本 |
| 连续 extract / emit-TX 融合 | 减少重复状态更新和调用 | 不把局部融合等同于全局构包规划 |
| 独立 header 存储 + scratch | 明确原包 view 与新 header 的来源 | 按活跃区间规划空间，而非默认备份全部输出 |
| 来源区间合并 | 识别可复用连续数据 | 计算目标布局、重叠依赖及最小必要备份 |
| 编译与运行时组合 | 动态长度、validity 留到运行时 | 静态已知部分专用化，动态部分保留必要检查 |

本轮实验验证了通用指令 helper 的行为，没有测量解释分派开销，也没有验证 C codegen 产物的最终优化。后续应围绕本项目的具体问题区分三类对照：SWX 解释执行、SWX 可选原生加速、直接生成的专用 DPDK 代码。是否继续完整构建 SWX，应由对照需求决定；已有 C codegen 功能本身不足以把 SWX 定为最接近本项目的编译器路线。
