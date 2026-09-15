# Day 5 · 排障工具链 + 故意制造故障（代码/实验目录）

> 主题：容器出问题先看什么（分层定位 + 退出码）
> 笔记：`notes/week1/day5.md`｜题库：`docs/docker/05-排障索引.md`

## 今天在这里放什么

| 文件 | 用途 |
|---|---|
| `Dockerfile.badcmd` | 故意把 `CMD` 指向不存在的文件 → 抓 `Exited (127)` |
| `Dockerfile.exit0` | 主进程立刻正常结束 → 抓 `Exited (0)`（服务型进程的反例） |
| `Dockerfile.oom` | 配合 `-m 32m` 制造 OOM → 抓 `Exited (137)` + `OOMKilled=true` |
| `Dockerfile.sigterm` | 捕获 SIGTERM 并善后 → 对比 137 / 143 |
| `run.sh` | 一条条实验命令（**先自己写，跑通再回填**） |
| `日志/*.log` | 把实测输出重定向保存，便于回填笔记 |

## 约定

- 实验命令**先自己写一遍**再对照 `docs/docker/05-排障索引.md`；
- 每抓到一次异常退出，就把「现象 → 机制 → 命令」写进当天笔记；
- 输出较长时重定向到文件（`> /tmp/xxx.log 2>&1`）再读，避免终端丢输出。
