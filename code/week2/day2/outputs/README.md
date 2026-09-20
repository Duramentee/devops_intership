# outputs 目录 · 原始输出记录的命名规则

> 本目录用于保存命令的原始输出。每一项观察类实验都必须在输出文件旁边保留结论，说明这些输出证明了什么。
> 记录方式示例：`kubectl get endpoints webapp > outputs/02-endpoints.txt`。

| 文件 | 产生它的命令 | 这份输出要证明什么 |
|---|---|---|
| `00-baseline-pods.txt` | `kubectl get po -o wide --show-labels` | 创建 Service 之前的 Pod 数量、IP 地址与标签，作为后续对比的参照物 |
| `00-baseline-svc.txt` | `kubectl get svc -o wide` | 创建 Service 之前已经存在的 Service 清单，其中包含默认命名空间里的 `kubernetes` |
| `00-baseline-endpoints.txt` | `kubectl get endpoints -o wide` | 创建 Service 之前已经存在的 Endpoints 对象 |
| `00-baseline-nodes.txt` | `kubectl get nodes -o wide` | 节点的名称与地址，从宿主机访问节点端口时需要使用该地址 |
| `01-dry-run-svc.yaml` | `kubectl expose deploy webapp --port=8080 --dry-run=client -o yaml` | 由客户端生成的清单模板，用于分辨必填字段与默认值字段 |
| `02-svc-clusterip.txt` | `kubectl get svc -o wide` | ClusterIP 类型 Service 的虚拟地址与端口映射关系 |
| `02-endpoints-clusterip.txt` | `kubectl get endpoints <服务名>` | 端点列表的条目与处于就绪状态的 Pod 之间的对应关系 |
| `02-endpointslices.txt` | `kubectl get endpointslices -o wide` | 同一个 Service 的端点如何被写入 EndpointSlice 对象 |
| `03-endpoints-before.txt` | `kubectl get endpoints <服务名>` | 删除 Pod 之前的端点列表 |
| `03-endpoints-after.txt` | `kubectl get endpoints <服务名>` | 删除 Pod 并等待新 Pod 就绪之后的端点列表，用于证明端点地址被替换而 ClusterIP 不变 |
| `04-selector-mismatch.txt` | `kubectl get endpoints <服务名>`，以及客户端访问命令的完整输出 | 选择器不匹配任何 Pod 时，端点列表与访问请求分别出现什么结果 |
| `05-nodeport.txt` | `kubectl get svc` | API Server 自动分配的节点端口 |
| `06-kubernetes-svc.txt` | `kubectl get svc kubernetes -o yaml`，以及 `kubectl get endpoints kubernetes` | 没有选择器的 Service 依靠人工创建的 Endpoints 对象工作 |

> 汇总要求：`notes/week2/day2.md` 的「今日速览」表格中，每一条结论都必须指向本目录下的某一个文件，不能只写结论而不留下原始输出。

## 本次实验实际生成的文件

| 文件 | 实际记录的内容 |
|---|---|
| `00-baseline-pods.txt` | 两个处于 Running 状态的 Pod（`webapp-7dbcc8ff4b-pvr9k` 与 `-r8jvf`）、它们的 IP、节点与标签，以及 `RESTARTS` 为 `1 (49s ago)` 这一条异常线索 |
| `00-baseline-svc.txt` | 创建 Service 之前，命名空间中只有 `kubernetes` 一个 Service |
| `00-baseline-endpoints.txt` | `kubernetes` 的端点是 `172.18.0.2:6443` |
| `00-baseline-nodes.txt` | 节点 `kind-control-plane` 的地址 `172.18.0.2`、版本 v1.37.0、容器运行时 containerd 2.3.4 |
| `01-dry-run-svc.yaml` | 客户端生成的清单模板，其中带有 `status: loadBalancer: {}` 这一处服务端字段 |
| `02-svc-clusterip.txt` | `kubectl get svc -o wide` 与 `kubectl get endpoints webapp` 的输出，以及 v1 Endpoints 的废弃警告 |
| `02-endpointslice.txt` | `kubectl get endpointslices -o wide` 的输出，其中 `webapp-jjm4b` 登记的地址与 Endpoints 一致 |
| `03-busybox.txt` | 临时 Pod 两次访问服务名得到的 `<h1>Hello DevOps</h1>` |
| `03-endpoints-before.txt` 与 `03-endpoints-after.txt` | 删除 Pod 前后的端点列表，以及 `kubectl describe svc webapp` 的完整字段 |
| `04-endpoints-error.txt` | 选择器不匹配任何 Pod 时，`get svc`、`get endpoints` 与 `wget` 三条命令的原始输出 |
| `04-nodeport.txt` | NodePort 的自动分配结果 `8080:31873/TCP`、节点容器的端口发布信息与三次 `curl` 的输出 |
| `05-kubernetes-svc.txt` | `kubernetes` Service 的完整 YAML 与它的端点 |
| `06-service-env.txt` | 容器内与 `WEBAPP` 相关的环境变量 |
| `07-fix-and-verify.txt` | 补做实验的原始输出与逐段结论：代理变量、路由查询、宿主机直连超时、节点容器内部访问成功、集群内部访问成功、删除 Service 之后端点对象消失、沙箱重建与重启计数、容器环境变量的注入时刻与时效性 |
