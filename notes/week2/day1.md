# Day 1 学习笔记 · Pod 与 Deployment

> 日期：2026-09-18 · 代码：`code/week2/day1/`（`pod.webapp.yaml`、`deploy.webapp.yaml`）
> 配套资料：`docs/k8s_in_action/02-Pod与副本机制.md`，以及 `plan/week2/任务明细.md` 中的 Day 1
> 起点资产：第 1 周构建的镜像 `webapp:v4`（占用磁盘 25.3MB、以非 root 用户 uid 10001 运行、基于 alpine 底座）
> **本周基调**：从"我命令 Docker 做什么"切到"我声明要什么状态，K8s 自己对齐"。

---

## 一、今日速览（结论，收尾时填）

| 编号 | 结论 |
|---|---|
| 1 | 集群状态：kind 节点容器的状态 = ___；节点数量 = ___；当前上下文 = ___ |
| 2 | 镜像为什么需要导入节点：`kind load docker-image webapp:v4` 把镜像写入节点内部的镜像库，因为节点上的 kubelet 只能看到节点自己的镜像库 = ___ |
| 3 | Pod 与容器的关系：Pod = ___；共享的命名空间 = ___；文件系统是否共享 = ___ |
| 4 | 删除 Pod 之后重建：IP 地址 ___，名称 ___，这说明 Pod 属于 ___ 类型的对象 |
| 5 | 裸 Pod 与 Deployment 的差异：删除裸 Pod 之后 ___；删除由 Deployment 管理的 Pod 之后 ___ |
| 6 | 遗留疑问：___ |

---

## 二、任务清单

| 编号 | 任务 | 完成 | 原始输出留在哪 |
|---|---|---|---|
| 1 | 检查集群状态（`docker ps -a --filter name=kind` 与 `kubectl get nodes`） | ⬜ | |
| 2 | 执行 `kind load docker-image webapp:v4` 把镜像导入节点 | ⬜ | |
| 3 | 用 `kubectl run --dry-run=client -o yaml` 生成 YAML 模板，并逐字段阅读 | ⬜ | |
| 4 | 自己编写 `code/week2/day1/pod.webapp.yaml` 并创建裸 Pod | ⬜ | |
| 5 | 执行 `kubectl get po -o wide`、`kubectl describe po`、`kubectl logs` | ⬜ | |
| 6 | 执行 `kubectl port-forward`，并在另一个终端执行 `curl` 验证 | ⬜ | |
| 7 | 执行 `kubectl exec` 进入容器，查看 `/proc/1/cmdline`、`hostname`、`env` | ⬜ | |
| 8 | 删除裸 Pod，确认它不会自动恢复 | ⬜ | |
| 9 | 编写并创建 `code/week2/day1/deploy.webapp.yaml`（副本数量为 2） | ⬜ | |
| 10 | 执行 `kubectl get deploy,rs,po` 同时观察三层对象 | ⬜ | |
| 11 | 删除一个由 Deployment 管理的 Pod，确认控制器自动补齐 | ⬜ | |
| 12 | 执行 `kubectl scale` 完成一次扩容与一次缩容 | ⬜ | |
| 13 | 完成 Linux 每日一题 Day 8（umask） | ⬜ | |
| 14 | 回答当天的面试问答卡（四道题，见 `plan/week2/任务明细.md`） | ⬜ | |

---

## 三、概念（机制，用自己的话写）

### 3.1 Pod 是什么

| 问题 | 答案（待自己写） |
|---|---|
| Pod 是调度单位，这句话的推论是什么？ | |
| 同 Pod 容器共享哪些 namespace？ | |
| 同 Pod 容器**不**共享什么？ | |
| 同 Pod 两容器能绑同一端口吗？为什么？ | |
| 不同 Pod 的端口会冲突吗？为什么？ | |

### 3.2 与 Docker 的对应关系（本周的模型切换）

| 维度 | Docker（第 1 周） | Kubernetes（第 2 周） |
|---|---|---|
| 运行单位 | 容器 | |
| 镜像来源 | 宿主机 Docker 的镜像库可以直接使用 | |
| 网络访问 | `-p 8080:8080`，由宿主机上的 DNAT 规则完成 | |
| 进程退出 | 需要自己执行 `docker start` | |
| 容器被删除 | 不会自动恢复 | |

### 3.3 Deployment 与 ReplicaSet 的关系

| 问题 | 答案（待自己写） |
|---|---|
| 从提交 Deployment 到容器运行，一共经过哪几层对象？ | |
| 副本数量由哪一层对象负责维持？ | |
| Deployment 为什么能够回滚？ | |
| Pod 的名称为什么带有随机后缀？ | |

---

## 四、命令

| 场景 | 命令 | 说明（修改了集群中的哪个对象或状态） |
|---|---|---|
| 查看集群与节点 | | |
| 把镜像导入节点内部的镜像库 | | |
| 生成 YAML 模板（只输出到文件，不创建资源） | | |
| 根据 YAML 创建资源 | | |
| 以声明式方式创建或更新资源 | | |
| 查看 Pod 的 IP 地址与所在节点 | | |
| 同时查看 Deployment、ReplicaSet、Pod 三层对象 | | |
| 查看事件记录（排查的第一步） | | |
| 查看日志与上一个容器的日志 | | |
| 进入容器内部 | | |
| 转发端口 | | |
| 调整副本数量 | | |
| 删除 Pod | | |

---

## 五、易错点

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |

---

## 六、我的疑问

-
