# 第 5 讲：数据流分析

[上一讲](04-control-flow.md) · [课程目录](README.md) · [下一讲](06-values-and-memory.md)

本讲目标：理解如何用有限的抽象状态，保守描述多条执行路径上的事实。

## 1. 从执行一个包到分析所有包

解释器执行具体输入，可以直接知道某个 header 是否有效。编译器面对尚未到来的输入，只能记录对一组执行都成立的结论。

对一个 header，采用以下抽象域：

| 状态 | 含义 |
| --- | --- |
| Unreachable | 当前没有可达执行 |
| Invalid | 所有到达执行中都无效 |
| Valid | 所有到达执行中都有效 |
| Unknown | 可能有效，也可能无效 |

Unknown 不表示程序错误，而是分析信息不足。Unreachable 与 Unknown 不同：前者没有执行，后者有执行但结论不确定。

## 2. 转移函数

每种操作把输入抽象状态转换成输出状态：

- 成功 Extract(h) 将 h 设为 Valid。
- SetValid(h, false) 将 h 设为 Invalid。
- 只读 h 的操作不会改变其有效性。
- 对 Unreachable 不执行操作，仍保持 Unreachable。

入口状态应来自实际运行模型。若入口保证 header 初始无效，就设 Invalid；没有这种保证则不能凭空假定。

## 3. 分支合并

合并运算要覆盖所有前驱可能性：

```text
join(Valid, Valid) = Valid
join(Invalid, Invalid) = Invalid
join(Valid, Invalid) = Unknown
join(Unreachable, x) = x
join(Unknown, x) = Unknown   // x 不是 Unreachable 时
```

例如一个分支提取 B，另一个分支保持 B 初始无效，合并后得到 Unknown。此时不能把 emit(B) 当成无条件输出。

## 4. 工作列表与不动点

设 IN[b] 是进入块 b 的状态，OUT[b] 是执行块后的状态：

```text
IN[b] = join(所有前驱的 OUT)
OUT[b] = transfer(b, IN[b])
```

初始把未访问块设为 Unreachable，给入口提供边界状态，将入口加入工作列表。每次取出一块，重新计算状态；如果 OUT 变化，就把后继加入工作列表。循环会让信息多次传播，直到没有变化，即达到不动点。

这个例子的抽象域有限，且合并与转移保持单调，所以迭代能稳定。对无界数值区间等更复杂的分析，终止还可能需要 widening 等技术；当前不必先实现它。

## 5. 正确性来自保守性

若分析结果为 Valid，所有实际到达执行都必须有效。错把 Unknown 变成 Valid，可能让生成代码输出不该出现的内容。

保守分析可能错失优化，但不能遗漏真实可能性。数据流结果还可以包含字段是否修改、来源是否唯一等信息，逐步扩展即可。

extract_end 的相邻来源证明需要另一类事实：上一次追加终点与下一次追加起点之间，是否有未纳入累计区的消费。仅知道 validity 不足以证明连续性。按照项目方案，不能静态证明时应使用物化路径。

## 练习

B 入口无效。左分支提取 B，右分支不操作；合流后执行 SetValid(B, false)。分别写出合流入口和出口状态。能否在出口之后删掉 emit(B)？条件是什么？

## 参考答案

入口 Unknown，出口 Invalid。若到 emit 之间没有再次改变 B 的有效性，且 guard 等求值没有必须保留的可观察效果，可以删除该输出。在项目无副作用 guard 的限制下，这个证明更容易建立，但仍要考虑相关表达式的合法求值条件。
