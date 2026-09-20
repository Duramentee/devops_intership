# Day 2 · Service 与标签选择器

> 目标：为 Deployment `webapp` 提供一个稳定的访问入口，并且理解 Service 是通过标签选择器与 Endpoints 对象找到 Pod 的。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 2 节、`docs/k8s_in_action/03-Service与存储.md`、教材第 5 章（p.207-260）与第 11 章 5（p.523-526）。
> 笔记落点：`notes/week2/day2.md`
> 起点资产：Day 1 创建的 Deployment `webapp`（副本数量为 3，Pod 标签包含 `app=webapp` 与 `env=dev`），以及镜像 `webapp:v4`。

---

## 一、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `svc-clusterip.skeleton.yaml` | ClusterIP 类型 Service 的填空骨架，字段名齐全，取值留空 | 已提供 |
| `svc-clusterip.yaml` | ClusterIP 类型 Service 的清单文件 | 你自己编写，从骨架开始 |
| `svc-nodeport.skeleton.yaml` | NodePort 类型 Service 的填空骨架，字段名齐全，取值留空 | 已提供 |
| `svc-nodeport.yaml` | NodePort 类型 Service 的清单文件 | 你自己编写，从骨架开始 |
| `outputs/` | 命令的原始输出记录 | 你自己记录，命名规则见 `outputs/README.md` |

编写顺序建议：先写 ClusterIP 类型的清单文件并创建，在集群内部用临时 Pod 访问它；再写 NodePort 类型的清单文件，从宿主机访问节点端口。

## 二、动手之前必须先记录的基线

| 项目 | 命令 | 输出文件 | 为什么要先记录 |
|---|---|---|---|
| Pod 列表、IP 地址、所在节点、标签 | `kubectl get po -o wide --show-labels` | `outputs/00-baseline-pods.txt` | 判断 Endpoints 列表是否完整，必须有一个可以对照的 Pod 清单；`--show-labels` 用于核对选择器与标签是否一致 |
| 全部 Service | `kubectl get svc -o wide` | `outputs/00-baseline-svc.txt` | 记录创建之前的 Service 数量，并且观察默认命名空间中已经存在的 `kubernetes` 这个 Service |
| 全部 Endpoints | `kubectl get endpoints -o wide` | `outputs/00-baseline-endpoints.txt` | 记录创建之前已经存在的 Endpoints 对象 |
| 节点名称与节点地址 | `kubectl get nodes -o wide` | `outputs/00-baseline-nodes.txt` | 从宿主机访问节点端口时需要使用节点地址，而不是 `localhost` |

## 三、操作顺序

