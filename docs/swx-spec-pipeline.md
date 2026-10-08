# p4c-DPDK → SWX spec：目标 IR、解释执行与扩展空间

调研日期：2026-09-26。延续 [已有后端调研](codegen-research.md)，固定阅读 p4c `4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11` 与 DPDK `4f795ddd6a1fbdea97b7b254dea6d8f1f837a681`。本文是源码分析，没有构建或运行两者，也没有验证这两个提交的组合兼容性或性能。示例为解释性片段。

2026-09-27 修正：优先从 SWX 的指令解释器模型理解 spec。C codegen 是可选加速路径；此前将它作为主链路描述，容易把 SWX 与直接生成专用 C 的后端混为同一种方案。

项目当前约束：明确以 DPDK codegen 为目标，DPDK 是当前唯一 target，kernel、eBPF 等留待后续考虑；先完成面向 DPDK 的 header 格式转换、parser codegen 与 deparser codegen；后续扩展 P4；优先考虑自己的轻量前端，保留采用官方 p4c 的可能。本文不确定最终 IR，也不制定实现 roadmap。

后续的 [parser/deparser 源码导读](swx-parser-deparser-internals.md) 进一步追踪 spec 指令翻译、原生 C 生成、header 存储与构包实现，并提供原始 helper 的局部运行实验。本文的架构结论与这些更细的实现证据配合阅读。

## 1. 这个模式拆开了哪些职责

```text
P4 程序 + PSA/PNA 架构定义
  → p4c 前端：名字解析、类型与语言语义检查
  → 中端与 DPDK 后端：结构展开、位字段处理、架构映射、指令选择
  → SWX .spec：数据声明、表配置、action 与 apply 指令
  → 解析/配置为内部指令和运行时对象
  → SWX 指令解释器：按 opcode 分派执行

可选加速路径：
SWX .spec → SWX C codegen → C 编译器 → 共享库
  → 将原生指令组函数接回 SWX 执行框架
```

SWX `.spec` 可以理解为 SWX 目标 IR 的文本形式，包含接近汇编的指令和声明式资源配置。它有实际执行语义，基本路径由 SWX 解释器执行，并非每个程序都必须先生成 C。它与 P4 语言规范、项目需要讨论的语义约束是不同事物。SWX 读入 spec 时不需要 P4 AST，也不要求它由 p4c 生成。因此，**自己的前端 → SWX spec** 在架构上成立，但这意味着接入 SWX 执行模型，要另外评估其与直接生成专用 DPDK C 的差异。

