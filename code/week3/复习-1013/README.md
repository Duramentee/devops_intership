# 复习产物目录 · 10-13（主域 Kubernetes）

> 对应记录：`notes/week3/复习-1013.md`。

本次复习以口述与纸面推演为主，不要求集群，因此本目录按需存放下列产物：

| 目录 | 存放内容 | 采集方式 |
|---|---|---|
| `daily02/` | Linux 每日一题 Day 2（磁盘空间排障）三个原因各自的验证命令与实测输出 | 需要时建立，用 `script -q -a session.log` 记录 |
| `dobj/` | 对象五问核对过程中发现的、需要回填 `notes/k8s-对象词典.md` 的新字段或新边界条件 | 口述后直接抄写 |
| `reject/` | 现象反推（若补做）所用的故障注入清单与 `kubectl describe` 输出片段 | 需要集群时建立 |

## 复现入口

| 目的 | 命令 | 说明 |
|---|---|---|
| 记录整个终端会话 | `script -q -a /home/drow/devops_intership/code/week3/复习-1013/session.log` | `exit` 结束录制 |
| 核对当前集群上下文 | `kubectl config current-context` | 只有补做现象反推时才需要，且必须确认指向个人 kind 集群 |
| 列出全部命名空间中的 Pod | `kubectl get po -A` | 需要集群时先确认整体状态 |