| 顺序 | 操作 | 命令 | 要观察的内容 |
|---|---|---|---|
| 0 | 检查集群状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes` | 确认节点容器处于运行状态，并且节点的 STATUS 列显示为 `Ready`；如果节点容器处于 `Exited` 状态，先执行 `docker start kind-control-plane` |
| 1 | 补完 Day 1 的三项遗留任务 | `kubectl port-forward po/webapp 8888:8080`、`kubectl exec -it webapp -- sh`、`kubectl delete po webapp` 之后重新执行 `kubectl create -f ../../day1/pod.webapp.yaml` | 记录重建前后的 Pod 名称与 IP 地址，确认两者都发生变化 |
| 2 | 记录基线 | 执行第二节表格中的四条命令 | 得到今天全部对比结论的参照物 |
| 3 | 生成 YAML 模板（只输出到文件，不创建资源） | `kubectl expose deploy webapp --port=8080 --dry-run=client -o yaml > outputs/01-dry-run-svc.yaml` | 逐字段阅读这份模板，分清哪些字段是必填项，哪些字段是由 Kubernetes 自动补全的默认值 |
| 4 | 编写 ClusterIP 清单文件 | 参照 `svc-clusterip.skeleton.yaml`，写出 `svc-clusterip.yaml` | 其中至少包含 `metadata.name`、`spec.selector`、`spec.ports` 三个部分，并且选择器的取值要与 Day 1 的 Pod 标签一致 |
| 5 | 创建 ClusterIP 类型的 Service | `kubectl create -f svc-clusterip.yaml` | 输出应当为 `service/<服务名> created` |
| 6 | 观察 Service 与 Endpoints 两个对象 | `kubectl get svc -o wide > outputs/02-svc-clusterip.txt`，然后执行 `kubectl get endpoints <服务名>` | 确认 Endpoints 中的条目数量与处于就绪状态的 Pod 数量一致，并且每一个条目都是 `Pod 的 IP:端口` 的形式 |
| 7 | 观察新版本的 EndpointSlice 对象 | `kubectl get endpointslices -o wide` | 确认同一个 Service 的端点同时被写入 EndpointSlice 对象，理解两个对象的对应关系 |
| 8 | 在集群内部验证访问 | `kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never -- wget -qO- http://<服务名>:8080` | 记录应用返回的内容；如果镜像拉取失败，先在宿主机执行 `docker pull busybox:1.36`，再执行 `kind load docker-image busybox:1.36` |
| 9 | 删除一个 Pod 并观察 Endpoints 的变化 | 先执行 `kubectl get endpoints <服务名> > outputs/03-endpoints-before.txt`，再执行 `kubectl delete po <其中一个 Pod 的名称>`，等新 Pod 就绪之后执行 `kubectl get endpoints <服务名> > outputs/03-endpoints-after.txt` | 对比两个文件，确认端点列表中的地址被替换成了新 Pod 的地址，而 Service 的 ClusterIP 保持不变 |
| 10 | 制造一次端点为空的情况 | `kubectl edit svc <服务名>`，把 `spec.selector` 改成不匹配任何 Pod 的取值，然后执行 `kubectl get endpoints <服务名>`，再重复第 8 步的访问命令；记录完成之后把选择器改回原值 | 观察 Service 对象本身是否报错、Endpoints 对象是否变为空、客户端访问得到的是连接被拒绝还是请求超时；把预测与实测结果一并记录 |
| 11 | 建立 NodePort 类型的 Service | 参照 `svc-nodeport.skeleton.yaml` 写出 `svc-nodeport.yaml`，执行 `kubectl create -f svc-nodeport.yaml`，然后执行 `kubectl get svc > outputs/04-nodeport.txt` | 读出 API Server 自动分配的节点端口，它的取值范围是 30000 至 32767 |
| 12 | 从宿主机访问节点端口 | 先执行 `kubectl get nodes -o wide` 取得节点地址，再执行 `curl <节点地址>:<节点端口>` | 记录访问结果；同时执行 `docker inspect kind-control-plane --format '{{json .NetworkSettings.Ports}}'` 观察端口映射情况，解释为什么 `localhost` 无法访问 |
| 13 | 观察没有选择器的 Service | `kubectl get svc kubernetes -o yaml > outputs/05-kubernetes-svc.txt`，然后执行 `kubectl get endpoints kubernetes` | 确认这个 Service 没有 `spec.selector` 字段，而它的 Endpoints 指向控制平面节点的 6443 端口 |
| 14 | 观察环境变量形式的服务发现 | `kubectl exec -it <某个 webapp Pod 的名称> -- env \| grep -i <服务名的大写形式>` | 确认容器中存在 `<服务名的大写形式>_SERVICE_HOST` 与 `<服务名的大写形式>_PORT` 两个环境变量 |
| 15 | 清理第 8 步创建的临时 Pod | `kubectl get po` 确认没有残留的 `tmp` Pod | `--rm` 参数会在命令结束之后删除该 Pod；如果仍然存在，执行 `kubectl delete po tmp` |

## 四、验收标准

| 编号 | 标准 |
|---|---|
| 1 | ClusterIP 类型的 Service 创建成功，`kubectl get endpoints <服务名>` 中列出了全部处于就绪状态的 Pod 地址 |
| 2 | 在集群内部使用临时 Pod 访问服务名称，能够得到应用返回的内容 |
| 3 | 删除一个 Pod 之后，Endpoints 中的地址被替换，而 Service 的 ClusterIP 没有变化 |
| 4 | 把选择器改成不匹配任何 Pod 之后，Endpoints 变为空，并且能够说明客户端访问失败的原因 |
| 5 | NodePort 类型的 Service 创建成功，并且能够说明从宿主机访问时为什么不能使用 `localhost` |
| 6 | 能够按照「客户端 → Service → Endpoints → Pod」的顺序，说明链路上每一步由哪个组件负责 |