证据：p4c [入口](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/main.cpp#L53) 分别执行前端、中端和后端；后端最终调用 `toSpec`。SWX 的 [codegen 入口](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14588) 则从 spec 解析、配置、指令分组开始。

| 工作 | p4c-DPDK 一侧 | SWX 一侧 |
| --- | --- | --- |
| P4 名字、类型与值语义 | 解析、检查、规范化 | 不解析 P4 源语言 |
| Header 表示 | 转换布局与字段访问，生成声明 | 建立偏移、字段描述与 header 存储 |
| Parser | 状态分支降低为标签、跳转、extract 等 | 执行 cursor、header view 与 validity 操作 |
| Control / table | action、key、架构 metadata 等降低 | 表查询及目标指令执行 |
| Deparser | 生成按程序顺序执行的 emit 等指令 | 收集输出区间、选择构包路径、提交报文 |
| 执行方式 | 输出目标 IR/spec | 基本路径解释指令；可选 C codegen 编译指令组并接回 runtime |

这层分工值得借鉴，但“采用这种分工”和“采用现有 SWX spec/runtime”应分别评估。

## 2. spec 的具体形态

p4c 仓库提供了 [P4 样例](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/testdata/p4_16_samples/pna-elim-hdr-copy-dpdk.p4) 及其 [预期 spec 输出](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/testdata/p4_16_samples_outputs/pna-elim-hdr-copy-dpdk.p4.spec)。它展示了几个重要变化：

- `bit<4> version` 与 `bit<4> ihl` 合并为 `bit<8> version_ihl`；`flags` 与 `fragOffset` 合并为一个 16 位字段。
- Header 类型声明和实例声明分开，例如 `header ipv4 instanceof ipv4_t`。
- Parser state 成为标签，select 成为比较跳转，最终与控制处理及 emit 放进 `apply` 指令流。
- Metadata 归并为目标结构；表保留 key、actions、default action 与 size 等声明。

以下是按该样例缩写、改名后的说明片段，省略了类型、metadata、端口和 action 等配置，不能作为完整程序运行：

```text
apply {
    rx m.in_port
    extract h.ethernet
    jmpeq PARSE_IPV4 h.ethernet.etherType 0x800
    jmp PARSE_DONE
    PARSE_IPV4 : extract h.ipv4
    PARSE_DONE : emit h.ethernet
    emit h.ipv4
    tx m.out_port
}
```

此处的 `extract` 与 `emit` 仍是目标操作，文本本身没有展开成 memcpy 或 memmove。无效 header 的 emit 由目标执行逻辑跳过；布局与搬移策略还要继续追到 SWX。

## 3. 轻量前端需要承担的语义工作

### 3.1 spec 生成前已发生大量转换

p4c 的 [DPDK 中端](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/midend.cpp#L161) 包含类型检查、常量折叠、结构赋值展开、header/interface 展平、parser 展开等 pass。[DPDK 后端](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/backend.cpp#L43) 继续处理字节对齐、复杂表达式、header copy、架构转换、metadata 归并和双操作数指令化。

自己的编译器可以只实现明确选定的语言子集，并用更直接的方式完成转换；但名字绑定、位宽/符号、validity、赋值的值语义和错误路径等仍需明确处理。轻量化的依据应是缩小支持范围、简化表示与流程。现有语法解析器还不能直接替代这些语义步骤。

### 3.2 目标布局限制会反向影响语言支持

SWX [结构字段解析](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_spec.c#L166) 要求字段宽度按字节对齐，varbit 只能在结构末尾。p4c 的 [ByteAlignment](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/dpdkArch.h#L231) 合并相邻字段，并把原来的字段访问改成切片/位运算。字段最大可用宽度还取决于具体指令，不能用“所有字段最多 64 位”概括当前源码。

对于可变长度 extract，P4 参数使用 bit 数，SWX 使用 byte 数。p4c [降低代码](https://github.com/p4lang/p4c/blob/4eb5f4d020675fcbf056c61b9bacc22cf5b7fa11/backends/dpdk/dpdkHelpers.cpp#L1116) 生成右移 3 位，源码注释明确指出非字节对齐长度会丢弃余数。这是具体目标限制，不应无条件沿用为本项目语义；需要决定支持范围及拒绝或检查方式。

### 3.3 架构模型与语言前端可以分开选择

复用 p4c-DPDK 时，需要适配其 PSA/PNA 入口和 metadata 映射。自己的前端若直接输出 SWX spec，可以定义较小的 packet 输入/输出接口，再映射到 SWX 的 rx/tx 等操作，无须为了使用 SWX 完整实现 PSA/PNA。与此同时，parser reject、丢包、输出端口和剩余 payload 的处置仍需有明确约定。

这是基于编译边界得出的设计选项，尚未通过本项目原型验证。

## 4. 解释器本体与可选原生 C codegen

基本执行路径在 [instr_exec](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L7783) 中读取 `t->ip`，通过 `instruction_table[ip->type]` 调用指令 handler。spec 的解析与指令配置发生在加载阶段，逐包执行面对的是解码后的指令。数据指针、字段偏移、有效位和输出区间等构成解释器状态。

SWX 的 [指令组生成器](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14442) 生成 `pipeline_func_N(struct rte_swx_pipeline *p)`，取得执行上下文，输出标签、跳转及指令执行函数调用。[生成入口](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.c#L14650) 引入 `rte_swx_pipeline_internal.h` 等头文件。

这条可选路径确实生成原生 C；加载后通过 `pipeline_adjust` 把多指令组替换为调用生成函数的自定义指令。它减少组内解释分派，同时保留 SWX 的执行上下文和运行时组织。若希望得到一个可直接集成的 `process_packet(mbuf, context)` 式函数接口，还需要自己的适配或后端设计。C 编译器可能内联和消除部分开销，实际保留多少需要检查机器码，不能只凭生成形式判断性能。

## 5. packet build：最值得继续研究的边界

SWX 的 [extract](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1983) 使用原报文视图；[emit](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2161) 收集区间并合并相邻来源。最终 [emit_handler](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L1753) 根据区间数量及地址关系选择复用、复制新前缀或通用重建。

一个具体可比较的问题：输入为 `[A][B][C][payload]`，输出为 `[A][C][payload]`。假定三个 header 都有效、来源连续、没有额外写入、payload 保持原地址，并且空间和所有权允许：

- SWX 收集出 A 与 C 两个不连续来源区间。A 来自原报文，不符合“新前缀存储”的快路径条件，因此进入通用分支；源代码会将 A、C 汇集到 scratch，再整体回写。
- 专用计划可将 A 向后移动 `sizeof(B)`，保留 C 和 payload，调整起点及长度。其主要数据移动可以只涉及 A，且必须使用能正确处理重叠的操作。

这是源码层面的复制量分析，不是已经测得的性能提升。A/B/C 的长度、编译器优化和分支成本都会影响收益。

这里的结论是 SWX 支持删除 B，但该版本的通用构包策略没有自动选择上述单次移动。设原包起点为 `p`，A/B 长度为 `a`/`b`，专用操作是 `memmove(p + b, p, a)`，然后将包起点增加 `b`、长度减少 `b`。A 的新末端正好衔接 C；只有 A/B 等长时，才可直观地理解为 A 完全覆盖原 B 的位置。操作应安排在旧视图不再被读取的构包提交阶段。

SWX 的 `mov` 是字段赋值，其 [宽字段执行路径](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h#L2668) 使用 memcpy，不能直接当作带任意 packet 偏移、重叠保护与视图更新的 memmove 原语。增加此类快路径可以通过修改 SWX 构包实现探索，并不必然要求重写整个编译链路。简单删除案例用于验证基线；更一般的条件输出、重排与来源依赖才需要进一步规划。

这个例子说明：**前端输出既有 emit 指令，可以复用 SWX 的构包策略；如果需要表达专用的字节区间移动计划，则需要进一步的后端能力。** 现有 header 级 extract/emit 接口没有直接承载“保留 C、移动 A、安排 scratch 生命周期”这样的计划。实现方式可能是独立 C 后端，也可能是扩展 SWX；现在无需选定。

若过早只保留普通指令流，后续分析可能需要重新恢复 header 来源、别名、写入版本和条件输出关系。建议在降低前保留这些信息，先形成逻辑输出与数据依赖，再决定具体布局和移动。这里描述的是需要保留的信息，尚未固定某种 IR。

## 6. 扩展 P4 时，改动会落在哪里

| 扩展类型 | 对轻量前端的要求 | 对 SWX 的影响 |
| --- | --- | --- |
| 新语法，可展开为已有操作 | 解析、检查、降低 | 通常可继续输出既有 spec |
| 编译提示、布局/空间约束 | 解释并验证提示，参与 planning | 只有已有目标能力可表达时才可直接落实 |
| 新 extern 算法或状态对象 | 类型与调用规则，副作用描述 | 注册实现、参数传递、生命周期及加载集成 |
| 新 packet build 操作、分段/所有权语义 | 明确语义与依赖，生成专用计划 | 需要核对或扩展目标接口；也可直接生成 C/DPDK |

SWX 提供 [extern 类型、成员和函数注册 API](https://github.com/DPDK/dpdk/blob/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline.h#L224)，通过 mailbox 传递参数和结果。不过，spec 中写出一个对象或调用，不会自动提供实现或注册它。尤其现有 `rte_swx_pipeline_codegen` 内部新建 pipeline 后直接配置 spec；采用自定义 extern 时，需要检查注册如何进入 codegen 和加载路径，不能假定标准工具已具备所需扩展入口。

更不能仅凭“支持 extern”推断可以安全修改任意 packet buffer。包指针、可写性、分段、失效的 view 和构包状态如何协调，仍是运行时契约的一部分。

## 7. 对本项目的选择意味着什么

| 方案 | 可以复用 | 仍需承担或接受 |
| --- | --- | --- |
| 自己的前端 → SWX spec | SWX 指令执行、表、端口及 C codegen | 子集语义、目标降低；既有构包策略与运行时约束 |
| 自己的前端 → 构包分析 → C/DPDK | DPDK mbuf、I/O 和库能力 | 语义、布局分析、构包后端和所需集成；可直接控制移动计划 |
| 复用 p4c 前端/中端，再接目标后端 | 已有 P4 语义与规范化能力 | p4c 依赖和 IR/pass 接口；扩展语义与优化信息的保留 |

当前路线是保留自己的轻量前端，围绕实际需求做 DPDK codegen。SWX 主要提供通用解释器的 header/构包算法参考，以及可区分解释执行和原生加速的对照对象。接入 SWX 会引入它的指令与执行模型，不能仅因其能输出 C 就认定比直接 codegen 更接近项目目标。若要验证专用 packet build planning，必须能控制最终的数据移动。

若后续选择 p4c，可先评估把扩展展开为已有 P4 或 extern 的方式；无法这样表达时，再评估修改其前端/IR。无需现在承诺维护完整编译器分支，也不能把已有 AST 解析能力等同于完整语言支持。

下一轮讨论可以围绕三个具体问题展开：需要的语言扩展是什么；构包分析必须保留哪些来源与值版本信息；生成代码与 DPDK 之间的包所有权、空间和失败接口是什么。这些讨论服务于既定三项 codegen 产出，文档与独立 spec 仍不作为第一阶段交付项。
