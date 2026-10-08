# SWX parser/deparser 源码实验

配套说明：[SWX 解释器执行模型与可选 codegen 源码导读](../../docs/swx-parser-deparser-internals.md)。

## 范围

`run_probe.py` 从固定版本的原始 `rte_swx_pipeline_internal.h` 提取七个 helper 和 `METADATA_READ` 宏，保留函数体，使用 `probe.c` 的缩减数据结构编译执行。缩减结构只提供 helper 使用的成员，不兼容 SWX ABI。

实验覆盖固定/可变长度提取、lookahead、validity、输出区间合并、构包复制路径和延迟 emit。只在提取的 helper 范围内拦截 memcpy 统计调用次数及请求字节数；计数不等于机器指令数、内存总流量或吞吐性能。TRACE 被禁用。

2026-09-27 定位澄清：这些是 SWX 指令解释器与可选生成代码共用的 helper。实验直接调用它们，绕过了 opcode 分派，既不测量解释器成本，也不证明一个专用 C codegen 后端会保留同样的逐包操作。

**这不是完整 DPDK 构建、P4 编译测试或 SWX spec → C 的端到端测试。** `abc-to-ac.spec` 是用于源码追踪的输入样例，尚未交给完整 SWX codegen 执行。实验不会读入这个 spec，而是显式构造指令描述符调用原始 helper。

## 复现

源版本：DPDK `4f795ddd6a1fbdea97b7b254dea6d8f1f837a681`。

```sh
curl -fL https://raw.githubusercontent.com/DPDK/dpdk/4f795ddd6a1fbdea97b7b254dea6d8f1f837a681/lib/pipeline/rte_swx_pipeline_internal.h -o /tmp/swx-pinned-internal.h
python3 research/swx-codegen/run_probe.py /tmp/swx-pinned-internal.h
```

脚本校验输入 SHA256，使用临时目录生成 include 与可执行文件，运行后自动清理。需要 Python 3、Clang 及 AddressSanitizer/UndefinedBehaviorSanitizer；可用 `--cc` 指定编译器。

固定输入源文件 SHA256：`09f99c1378e2fec31a2715d162e601a6797352938e55cfd608209d68b44c8f6d`。上游源码标记为 BSD-3-Clause、Copyright(c) 2021 Intel Corporation；原始函数在本地实验时提取，不作为本项目重写的算法。

## 本次结果

2026-09-26 在本地使用 Homebrew Clang 21.1.2，目标为 `arm64-apple-darwin24.6.0`，以 `-O1 -fsanitize=address,undefined` 编译执行。断言全部通过，sanitizer 未报告错误。原始输出见 [results.txt](results.txt)。

初始报文：headroom 32 字节，A=4、B=8、C=4、payload=8；另有 X=4 字节的新 header。`header_storage`、输出 scratch 与原包使用分开的数组。

“短包”实验只把逻辑包长设为 2，再调用长度为 4 的 extract；实际数组仍有足够空间。因此它安全地观察到了无符号长度下溢，没有故意触发越界。它证明该 helper 没有执行此项包长检查，不证明完整 P4/SWX 应用必然缺少所有上游检查。

“emit 后修改”实验观察原始 SWX helper 的延迟指针行为；是否导致特定 P4 程序偏离语义，还需要检查 p4c 的相关转换和目标支持范围。