## 五、常见错误与原因

| 现象 | 原因 | 处理方式 |
|---|---|---|
| 创建清单文件时报错，提示标签取值非法 | 骨架文件中的尖括号没有被替换，标签取值只允许包含字母、数字、短横线、下划线与点号，并且必须以字母或数字开头和结尾 | 执行 `kubectl create --dry-run=server -f <文件名>` 提前校验；这条错误对应第 2 周错题本中的 K1 |
| Endpoints 列表为空 | 选择器的取值与 Pod 标签不匹配，或者 Pod 尚未通过就绪判定 | 比较 `kubectl get po --show-labels` 与 `kubectl describe svc <服务名>` 中 `Selector` 一行的取值 |
| Endpoints 列表的条目数量少于 Pod 数量 | 部分 Pod 尚未就绪，因此没有被写入端点列表 | 执行 `kubectl get po`，确认 READY 列是否显示为 `1/1` |
| 临时 Pod 的状态为 `ImagePullBackOff` | 节点内部的容器运行时镜像库中没有 `busybox:1.36`，并且节点从公网拉取失败 | 先在宿主机执行 `docker pull busybox:1.36`，再执行 `kind load docker-image busybox:1.36` |
| 在宿主机执行 `curl localhost:<节点端口>` 失败 | kind 的节点本身是一个 Docker 容器，节点端口只暴露在节点容器的网络命名空间内；如果创建集群时没有通过 `extraPortMappings` 声明端口映射，宿主机上就没有对应的转发规则 | 执行 `kubectl get nodes -o wide` 取得节点地址，把访问地址改为 `<节点地址>:<节点端口>` |
| 访问服务名称时提示名称无法解析 | 临时 Pod 的 DNS 配置不正确，或者 CoreDNS 没有正常运行 | 执行 `kubectl get po -n kube-system` 确认 CoreDNS 的 Pod 处于就绪状态；也可以改用 `<服务名>.<命名空间>.svc.cluster.local` 这个完整域名访问 |

## 六、验收结果（2026-09-20 完成）

| 编号 | 标准 | 结果 |
|---|---|---|
| 1 | ClusterIP 类型的 Service 创建成功，端点列表包含全部处于就绪状态的 Pod 地址 | ✅ 端点列表为 `10.244.0.2:8080,10.244.0.3:8080`，与两个处于就绪状态的 Pod 一致 |
| 2 | 在集群内部使用临时 Pod 访问服务名称，能够得到应用返回的内容 | ✅ 两次返回 `<h1>Hello DevOps</h1>` |
| 3 | 删除一个 Pod 之后端点中的地址被替换，而 ClusterIP 没有变化 | ✅ `10.244.0.3:8080` 被替换为 `10.244.0.9:8080`，ClusterIP 保持 `10.96.135.12` |
| 4 | 选择器改成不匹配任何 Pod 之后端点变为空，并能够说明客户端访问失败的原因 | ✅ 端点为 `<none>`，客户端得到 `Connection refused`，原因是 kube-proxy 为没有后端的 Service 写入了拒绝规则，而不是把数据包静默丢弃 |
| 5 | NodePort 类型的 Service 创建成功，并能够说明从宿主机访问时不能使用 `localhost` 的原因 | ✅ 节点端口 `31873` 由 API Server 自动分配；节点容器只发布了 API Server 的端口，因此 `localhost` 与节点地址都无法从宿主机访问，验证改用节点容器内部与集群内部两种方式完成 |
| 6 | 能够按照「客户端 → Service → Endpoints → Pod」的顺序说明链路上每一步由哪个组件负责 | ✅ 见 `notes/week2/day2.md` 第三节的 3.4 与 3.8 两个小节 |

> 原始输出统一保存在 `outputs/` 目录；补做实验的完整记录在 `outputs/07-fix-and-verify.txt`。
