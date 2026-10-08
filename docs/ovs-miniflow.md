# 从 OVS miniflow_extract 反推 P4 的表达价值

## 这个实验交付什么

[samples/ovs_miniflow.p4](../samples/ovs_miniflow.p4) 是一份报文字段提取的
P4 parser 描述，用于比较真实软件解析逻辑与 P4 状态图的表达成本。
当前有 63 个显式状态、四组循环，项目的前端可以读取它并保留 AST。
状态数是这份实现的结果，不是 P4 的理论下限，也不是性能指标。

它不是完整 OVS 替代品，不生成 C，不是已经验证可部署的 P4 程序。
没有 switch architecture、package 实例化或数据面控制逻辑。
本次没有可用的 `p4test` 可执行文件；未通过官方类型检查，也没有进行
报文级 OVS 差分验证。因此下文的“对应”指源码层面的建模意图。

## 固定参考

- [OVS v2.17.2 lib/flow.c](https://github.com/openvswitch/ovs/blob/v2.17.2/lib/flow.c)：
  `miniflow_extract`、`parse_vlan`、`parse_ethertype`、`parse_mpls`、
  `ipv4_sanity_check`、`ipv6_sanity_check`、`parse_ipv6_ext_hdrs__`、
  `parse_icmpv6`、`parse_nsh`。
- [OVS flow.h](https://github.com/openvswitch/ovs/blob/v2.17.2/include/openvswitch/flow.h)：
  最多保存 2 层 VLAN、3 个 MPLS label。
- 实际逐行阅读的本机参考：
  `/Users/bytedance/src/openvswitch-2.17.2/lib/flow.c`。
  该目录不是 Git checkout；不以目录名保证内容与上游逐字相同。
  文件 SHA-256：`be08564778af8273633a79eaf9ccf18c1eb4c8279e6ed6341000b0f4d3eb44f5`。
  主要解析路径另外与上游标签源码交叉核对。
- [P4_16 1.2.4 §13.8](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/P4-16-v1.2.4.html#sec-packet-data-extraction)：
  `lookahead<T>()`、`extract`、`advance`、`length()` 的语义。

## 模型契约

输入是一份完整报文，软件目标支持 `packet.length()`。`ovs_input_t` 提供
`packet_type` 和 `vlan_limit`，后者由宿主限制在 0..2。
默认 Ethernet packet type 为 0；其他类型与参考代码一样使用低 16 位作为 ethertype。

输出 `ovs_key_t` 是逻辑字段，不是 `struct flow` 或压缩 `struct miniflow`：

- `has_*` 为字段组的有效性标记，不等同于 OVS 的 64-bit word bitmap。
  标记为 false 的字段未定义，消费者必须先检查标记。
- `has_ipv4` 对应 IPv4 地址；`has_ipv6` 对应 IPv6 地址；
  `has_nw` 对应完成 IP 头和扩展头处理后的协议/TTL/TOS/分片信息及 label。
  IPv6 扩展头损坏时，地址可能有效而 `has_nw` 为 false。
- ARP 使用 `has_arp`，ARP opcode 单独由 `has_arp_op` 控制。
  `arp_sha/arp_tha` 在 `has_arp` 或 `has_nd` 为 true 时有效。
- ND 使用 `has_nd`、`has_nd_target`、`nd_opt_type`、`nd_reserved`。
  OVS 会复用 `tcp_flags` / `igmp_group_ip4` 存储后两个值；本模型使用独立名字。
- VLAN/MPLS 只读取 `vlan_count` / `mpls_count` 范围内的槽位。
  MPLS count 是保存的数量，最大为 3，不是实际扫描总数。
- 多字节字段表示数值；C 后端如何保留或转换网络序尚未实现。
- `ovs_parse_t.l2_5/l3/l4/l2_padding` 表达层偏移和 padding；
  unset 使用 32 位 `0xffffffff`，而 OVS 使用 16 位 sentinel。
  要接入 OVS，需要范围检查和转换。
- `ovs_parse_t` 的其他字段以及 `ovs_headers_t` 都是工作区，不是交付 ABI。
  工作 header 的 validity 不能替代 key 的 presence 标记。
  终止路径上的物理 packet cursor 不承诺与 OVS 内部 `data` 相同，尤其是
  ARP/NSH；本实验只观察字段及上述层偏移，不作为后续 deparser 的输入。

这里 `accept` 表示“结束提取，保留已完成的字段”，不代表报文完整、合法或应该转发。
这是为了模拟 OVS 的 `goto out`。不能统一换成 `verify(...); reject`，否则会
丢失短包、无关协议和部分有效字段之间的区别。

## 路径对照

| OVS 行为 | P4 状态 | 保留的关键细节 |
| --- | --- | --- |
| Ethernet / 非 Ethernet packet type | `ethernet_*` / `bare_l3` | 短于 14 字节不提交 L2；裸 L3 不经过 Ethernet |
| VLAN | `vlan_check → vlan → vlan_check` | 0x8100/0x88a8；受配置和两层上限约束；TCI 设置 0x1000 |
| 802.3 LLC/SNAP | `ethertype → snap_*` | 无效 SNAP 不跳过；合法 SNAP 才前移 8 字节；无类型为 0x05ff |
| MPLS | `mpls_check → mpls → mpls_check` | 扫描到 BOS 或不足 4 字节；只保存前三个；不猜测内层 IP |
| IPv4 | `ipv4_check → ipv4_peek → ipv4` | IHL/total length 检查、跳过 options、排除 padding、首片/后续片区分 |
| IPv6 | `ipv6_*` | payload length 约束；地址在扩展头检查之前提交 |
| IPv6 HBH/Routing/Destination/AH | `ipv6_dispatch → ipv6_ext_* → ipv6_dispatch` | 普通扩展头 `(len+1)*8`；AH `(len+2)*4`；至少有 8 字节 |
| IPv6 fragment | `ipv6_frag_*` | 后续片停止读 L4，协议设为 44；原子分片不自动标为 fragmented |
| TCP | `tcp_*` | data offset 至少 20 且不越 IP payload；保留控制字低 12 位 |
| UDP/SCTP | `udp_*` / `sctp_*` | 最小头长；不额外验证 UDP length/checksum |
| ICMP/IGMP | `icmp_*` / `igmp` | type/code 映射到端口字段；IGMP group |
| ICMPv6/ND | `icmpv6 → nd_*` | NS/NA code=0；target、options、reserved、首个 option type |
| ND options | `nd_option_check → … → nd_advance → nd_option_check` | 动态长度；短/零长 option 保留已有结果；重复非零 MAC 清除 target 和两地址 |
| ARP/RARP | `arp_*` | Ethernet/IPv4 格式检查；opcode >255 时保留地址但不提交 opcode |
| NSH | `nsh_*` | version/length；MD1 四个 context；MD2 不解析 TLV；不递归解析 NSH payload |

几个容易在“简化实现”中改错的地方：

1. MPLS 的保存上限不是扫描上限。第四个 label 之后仍可能需要继续扫描。
2. IP payload 的边界不同于整帧边界。Ethernet padding 不能提供缺失的 L4 字节。
3. OVS 的 ND 重复检测使用 MAC 是否为零作为哨兵，而不是独立的 seen 标志。
   一个零 MAC option 后再出现相同类型，不一定走 invalid。
4. 扩展头或 TCP 头损坏，不意味着已经提取的 Ethernet/IP 地址都无效。
5. 未知 IPv6 next-header（包括 ESP）结束扫描，仍记录该协议号。
6. OVS 的未知 NSH MD 类型路径与 MD2 的最低长度检查不同；本描述没有擅自
   给它补一条更严格的协议校验。生产版本是否保留此行为需要独立决定。

## 不属于这个 P4 parser 的部分

`miniflow_extract` 还负责复制或关联 tunnel、in_port、dp_hash、skb_priority、
pkt_mark、recirc、conntrack 状态和原始 tuple。这些不是从当前报文字节解析出的字段，
本次留给宿主适配层，也没有增加 VXLAN/Geneve 报文解封装来替代它们。

压缩 miniflow 的 bitmap、64 位写入顺序、padding、相邻字段合并以及 packet offset
回写也属于宿主/输出布局部分。本模型不证明这些接口或布局兼容性。
全量 header lookahead 只是逻辑描述；未来后端能否仅加载需要的字段、合并读操作，
以及性能能否接近 OVS，均需实现和测量。

## 从“交付可阅读 C”角度得到的结果

P4 对 header 布局、位宽和协议分派的描述很清楚。但这个例子中，大量程序行为是
边界检查、动态前移、部分结果提交、错误后的保留/清除。它们仍需要逐项写出，
并没有因为采用 P4 自动消失。

尤其 IPv6 扩展头，在 C 中适合一个循环；这里拆成了检查、查看长度、前移、再分派。
ND options 也是如此。63 个状态有一部分是这份实现为显式表达提前结束所作的拆分，
不能据此断言所有 P4 写法都这么长，但已经揭示了本项目需要付出的表达成本。

若直接按状态生成标签和跳转，很容易忠实翻译；若要求输出自然的 `while`，则需要
识别循环区域、合并检查状态、安排提前退出和工作变量。并非无法实现，但这已经超出
“把位域描述简单输出成 C”。四组循环都在消费字节，可以作为结构化代码生成的
具体试验对象，不应默认有限展开而改变语义。

这次实验支持的取舍是：先保留这份 P4 作为对照规格，不继续补泛用 P4 功能。
如果下一步要验证生成器的价值，选 `ipv6_ext` 或 `nd_option` 单独生成 C，
同时比较结构、差分结果和性能。若为了让输出好读必须恢复大部分原始 C 结构，
更轻的方案可能是仅生成 header 布局/安全读取，把循环留在手写 C 中。

## 当前验证与下一道验收

运行：

```sh
c3c build
./build/p4c3 samples/ovs_miniflow.p4
c3c test
```

已验证：前端接受整份描述；AST 保留 typed lookahead 和 cast；基本 wire header
长度正确；所有转移目标存在、状态不重名；四组回边保留。原有示例和测试仍通过。

没有验证：官方 P4 类型检查、实际 packet 执行、与 OVS 的字段差分、生成 C 的可编译性
或性能。结构测试通过不能代替这些验证。

未来差分测试应调用固定版本 OVS 的 `miniflow_extract`，再展开成逻辑 flow；
按 presence/字段映射比较，而非直接 memcmp 本模型与压缩 miniflow。至少应包含：

| 报文条件 | 应重点比较的结果 |
| --- | --- |
| 对每个完整样例逐字节截断 | 已完成的字段保留；没有越界读取 |
| VLAN limit=0/1/2，第三层 VLAN，缺少内层 ethertype | TPID/TCI、剩余 dl_type、l3 offset |
| 有效/无效 SNAP，长度小于 8 的 SNAP | 是否跳过 SNAP，FLOW_DL_TYPE_NONE |
| 1/3/5 个 MPLS label，缺 BOS | 保存上限与扫描长度分离，l3 offset |
| IPv4 options、IHL<5、total_len<IHL、total_len>可用长度 | IP 字段提交时机、offset、padding |
| L4 实际不足但帧 padding 足够 | 不从 padding 读取端口 |
| IPv4 首片/后续片，IPv6 原子/首片/后续片 | nw_frag、nw_proto、是否提取 L4 |
| IPv6 多种扩展头串联，AH 不同长度、头部截断 | 长度公式、地址保留、nw 字段提交时机 |
| TCP offset<5 或 options 不足、reserved bits 非零 | 端口有效性与低 12 位 flags |
| ND 0 长/越界 option、重复非零 MAC、重复零 MAC、尾部不足 8 字节 | target/地址保留与清除，首个 option type |
| ARP opcode>255、NSH MD1/MD2/未知 MD | 字段组 presence，context、版本和长度限制 |

这份表是后续验收清单，不是已经执行过的报文测试。
