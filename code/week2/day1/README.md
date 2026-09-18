# Day 1 · Pod 与 Deployment

> 目标：把第 1 周构建的镜像 `webapp:v4` 部署到 kind 集群，并且理解 Pod 与 Deployment 两层对象之间的关系。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 1 节、`docs/k8s_in_action/02-Pod与副本机制.md` 第一节。
> 笔记落点：`notes/week2/day1.md`
> 起点资产：镜像 `webapp:v4`（占用磁盘 25.3MB、以非 root 用户 uid 10001 运行、基于 alpine 底座）。

---

## 一、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `pod.webapp.skeleton.yaml` | 裸 Pod 的填空骨架，字段名齐全，取值留空 | 已提供 |
| `pod.webapp.yaml` | 裸 Pod 的清单文件 | 你自己编写，从骨架开始 |
| `deploy.webapp.skeleton.yaml` | Deployment 的填空骨架，字段名齐全，取值留空 | 已提供 |
| `deploy.webapp.yaml` | Deployment 的清单文件 | 你自己编写，从骨架开始 |
| `outputs/` | 命令的原始输出记录，例如 `kubectl get po -o wide > outputs/01-po-wide.txt` | 你自己记录 |

编写顺序建议：先写 Pod 的清单文件并创建，理解裸 Pod 的行为；再写 Deployment 的清单文件，对比两者在被删除之后的表现差异。

## 二、操作顺序

| 顺序 | 操作 | 命令 | 要观察的内容 |
|---|---|---|---|
| 0 | 检查集群状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes` | 确认节点容器处于运行状态，并且节点的 STATUS 列显示为 `Ready`。如果节点容器处于 `Exited` 状态，先执行 `docker start kind-control-plane`，等待节点恢复。 |
| 1 | 把镜像导入节点内部的镜像库 | `kind load docker-image webapp:v4` | 该命令没有输出即表示执行成功；再用 `docker exec kind-control-plane crictl images \| grep webapp` 复核。 |
| 2 | 生成 YAML 模板（只输出到文件，不创建资源） | `kubectl run webapp --image=webapp:v4 --port=8080 --dry-run=client -o yaml > outputs/00-dry-run.yaml` | 逐字段阅读这份模板，分清哪些字段是必填项，哪些字段是由 Kubernetes 自动补全的默认值。 |
| 3 | 编写裸 Pod 的清单文件 | 参照 `pod.webapp.skeleton.yaml`，写出 `pod.webapp.yaml` | 其中至少包含 `metadata.name`、`metadata.labels`（`app` 与 `env` 两个标签）、`spec.containers` 三个部分。 |
| 4 | 创建裸 Pod | `kubectl create -f pod.webapp.yaml` | 输出应当为 `pod/webapp created`。 |
| 5 | 观察裸 Pod | `kubectl get po -o wide > outputs/01-po-wide.txt`，然后执行 `kubectl describe po webapp` | 记录 IP 地址与所在节点；重点阅读 `describe` 输出末尾 Events 段落中的调度、拉取镜像、启动容器三个事件。 |
| 6 | 查看日志 | `kubectl logs webapp` | 观察应用写到标准输出的内容。 |
| 7 | 转发端口并验证访问 | 先执行 `kubectl port-forward po/webapp 8888:8080`，再在另一个终端执行 `curl localhost:8888` | 期望得到 `<h1>Hello DevOps</h1>`。 |
| 8 | 进入容器 | `kubectl exec -it webapp -- sh` | 在容器内执行 `cat /proc/1/cmdline`、`hostname`、`env` 三条命令，分别观察主进程、主机名与环境变量。 |
| 9 | 删除裸 Pod | `kubectl delete po webapp` | 确认它不会自动恢复，也就是说集群中不会出现新的 Pod。 |
| 10 | 编写 Deployment 的清单文件 | 参照 `deploy.webapp.skeleton.yaml`，写出 `deploy.webapp.yaml` | 副本数量设置为 2；确保 `selector.matchLabels` 与 `template.metadata.labels` 完全一致。 |
| 11 | 创建 Deployment | `kubectl apply -f deploy.webapp.yaml` | 注意 `apply` 与 `create` 的区别：对象已经存在时 `apply` 会更新它，而 `create` 会报错。 |
| 12 | 同时观察三层对象 | `kubectl get deploy,rs,po > outputs/02-three-layers.txt` | 记录 ReplicaSet 的名称，以及两个 Pod 名称的共同前缀。 |
| 13 | 验证自动补齐 | `kubectl delete po <其中一个 Pod 的名称>`，然后执行 `kubectl get po -w` | 确认控制器创建了新的 Pod，并且新 Pod 的名称与 IP 地址都与被删除的那个不同。 |
| 14 | 调整副本数量 | `kubectl scale deploy webapp --replicas=4`，然后执行 `kubectl scale deploy webapp --replicas=2` | 确认 Pod 数量随之增加与减少。 |
| 15 | 通过 Deployment 转发端口 | `kubectl port-forward deploy/webapp 8888:8080`，然后在另一个终端执行 `curl localhost:8888` | 说明 `port-forward` 可以直接指向 Deployment，kubectl 会自动选择一个后端 Pod。 |

## 三、验收标准

| 编号 | 标准 |
|---|---|
| 1 | 集群处于可用状态，节点显示为 `Ready`。 |
| 2 | 镜像已经进入节点内部的镜像库，可以用 `crictl images` 命令验证。 |
| 3 | 裸 Pod 创建成功，删除之后不会自动恢复。 |
| 4 | Deployment 创建成功，删除一个 Pod 之后控制器会自动补齐。 |
| 5 | 能够通过 `port-forward` 与 `curl` 访问到应用返回的内容。 |
| 6 | 能够使用 `kubectl scale` 完成一次扩容与一次缩容。 |

## 四、常见错误与原因

| 现象 | 原因 |
|---|---|
| Pod 的状态为 `ImagePullBackOff` | 镜像没有导入节点内部的镜像库，或者清单文件中的镜像名称与标签拼写错误。 |
| Pod 的状态长期停留在 `Pending` | 没有可用的节点能够满足调度要求；在单节点的 kind 集群中，通常是节点容器还没有完全启动完成。 |
| 创建 Deployment 时报错，提示选择器与模板标签不匹配 | `selector.matchLabels` 与 `template.metadata.labels` 两个部分必须完全一致，否则 API Server 会拒绝创建。 |
| `curl localhost:8888` 没有响应 | `port-forward` 命令所在的终端没有保持运行，或者清单文件中声明的容器端口与应用实际监听的端口不一致。 |
| 执行 `kubectl exec` 报错 | 容器内没有 shell。本日使用的是基于 alpine 的 `webapp:v4`，其中包含 `sh`；如果改用第 1 周的 `scratch` 版本（`webapp:v3`），则无法执行该命令。 |

## 五、完成后如何报告

把 `outputs/` 目录中的原始输出，以及 `kubectl get po -o wide`、`kubectl describe po webapp` 的关键片段发给我。我会逐字段解析，并把结论写进 `notes/week2/day1.md`；如果其中有判断错误的内容，我会追加到 `notes/错题本.md`。
