# outputs 目录 · 原始输出记录的命名规则

> 本目录用于保存命令的原始输出。每一项观察类实验都必须在输出文件旁边保留结论，说明这些输出证明了什么。
> 记录方式示例：`kubectl get cm webapp-config -o yaml > outputs/02-cm-yaml.txt`。
> 追加输出时不要覆盖旧文件：需要对比两次结果时使用 `>>` 追加，或者使用两个不同编号的文件。

| 文件 | 产生它的命令 | 这份输出要证明什么 |
|---|---|---|
| `00-baseline-cluster.txt` | `docker ps -a --filter name=kind`、`kubectl get nodes -o wide` | 实验开始之前节点容器的状态与节点的 STATUS 取值 |
| `00-baseline-pods.txt` | `kubectl get po -o wide --show-labels` | 创建新对象之前的 Pod 清单、IP 地址与标签 |
| `00-baseline-cm.txt` | `kubectl get cm -A` | 创建之前已经存在的 ConfigMap，其中包含系统自动创建的 `kube-root-ca.crt` |
| `00-baseline-secret.txt` | `kubectl get secret -A` | 创建之前已经存在的 Secret，其中包含服务账户令牌 |
| `00-baseline-workload.txt` | `kubectl get deploy,svc -o wide` | 创建之前的 Deployment 与 Service，用于确认 Deployment `webapp` 的镜像标签是 `webapp:v4` |
| `00-baseline-appdir.txt` | `kubectl exec deploy/webapp -- sh -c '...'` | 证明镜像内部没有配置目录，因此配置只能来自部署时注入 |
| `00-baseline-images.txt` | `docker images webapp --format ...` | 构建之前的镜像标签与体积 |
| `01-dry-run-cm.yaml` | `kubectl create configmap ... --dry-run=client -o yaml` | 客户端生成的 ConfigMap 模板，其中取值是明文 |
| `01-dry-run-secret.yaml` | `kubectl create secret generic ... --dry-run=client -o yaml` | 客户端生成的 Secret 模板，其中 `data` 里的取值已经变成 base64 编码 |
| `02-cm-yaml.txt` | `kubectl get cm webapp-config -o yaml` | ConfigMap 的实际存储形式，取值是明文 |
| `02-secret-yaml.txt` | `kubectl get secret webapp-secret -o yaml` | Secret 的实际存储形式，取值是 base64 编码；同时包含 `base64 -d` 还原出来的明文 |
| `02-describe-cm.txt` | `kubectl describe cm webapp-config` | ConfigMap 的键数量、每一个键的取值长度与内容摘要 |
| `02-describe-secret.txt` | `kubectl describe secret webapp-secret` | Secret 的键数量与每一个键的取值长度。**注意：这条命令只输出字节数，不输出取值本身，这与 ConfigMap 的表现不同** |
| `03-env-injected.txt` | `kubectl exec deploy/webapp -- env` | 三个合法键名注入成功、`FOO-BAR` 没有出现，用于验证 `envFrom` 对不合法键名的处理方式 |
| `03-app-report-env.txt` | `kubectl exec deploy/webapp -- wget -qO- http://localhost:8080/` | 没有挂载卷的 Deployment 中，文件来源显示为读取失败 |
| `04-volume-files.txt` | `kubectl exec deploy/webapp-vol -- ls -la /etc/webapp /etc/webapp-file` | 一个键对应一个文件、`..data` 符号链接与 `..2026_...` 目录的存在 |
| `05-config-drift.txt` | 第 15 步的三条命令的输出 | 同一次请求中环境变量保持旧取值、文件变成新取值，用于解释两种注入方式的差异 |
| `06-rollout-restart.txt` | `kubectl rollout restart deploy/webapp` 之后执行 `kubectl get po -o wide` 与 `env \| grep GREETING` | 环境变量方式需要重建容器才能读到新取值，同时 Pod 的名称与 IP 地址都发生变化 |
| `07-subpath.txt` | 第 17 步中 `ls -l /etc/webapp-file` 与两个文件的 `cat` 输出，改配置前后各记录一次 | 整卷挂载的 `config.conf` 是指向 `..data` 的符号链接并且会更新，`subPath` 挂载的 `sub-config.conf` 是普通文件且不更新 |
| `08-secret-volume.txt` | 第 18 步中 `ls -la /etc/webapp-secret`、`cat /etc/webapp-secret/DB_PASSWORD` 与 `env \| grep DB_PASSWORD` 的输出 | Secret 写入卷之前已经完成解码，卷内与进程环境中都是明文；同时记录卷内文件的默认权限 |

> 汇总要求：`notes/week2/day3.md` 的「今日速览」表格中，每一条结论都必须指向本目录下的某一个文件，不能只写结论而不留下原始输出。
