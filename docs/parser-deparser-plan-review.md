# Parser/Deparser 高效实现方案 Review

日期：2026-10-05。来源：[review 线程](https://ampcode.com/threads/T-01a1096d-b22a-700a-9810-2f9bc3bfc75c)。

## 范围与证据边界

Review 对象：

- [parser-deparser-challenges.md](parser-deparser-challenges.md)：问题界定
- [incremental-header-rebuild-evaluation.md](incremental-header-rebuild-evaluation.md)：具体方案评估

交叉核对材料：[`research/swx-codegen/results.txt`](../research/swx-codegen/results.txt)（实测 memcpy 计数）、[`research/swx-codegen/README.md`](../research/swx-codegen/README.md)、[project-vision.md](project-vision.md)，以及 P4 spec 语义。

以下判断基于上述文档和 P4 spec 语义；没有重新运行 SWX 实验，没有核对 [swx-parser-deparser-internals.md](swx-parser-deparser-internals.md) 中的源码行号，也没有对照源码核实 p4c-uBPF 的相关说法。

## 总体判断

方案的核心思路正确，文档对自身证据边界的说明也很诚实。最有价值的三点：

- 把**逻辑 header / 物理区间 / 值版本 / emit 出现次数**四个概念分开。这是正确原位操作的前提，SWX 没有做到：research 中 `deferred emit` 一行证明 SWX 把两次 emit 都输出了新值。
- “固定 payload、只移动前缀”的布局策略，以及 §6.3 的同序调度充分条件。已手动验证：左移区间从左到右处理，右移区间从右到左处理；左移组与右移组之间互不干扰，因为任一右移区间的目标终点 ≤ 任一后续左移区间的目标起点 < 其源起点。所以两组的相对顺序无关紧要，结论成立。
- §7 的成本表与 `results.txt` 完全一致：AC=2(4+4)=16、AB=2(4+8)=24、AXBC=2(4+4+8+4)=40、XABC=4。推导可信。

主要问题：**两份文档都停在“候选/边界/不承诺”，没有收敛成可以开始实现的 v0 子集**。以下按重要性列出具体意见。

## 1. Action 边界提前重构是最弱的一环，建议 v0 不做

文档自己在 §7.1 给出了反例：插入后又删除时，立即提交会白搬 2a 字节。§8 中“布局变化导致旧地址失效”“提前修改的可观察性”“发送元数据失配”三行风险，也都只在提前提交时才存在。收益只有一种情形：后续 action 或 extern 需要新 header 的**连续物理地址**。在 DPDK/PNA 程序里，table key 读的是字段值，可以从局部变量或 view 读取；校验和在 deparser 阶段计算；中间阶段很少需要连续字节。

建议：v0 只在 deparser 做一次提交；control 阶段的 ctx 只维护 validity 和字段值，不维护物理位置。这样可以直接消掉 §8 表中的三行风险，也不存在 §6.4 的 O(UH) 元数据维护成本。文档已经把“如何移动”（§6.3）与“何时移动”（§7.1）分开，把后者作为后续可选优化即可。

## 2. 运行时 ctx 有过度泛化的风险

§5.2 的信息模型给每个槽位列出了“来源/值版本、变化标记”。如果 codegen 按 parser 路径和 action 做了静态特化，真正需要在运行时保存的只有：

- validity：一个 bitmask
- 每个 header 相对 packet 起点的 offset：u16，因为不同 parser 路径下偏移不同
- varbit 的实际长度
- parser 消费终点

值版本和变化标记是编译期分析的产物，不应进入 runtime struct。

建议在文档中明确区分“分析需要知道的”和“运行时必须保存的”，并给出 ctx 的目标大小。SWX 的 header 描述符访问是已知开销，文档 §3 也说要“消除不必要的描述符访问”，但 ctx 设计没有体现这一点。

## 3. 遗漏了 header stack，它才是最常见的“循环”

§4.3 用 TLV、同一变量重复 extract 讨论 parser 环。但真实程序里的回边绝大多数是 `extract(hdr.vlan.next)`、`extract(hdr.mpls.next)` 这类 header stack。Stack 元素数静态有界，每个元素是独立实例，`emit(hdr.mpls)` 按下标顺序输出全部 valid 元素，恰好匹配“固定槽位”模型，也不存在 §4.3 第 2 条“归并后输出 T1 T2 T3 全部字节”的歧义。

建议把 header stack 列为 v0 支持的循环形式，同一变量的 TLV 循环放到后续。这样可以推迟 §4.3 中关于“区域 R”的复杂讨论。

## 4. 条件 emit 的难度被高估，应区分两种情形

§5.1 用 `if (flag) emit(B)` 说明“valid 不等于 emit”。例子成立，但在 P4 中，`emit` 对 invalid header 本来就是 no-op；v1model/PSA/PNA 程序的 deparser 几乎都是直线 emit 序列，或冗余的 `if (isValid()) emit`。真正的难点只是 emit 条件依赖**非 validity** 的值。

建议 v0 规定：deparser 必须是直线 emit 序列，条件只允许 `isValid()`，其他程序给出诊断。这样“输出选择 = validity bitmask”，可以大幅简化 §5。

## 5. 缺少具体的入口条件谓词

[incremental-header-rebuild-evaluation.md](incremental-header-rebuild-evaluation.md) §8.1 和 [parser-deparser-challenges.md](parser-deparser-challenges.md) §6 都提到容量、所有权和连续性，但没有写成可以生成的检查。对 DPDK direct mbuf，v0 快路径的入口条件就是三个：

- 可写：`RTE_MBUF_DIRECT(m) && rte_mbuf_refcnt_read(m) == 1`
- 连续：parser 消费的 `I` 字节位于首段内，即 `rte_pktmbuf_data_len(m) >= I`
- 容量：增长时满足 `O - I <= rte_pktmbuf_headroom(m)`

写出这些条件后，回退路径的触发条件也随之清晰。

## 6. 缺少可以立刻动手的参考模型

§10 提到“简单的参考构包模型对照”，但只有一句话。按照 [project-vision.md](project-vision.md) 中“设计文档不是交付项”的定位，下一步最有价值的产出是参考模型：一个慢但显然正确的 deparser，物化每个 header，按 emit 顺序拼接，再追加 payload。它作为 differential test 的 oracle，planner 生成的所有快路径都与它比较最终报文。这个模型本身也是 §2 值语义约束的可执行定义，并且可以先于 planner 完成。

## 7. 两处可以补强的小点

- [parser-deparser-challenges.md](parser-deparser-challenges.md) §1 说“p4c-uBPF 已采用 label/goto 翻译”，本次没有核对源码。如需引用，建议像其他 DPDK 引用一样给出固定提交的链接。
- §7 成本表只计算旧字节移动，没有计算 ctx 读写和分支。文档已经承认这一点，但 v0 实现后应尽快补充 cycles/packet 数据，否则“少复制”这一列始终只是推导。

## 建议的 v0 子集（供否决）

- 支持字节对齐的定长 header 和有界 header stack。
- 只处理单 segment、direct mbuf、refcnt 为 1 的报文。
- Deparser 为直线 emit 序列，条件仅允许 `isValid()`。
- 不支持同一 header 重复 emit，也不支持 header 整体赋值后继续读取旧值；两者给出编译诊断。
- Deparser 阶段单次提交。
- 布局计划使用 §6.3 的调度；不满足同序条件时，回退到 gather-to-scratch。

实施顺序：先做参考模型和 differential test，再做 planner，最后测量 cycles，对比 SWX helper 与手写 C。
