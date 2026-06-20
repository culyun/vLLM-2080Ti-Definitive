# Profile 导引

语言：[English](README.md) | 简体中文

这里是 vLLM 2080Ti Definitive 自带的启动 profile。一个 profile 只是运行参数
的 `.env` 预设，不包含模型权重路径；权重目录通过 `launcher.sh` 或
`MODEL_DIR=...` 单独选择。

这里列出的上下文容量和吞吐数据，验证硬件是双 RTX 2080 Ti 22GB，tensor
parallel size 2。

`launcher.sh` 也支持通过 pipeline parallel 接入第 3 张 GPU（`TP_SIZE=1`、
`PP_SIZE=3`，在菜单第 3 项中按 `t` 键切换，详见 `--help`）。这一路径**为实验
性、未经验证**，本指南中的数据并不适用：当某个模型的 attention/Mamba head
数量无法被 3 整除（导致 `TENSOR_PARALLEL_SIZE=3` 无法加载）、又想用上 3 张卡
合并后的显存池时可以使用，但 pipeline parallel 的各阶段不会像 tensor
parallel 那样让单条请求的解码吞吐成倍提升，并且跨双 Xeon NUMA 边界的流水线
阶段会引入额外延迟，这是 NVLink 互连的两张卡做 TP=2 所没有的问题。

目录结构：

```text
profiles/
  templates/
  qwen27b/
    normal/
      fp8/
      int4/
    fast/
      fp8/
      int4/
    user/
```

启动模式：

- `safe`：保守回退模式，优先保证可用性。
- `normal`：推荐日常模式，适合稳定部署。
- `fast`：高性能模式，适合追求更高吞吐的场景。
- `aggressive`：更加激进的模式，性能与质量风险最高。

`profiles/templates/` 存放可选 chat template 预设。它们通过 launcher 作为全局
服务设置选择；具体 route profile 不保存 chat template、GPU、端口、reasoning
默认值或工具调用默认值。

文件名描述路线：

```text
<kv-precision>-<context>-<mtp>-<message-type>.env
```

KV 精度定位：

- `fp16kv`：质量路线。
- `int8kv`：容量 / 平衡路线；当前只作为 `normal` profile 保留。
- `tqk8v4`：TurboQuant K8V4 压缩路线；当前只保留质量通过的 `fast` profile。

## 已验证 Profile

### FP8

测试权重：Jackrong/Qwopus3.6-27B-v2-FP8，约 29G。

| Profile | 兼容模式 | 上下文 | KV | MTP | 消息 | 并发 | 吞吐性能 |
|---|---|---:|---|---:|---|---:|---:|
| `qwen27b/normal/fp8/fp16kv-128K-mtp3-text-only.env` | normal | 128K | FP16 | 3 | text-only | 1 | 1619.48 / 84.71 |
| `qwen27b/normal/fp8/int8kv-252K-mtp3-text-only.env` | normal | 252K | INT8 | 3 | text-only | 1 | 1605.10 / 44.09 |
| `qwen27b/fast/fp8/fp16kv-112K-mtp3-text-only.env` | fast | 112K | FP16 | 3 | text-only | 1 | 1615.58 / 83.69 |
| `qwen27b/fast/fp8/tqk8v4-256K-mtp3-text-only.env` | fast | 256K | TQK8V4 | 3 | text-only | 1 | 1615.81 / 81.06 |
| `qwen27b/fast/fp8/tqk8v4-240K-mtp3-text-image.env` | fast | 240K | TQK8V4 | 3 | text+image | 1 | 1605.61 / 80.67 |

### AWQ/GPTQ-INT4

测试权重：GPTQ-INT4，约 19G。

| Profile | 兼容模式 | 上下文 | KV | MTP | 消息 | 并发 | 吞吐性能 |
|---|---|---:|---|---:|---|---:|---:|
| `qwen27b/normal/int4/fp16kv-256K-mtp3-text-only.env` | normal | 256K | FP16 | 3 | text-only | 1 | 1738.06 / 97.79 |
| `qwen27b/normal/int4/fp16kv-240K-mtp3-text-image.env` | normal | 240K | FP16 | 3 | text+image | 1 | 1760.14 / 94.48 |
| `qwen27b/normal/int4/int8kv-two250K-mtp3-text-only.env` | normal | 每工作区 250K | INT8 | 3 | text-only | 2 | 1740.51 / 49.06 |
| `qwen27b/normal/int4/int8kv-512K-yarn-mtp3-text-only.env` | normal | 512K | INT8 + YaRN | 3 | text-only | 1 | 1734.14 / 48.16 |
| `qwen27b/fast/int4/fp16kv-256K-mtp3-text-only.env` | fast | 256K | FP16 | 3 | text-only | 1 | 1734.98 / 87.00 |
| `qwen27b/fast/int4/tqk8v4-256K-mtp3-text-only.env` | fast | 256K | TQK8V4 | 3 | text-only | 1 | 1744.67 / 100.81 |
| `qwen27b/fast/int4/tqk8v4-two250K-mtp3-text-only.env` | fast | 每工作区 250K | TQK8V4 | 3 | text-only | 2 | 1739.23 / 99.91 |

表中的吞吐性能是在 `4096/128` 口径下测试，格式为
`prefill tok/s / decode tok/s`。测试前会先跑中文质量 smoke；质量失败的路线不作为
profile 保留。
