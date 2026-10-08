# P4 软件后端调研：extract、deparser 与内存复制

调研日期：2026-09-26。本文围绕 P4-to-C/uBPF 和 P4-to-DPDK 的已有实现，回答包头是否物化、何时复制、如何构包、临时内存放在哪里。技术问题的进一步展开见 [parser/deparser codegen 挑战](parser-deparser-challenges.md)。

2026-09-27 修正 SWX 定位：其本体是报文处理指令解释器，spec 是目标 IR；C codegen 是可选原生加速。比较时必须先区分执行模型，再讨论 helper 算法和复制成本。

本次读取了官方说明和下列固定提交的源码，没有编译、运行或测量这些项目。文中的“已有机制”指源码证据，“本项目机会”指基于源码的推断，不代表已经证明性能优势或原创性。这里将“P4-to-C/uBPF”具体对应到 p4c 的 uBPF 后端。

## 1. 调研对象与结论

| 对象 | 本次固定提交 | 编译路径 | 与本项目直接相关的发现 |
| --- | --- | --- | --- |
| [p4lang/p4c](https://github.com/p4lang/p4c/tree/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11) 的 uBPF 后端 | `4eb5f4d02067` | P4 → C → BPF 字节码 → 用户态 VM/JIT | state → label/goto；extract 生成字段加载；deparser 计算长度差、调用 adjust-head、逐字段发射 |
| [P4ELTE/t4p4s](https://github.com/P4ELTE/t4p4s/tree/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781) | `7cd5bacc7475` | P4 → C + NetHAL → 原生 DPDK 程序 | extract 保存原报文指针；存在跳过重建的路径，以及临时包头区、prepend/adj 和复制分支 |
| 同一 p4c 提交的 DPDK 后端 + [DPDK](https://github.com/DPDK/dpdk/tree/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681) | DPDK `4f795ddd6a1f` | P4 → SWX 目标 IR/spec → 指令解释执行；可选指令组 C codegen 加速 | 通用解释器中已有指针式 extract、相邻 emit 合并、封装/解封装快路径和预分配 scratch |
| [Orange-OpenSource/p4rt-ovs](https://github.com/Orange-OpenSource/p4rt-ovs/tree/2511a57e5411aadb824d914281afddbb203fd07c) | `2511a57e5411` | uBPF 的历史宿主参考 | helper 可复用 headroom，空间不足才进入扩容路径；不能用测试 runtime 代替宿主分析 |

因此，“extract 用指针”“使用 headroom”“常见封装不搬 payload”均有直接先例。更值得验证的方向是：根据具体 P4 程序静态推导输出布局、数据依赖和临时空间，生成更少运行时 bookkeeping、更少 header 复制的专用代码。

## 2. p4c-uBPF：物化字段，调整报文起点，再序列化

官方后端说明确认先输出 `.c/.h`，再由 Clang 生成 BPF 字节码供用户态执行。它采用 `ubpf_model.p4`，其目标约束与原生 C 后端不同。见 [uBPF 后端说明](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/README.md)。

### Parser

`UBPFStateTranslationVisitor` 直接为 state 输出 C label，为 transition 输出 goto。`compileExtract` 检查包长，逐字段调用 `compileExtractField`，生成不同宽度的 load、移位和掩码，最后设置 validity。见 [ubpfParser.cpp](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfParser.cpp#L87)、[字段提取](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfParser.cpp#L182)。

包头容器是入口函数内声明的局部对象，并非每次 extract 调用 malloc。这个实现更接近“提取为逻辑字段”，也不等同于按 wire layout 做整头 memcpy。后续 Clang 仍可能消除局部对象和冗余加载，源码生成策略不能直接当成最终机器码成本。见 [局部 header 实例](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfProgram.cpp#L69)。

### Deparser 与宿主内存

后端先累计有效输出 header 的长度，再减去 parser 消费长度，调用 `ubpf_adjust_head`，然后按字段写出 header。长度收集器拒绝 if、赋值等多类语句，这是一种受约束的两遍生成方式，不能直接覆盖任意 deparser control。见 [OutHeaderSize](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfDeparser.cpp#L49)、[compileEmit](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfDeparser.cpp#L209)、[整体发射流程](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/ubpfDeparser.cpp#L297)。

复制成本必须继续追到 runtime：p4c 的 [测试 helper](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/ubpf/runtime/ubpf_test.h#L37) 使用 realloc 和复制；历史 P4rt-OVS 的 [adjust-head helper](https://github.com/Orange-OpenSource/p4rt-ovs/blob/2511a57e5411aadb824d914281afddbb203fd07c/lib/bpf.c#L290) 则调用 `dp_packet_push_zeros` / `dp_packet_reset_packet`，而 [headroom 预留](https://github.com/Orange-OpenSource/p4rt-ovs/blob/2511a57e5411aadb824d914281afddbb203fd07c/lib/dp-packet.c#L304) 仅在空间不足时扩容。这里核对的是历史实现，没有验证它与本次 p4c 提交的完整兼容性。

**对本项目的启发：** label/goto 可以作为 parser 的直接基线；需要进一步比较的是字段物化、按需读取、原报文视图各自的成本，以及 deparser 是否必须把所有有效 header 重新写一遍。

## 3. T4P4S：原报文视图与可选重建

T4P4S 是已有的 P4 → C → DPDK 路线，项目将目标相关操作放在 NetHAL。见 [项目说明](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/README.md) 与 [作者项目页](https://p4.elte.hu/)。

在 [parser 生成模板](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/src/hardware_indep/multi_parser.c.py#L36) 中，普通 extract 将 `hdr->pointer` 设为当前输入指针，记录长度，推进 cursor；部分字段预先加载。它已经避免了普遍的“extract → 整头复制”。

[packet descriptor](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/src/hardware_dep/shared/includes/dataplane_hdr_fld_pkt.h#L79) 包含 header 描述符、emit 顺序、重建标志和固定大小的 `header_tmp_storage`。[激活新 header](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/src/hardware_dep/shared/dataplane_hdr_fld_pkt.c#L7) 时指向此临时区，并标记需要重建。[emit 模板](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/src/utils/codegen.sugar.py#L575) 记录 header ID 序列。

[Deparser 模板](https://github.com/P4ELTE/t4p4s/blob/7cd5bacc7475892f4a1d8b22c2cf9c28e16e5781/src/hardware_indep/dataplane_deparse.c.py#L37) 在重建分支备份原有 header，按输出大小调用 `rte_pktmbuf_prepend` / `rte_pktmbuf_adj`，并将连续来源合并复制；未标记重建时跳过这些步骤。空间不足的 prepend 分支直接退出进程，不能作为本项目的通用失败策略。

该源码有一个需要单独复现的细节：备份函数写入临时区后，回写函数仍读取 `hdr.pointer`，该函数内没有把原包指针改指向备份区。因此，本次只确认存在这些机制，不据此宣称任意重排及重叠复制都已正确处理。

**对本项目的启发：** 原报文视图和固定临时区具有已有实现基础。后续比较应具体到“哪些 header 被备份、哪些区间被复制、哪些判定可在编译期完成”，并包含插入、删除和纯重排的正确性用例。

## 4. p4c-DPDK 与 SWX：指令解释器、构包策略及可选 C codegen

### 编译链路

p4c-DPDK 输出 SWX `.spec`，支持的架构入口包括 PSA/PNA。见 [后端说明](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/README.md)。关于 spec 的表达能力、两端职责及本项目前端选择，见 [深入调研](swx-spec-pipeline.md)。

SWX 的基本路径是解释执行：spec 装载为内部指令，[instr_exec](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7783) 按 `ip->type` 分派到对应 handler。DPDK 另提供 [`rte_swx_pipeline_codegen`](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.h#L978) 作为可选加速路径：将指令组生成 C、编译成共享库，再接入同一执行框架。组内可以执行原生代码，但不能据此将整个方案等同于直接生成专用 DPDK C 的编译器。性能对照需明确采用哪条路径。

### Extract、emit 与构包

SWX 的 [extract 执行函数](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1983) 将 header 对应的结构指针指向当前 packet cursor，更新有效位和 cursor。其 [emit 执行函数](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2161) 收集有效 header，并把物理相邻的来源合并为一个输出区间。

最终的 [`emit_handler`](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1753) 有三类路径：

| 条件 | 动作 |
| --- | --- |
| 一个输出区间，末端正好连接 payload | 只改报文 offset/length，覆盖保持布局及前缀解封装情形 |
| 两个区间：前段来自新 header 存储，后段连接 payload | 只复制新前缀，再改 offset/length |
| 其他情况 | 将输出 header 汇集到 `header_out_storage`，再回写 payload 前方 |

这里保留 payload 的物理位置，复杂情形主要承担 header 汇集及回写成本。该策略根据运行时区间关系选择路径，并未在这里针对每一种中间插入、删除或交换生成最少移动序列。

`header_storage` 和 `header_out_storage` 在 [`header_build`](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L1514) 中为各 pipeline 执行上下文预分配。它们不要求逐包 malloc，也没有放在 mbuf headroom 里。包起点和长度通过 [ethdev port adapter](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/port/rte_swx_port_ethdev.c#L263) 写回 mbuf。

### 已有静态优化及可比较空间

p4c-DPDK 已有 [`EliminateHeaderCopy`](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/dpdkArch.h#L1140)：消除内联带来的部分临时 header 拷贝，将其他整头赋值展开为字段赋值。这与最终 packet 内存布局规划是不同层次的优化。

**本项目可以验证的差异：** 将 parser 来源信息、control 的读写、deparser 输出序列联合起来，对具体路径生成直接写字段、移动局部前缀、循环置换等代码，尝试降低通用描述符和复杂分支的成本。SWX 生成 C 后也可能被 C 编译器进一步优化，实际差异需要检查机器码并测量。

本次读取的 SWX extract/emit 热路径没有展示完整的逐操作短包、headroom 和跨 segment 保护；不能将其片段直接当作安全性模板。正确性与内存条件必须在本项目自己的接口和生成代码中闭合。

## 5. 从调研得到的研究问题

1. 对每个 header/字段，能否静态决定原报文视图、标量值或独立存储，并保持值语义？
2. 能否将逻辑 emit 序列转换为保留区间、字段写入、区间移动和必要备份，避免无条件重建所有 header？
3. 能否提前证明操作顺序不会覆盖仍然活跃的源数据，并给出 scratch 空间上界？
4. 对动态 header 长度、validity 和 mbuf 条件，哪些信息需要留到运行时？专用分支会增加多少代码体积？
5. 相比手写 C、T4P4S 和 SWX 原生 codegen，减少的复制是否转化为实际 cycles/packet 改善？

这些问题用于细化第一阶段的三项代码生成能力。当前证据支持进一步做程序专用的构包优化研究，但还不足以作出“已有项目没有解决”或“本项目可以生成全局最优代码”的结论。
