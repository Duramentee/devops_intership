# Day 5 · 排障工具链 + 故意制造故障

> 主题：容器出问题先看什么（分层定位 + 退出码）
> 笔记：`notes/week1/day5.md`｜排障总索引：`docs/docker/05-排障索引.md`（§二「按退出码排障」）
> 环境：Docker Desktop 4.90.0 · Engine 29.7.2 · containerd 2.3.3 · runc 1.4.3

## 目录里有什么

| 文件 | 作用 |
|---|---|
| `Dockerfile.badcmd` | **exec** 形式 CMD 指向不存在文件 → 容器卡在 `Created`，线索在 `State.Error` |
| `Dockerfile.badcmd-shell` | **shell** 形式 CMD（同一个路径）→ `Exited (127)` + `docker logs` 里有 `not found` |
| `oom/main.go` + `Dockerfile.oom` | 内存吞噬器（逐个字节写，确保真正落页）→ 配合 `-m` 制造 OOM |
| `sig/main.go` + `Dockerfile.sig` | 同一个程序，用 `MODE` 切换三种"对 SIGTERM 的态度"：`default` / `graceful` / `ignore` |
| `run.sh` | 实验 1~5：退出码、OOM、信号三态、stats、df |
| `run2.sh` | 第二轮对照：钉死 `PID 1 信号语义`、`Created` 状态的 State、`--memory-swap`、`events --until` |
| `prune.sh` | 实验 6：**先预检爆炸半径**再 `prune`，并演示 `-a` 的后果（只看不执行） |
| `logs/` | 三份原始实测日志（证据留档） |

## 复跑方式

```bash
cd code/week1/day5
bash run.sh   > logs/exp1-5.log     2>&1   # 实验 1~5
bash run2.sh  > logs/exp-round2.log 2>&1   # 机制对照
bash prune.sh > logs/exp6-prune.log 2>&1   # 清理（⚠️ 会删掉所有已停止容器）
```

## 结论速记（完整版见笔记）

| # | 结论 |
|---|---|
| 1 | `docker stop` 的结局**由「PID 1 是谁 + 装没装 handler」决定**：实测拿到过 `0` / `2` / `137` / `143` 四种 |
| 2 | **PID 1 不装 handler 时，SIGTERM 被内核忽略** → 只能等 `-t` 超时被 SIGKILL → `137`（`sleep`/`sh` 做 PID 1 实测均如此） |
| 3 | **"优雅关闭成功" = `ExitCode 0` + 日志有善后**，不是 `143` |
| 4 | **`137` ≠ OOM**：`stop` 超时就有 `137` + `OOMKilled=false` |
| 5 | **`-m 32m` 能吃 56 MiB**：`MemorySwap` 默认 = 2 × `Memory` |
| 6 | **`CMD` 写错有两种形态**：exec 形式 → `Created`（`logs` 空，看 `State.Error`）；shell 形式 → `Exited (127)` |
| 7 | `docker stats` 对已退出容器返回 `0B / 0B` **且不报错**（会骗人）；`docker events --until` 用 `FinishedAt` 会**切掉 `oom`/`die` 事件** |
| 8 | `docker system prune`（不带 `-a`）：删**所有已停止容器** + 构建缓存，**不动**有 tag 的镜像与卷 |
