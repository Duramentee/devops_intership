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
