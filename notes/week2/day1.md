# Day 1 学习笔记 · Pod 与 Deployment

> 日期：2026-09-18 · 代码：`code/week2/day1/`（`pod.webapp.yaml`、`deploy.webapp.yaml`）
> 配套资料：`docs/k8s_in_action/02-Pod与副本机制.md`，以及 `plan/week2/任务明细.md` 中的 Day 1
> 起点资产：第 1 周构建的镜像 `webapp:v4`（占用磁盘 25.3MB、以非 root 用户 uid 10001 运行、基于 alpine 底座）
> 本周的模型变化：从「直接命令 Docker 执行动作」转为「声明期望的状态，由 Kubernetes 的控制器把实际状态调整到期望状态」。

---

## 一、今日速览（结论，收尾时填）

| 编号 | 结论 |
|---|---|
| 1 | 集群状态：单节点 kind 集群，节点名称为 `kind-control-plane`，节点地址为 172.18.0.2；`kubectl get nodes` 与 Pod 的 `NODE` 列显示一致。 |
| 2 | 镜像为什么需要导入节点：`kind load docker-image webapp:v4` 把镜像写入节点内部的容器运行时镜像库。证据是 `kubectl describe` 输出中的 `Image ID` 为 `docker.io/library/import-2026-09-18@sha256:4bf2cfd4…`，其中 `import-2026-09-18` 是导入时生成的引用，说明容器使用的镜像来自节点内部，而不是从远程仓库拉取。 |
| 3 | Pod 与容器的关系：Pod 是一组被放在同一个节点上共同运行的容器集合，它是调度的最小单位；同一个 Pod 内的容器共享 Network、UTS、IPC 三种命名空间，因此共用 IP 地址、主机名与端口空间，文件系统默认互相隔离。 |
| 4 | 删除 Pod 之后重建：新 Pod 的名称与 IP 地址都会改变（本次观察到的 IP 依次为 10.244.0.6、10.244.0.7、10.244.0.9、10.244.0.10、10.244.0.11），这说明 Pod 是一次性对象，删除并重建等价于创建一个全新的对象。 |
| 5 | 裸 Pod 与 Deployment 的差异：删除裸 Pod 之后不会自动恢复；删除由 Deployment 管理的 Pod 之后，ReplicaSet 控制器会创建一个新 Pod 补齐数量，本次观察到 `webapp-7dbcc8ff4b-cz4vc` 被删除后出现了 `webapp-7dbcc8ff4b-qpndp`，其 AGE 为 8 秒。 |
| 6 | 遗留疑问：扩容与缩容时，控制器依据什么顺序选择要删除的 Pod？（属于实现细节，本次不展开） |

---

## 二、任务清单

| 编号 | 任务 | 完成 | 原始输出留在哪 |
|---|---|---|---|
| 1 | 检查集群状态（`docker ps -a --filter name=kind` 与 `kubectl get nodes`） | ✅ | 间接证据：Pod 的 `NODE` 列为 `kind-control-plane` |
| 2 | 执行 `kind load docker-image webapp:v4` 把镜像导入节点 | ✅ | 间接证据：`Image ID` 为 `import-2026-09-18@sha256:…` |
| 3 | 用 `kubectl run --dry-run=client -o yaml` 生成 YAML 模板，并逐字段阅读 | ✅ | `outputs/00-dry-run-pod.yaml`、`outputs/00b-dry-run-deploy.yaml` |
| 4 | 自己编写 `code/week2/day1/pod.webapp.yaml` 并创建裸 Pod | ✅ | 同上 |
| 5 | 执行 `kubectl get po -o wide`、`kubectl describe po`、`kubectl logs` | ✅ | `outputs/01-po-wide.txt` |
| 6 | 执行 `kubectl port-forward`，并在另一个终端执行 `curl` 验证 | ⬜ | 待确认 |
| 7 | 执行 `kubectl exec` 进入容器，查看 `/proc/1/cmdline`、`hostname`、`env` | ⬜ | 待确认 |
| 8 | 删除裸 Pod，确认它不会自动恢复 | ⬜ | 待确认 |
| 9 | 编写并创建 `code/week2/day1/deploy.webapp.yaml`（副本数量为 3） | ✅ | 同上 |
| 10 | 执行 `kubectl get deploy,rs,po` 同时观察三层对象 | ✅ | `outputs/02-three-layers.txt` |
| 11 | 删除一个由 Deployment 管理的 Pod，确认控制器自动补齐 | ✅ | 同上 |
| 12 | 执行 `kubectl scale` 完成一次扩容与一次缩容 | ✅ | 同上 |
| 13 | 完成 Linux 每日一题 Day 8（umask） | ⬜ | 待完成 |
| 14 | 回答当天的面试问答卡（四道题，见 `plan/week2/任务明细.md`） | ⬜ | 待完成 |

---

## 三、概念（机制，用自己的话写）

### 3.1 Pod 是什么

| 问题 | 答案 |
|---|---|
| Pod 是调度单位，这句话的推论是什么？ | 调度器以 Pod 为对象选择节点，因此同一个 Pod 内的全部容器必然位于同一个节点上，无法被拆分到两个节点。 |
| 同 Pod 容器共享哪些 namespace？ | 共享 Network、UTS、IPC 三种命名空间，因此共用 IP 地址、主机名与端口空间。 |
| 同 Pod 容器**不**共享什么？ | 默认不共享 PID 命名空间与文件系统，因此进程之间互不可见、文件系统互相隔离；需要共享目录时必须显式挂载卷。 |
| 同 Pod 两容器能绑同一端口吗？为什么？ | 不能，因为端口空间是共用的，第二个容器绑定该端口时会返回地址已被占用的错误。 |
| 不同 Pod 的端口会冲突吗？为什么？ | 不会，因为每个 Pod 拥有独立的网络命名空间，端口空间彼此独立。 |

### 3.2 与 Docker 的对应关系（本周的模型切换）

| 维度 | Docker（第 1 周） | Kubernetes（第 2 周） |
|---|---|---|
| 运行单位 | 容器 | Pod，也就是一组一起运行、并且始终位于同一节点上的容器 |
| 镜像来源 | 宿主机 Docker 的镜像库可以直接使用 | 只能使用节点内部容器运行时镜像库中的镜像，因此必须先执行 `kind load docker-image` |
| 网络访问 | `-p 8080:8080`，由宿主机上的 DNAT 规则完成 | 每个 Pod 拥有独立的 IP 地址；调试时使用 `kubectl port-forward`，正式的对外暴露方式在 Day 2 学习 Service 时介绍 |
| 进程退出 | 需要自己执行 `docker start` | kubelet 根据 `restartPolicy`（Pod 的默认值为 `Always`）自动重启容器 |
| 容器被删除 | 不会自动恢复 | 由 ReplicaSet 控制器创建一个新的 Pod 来补齐副本数量 |

### 3.3 Deployment 与 ReplicaSet 的关系

| 问题 | 答案 |
|---|---|
| 从提交 Deployment 到容器运行，一共经过哪几层对象？ | 四层：Deployment → ReplicaSet → Pod → 容器。 |
| 副本数量由哪一层对象负责维持？ | 由 ReplicaSet 负责维持，Deployment 只声明期望的副本数量。 |
| Deployment 为什么能够回滚？ | 因为升级时它会保留旧的 ReplicaSet，回滚时把旧 ReplicaSet 的副本数量重新调大。 |
| Pod 的名称为什么带有随机后缀？ | 因为 Pod 由控制器创建，名称由控制器生成。完整结构为 `<Deployment 名称>-<pod-template-hash>-<随机后缀>`，本次实测的哈希为 `7dbcc8ff4b`。 |

#### 补充说明：为什么裸 Pod 不会被 Deployment 接管

本次实验中，裸 Pod 的名称是 `webapp`，Deployment 的名称也是 `webapp`，两者的标签都包含 `app=webapp`，但是 Deployment 的副本统计中没有包含这个裸 Pod：`kubectl get deploy,rs,po` 的输出显示副本数为 `3/3`，对应的三个 Pod 全部带有 `pod-template-hash` 前缀。

原因是 Deployment 在创建 ReplicaSet 时，会把 `pod-template-hash` 这个标签追加到 ReplicaSet 的选择器中。因此 ReplicaSet 实际使用的选择器是 `app=webapp,pod-template-hash=7dbcc8ff4b`，而裸 Pod 缺少这个标签，所以不会被选中，也不会被计入副本数量。

Pod 名称的中间部分就是这个哈希值，它同时出现在三个位置：ReplicaSet 名称的后缀、ReplicaSet 选择器的一部分、Pod 名称的中间部分。这三处一致，正是控制器用来判断「这个 Pod 是否属于我」的依据。

如果跳过 Deployment 直接创建 ReplicaSet，那么它的选择器就只有 `app=webapp`，此时标签匹配的孤立 Pod 会被控制器接管（《Kubernetes in Action》中称之为收养，p.163-170）。这也是 Deployment 要在选择器中加入哈希标签的原因：避免把标签恰好相同的无关 Pod 误认为自己的副本。

---

## 四、命令

| 场景 | 命令 | 说明（修改了集群中的哪个对象或状态） |
|---|---|---|
| 查看集群与节点 | `kubectl get nodes` | 读取节点对象的状态，确认节点处于 `Ready`。 |
| 把镜像导入节点内部的镜像库 | `kind load docker-image webapp:v4` | 把宿主机 Docker 中的镜像写入节点内部的容器运行时镜像库。 |
| 生成 YAML 模板（只输出到文件，不创建资源） | `kubectl run webapp --image=webapp:v4 --port=8080 --dry-run=client -o yaml > outputs/00-dry-run-pod.yaml` | 由客户端生成清单模板，不会向 API Server 提交任何对象。 |
| 根据 YAML 创建资源 | `kubectl create -f pod.webapp.yaml` | 向 API Server 提交创建请求；如果对象已经存在，命令会报错。 |
| 以声明式方式创建或更新资源 | `kubectl apply -f deploy.webapp.yaml` | 向 API Server 提交期望状态；对象已经存在时执行更新而不是报错。 |
| 查看 Pod 的 IP 地址与所在节点 | `kubectl get po -o wide` | 读取 Pod 对象的 `status.podIP` 与 `spec.nodeName` 字段。 |
| 同时查看 Deployment、ReplicaSet、Pod 三层对象 | `kubectl get deploy,rs,po` | 一次读取三种资源，用于观察三层对象的对应关系。 |
| 查看事件记录（排查的第一步） | `kubectl describe po webapp` | 读取事件记录，本次观测到调度、镜像、创建、启动四个事件。 |
| 查看日志与上一个容器的日志 | `kubectl logs webapp` 与 `kubectl logs --previous` | 读取容器主进程写到标准输出的内容，后者用于查看已经被替换掉的容器。 |
| 进入容器内部 | `kubectl exec -it webapp -- sh` | 在容器内部执行命令。 |
| 转发端口 | `kubectl port-forward po/webapp 8888:8080` | 通过 API Server 与 kubelet 建立隧道，把本地端口转发到 Pod 的端口。 |
| 调整副本数量 | `kubectl scale deploy webapp --replicas=4` | 修改 Deployment 的期望副本数量，由 ReplicaSet 执行实际的增减。 |
| 删除 Pod | `kubectl delete po <名称>` | 删除 Pod 对象；如果该 Pod 由控制器管理，控制器会在下一轮对账时创建新的 Pod。 |

---

## 五、易错点

| 编号 | 易错点 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | 清单文件中保留了占位符 `<>` | 创建时被 API Server 拒绝，报错信息包含 `metadata.labels: Invalid value: "<>"` | 标签取值只能包含字母、数字、`-`、`_`、`.`，并且必须以字母数字开头和结尾。写完清单后可以先用 `kubectl create --dry-run=server -f <文件名>` 校验。 |
| 2 | 把 `status: {}` 写进清单文件 | 提交时会带上服务端字段 | `status` 字段由服务端写入，`--dry-run=client` 的输出保留了这个占位符，手写清单时应当删除。 |
| 3 | 把事件中的 `Pulled` 理解为真的拉取了镜像 | 误认为每次启动容器都会从远程仓库下载镜像 | 本次事件的原文是 `Container image "webapp:v4" already present on machine`，说明 kubelet 直接使用了节点上已有的镜像。原因是在镜像标签不是 `latest` 的情况下，`imagePullPolicy` 的默认值为 `IfNotPresent`。 |
| 4 | 认为标签相同的裸 Pod 会被 Deployment 接管 | 预期副本数量会变成 4 个 | Deployment 生成的 ReplicaSet，其选择器中还包含 `pod-template-hash`，因此不会选中缺少该标签的裸 Pod。 |
| 5 | 忽略 `describe` 输出中的其他字段 | 不清楚 `QoS Class`、`Tolerations`、`Mounts` 的含义 | `QoS Class: BestEffort` 说明没有设置资源请求与限制（第 3 周介绍）；`Tolerations` 是默认添加的容忍（第 3 周介绍）；`Mounts` 中的 `kube-api-access-…` 是自动挂载的 ServiceAccount 令牌卷（第 5 周介绍）。 |

---

## 六、我的疑问

- 缩容时控制器依据什么顺序选择要删除的 Pod？（本次观察到被删除的是两个较新的 Pod，但具体排序规则尚未查阅）
- `kubectl describe` 输出中的 `QoS Class`、`Tolerations`、`Mounts` 三个字段分别由什么机制产生？（已在易错点表中记录归属周次）
- `cat /proc/1/cmdline` 在容器内没有正常显示内容，原因见第七节末尾。

---

## 七、面试问答卡批改记录（Day 1）

| 题目 | 我的回答要点 | 批改结论 |
|---|---|---|
| 1. 同 Pod 容器共享哪些命名空间？ | 共享 Network、UTS；不共享文件系统、IPC、PID；不能监听同一端口 | 漏了 **IPC**：同一个 Pod 内的容器**共享** Network、UTS、IPC 三种命名空间；**不共享**的是 PID（默认）与文件系统。其余部分正确。 |
| 2. `RESTARTS` 统计的是什么？ | 不确定，认为是启动次数；Pod 不是持久对象；IP 每次启动都会变 | 三个需要修正的点：① 统计的是**容器被重启的次数**，第一次启动不计入，因此 `RESTARTS 0` 表示从未重启；② Pod 的 IP 在**生命周期内不变**，只有 Pod 被删除并重建之后才会获得新 IP；③ 与 Docker 容器对比的方向是正确的（Docker 容器的可写层在 stop 与 start 之间保留，而 Pod 删除即新建）。 |
| 3. 为什么宿主机 `docker images` 里有的镜像，kind 节点看不到？ | kind 是运行在 Docker 容器里的集群，因此被隔离，节点读不到外部 Docker 的镜像 | 方向正确。更精确的表述是：两层各自拥有**独立的镜像库**。宿主机上是 Docker 守护进程的镜像库，节点容器内部是 containerd 的镜像库，两者是不同的存储目录，因此必须用 `kind load docker-image` 把镜像复制过去。 |
| 4. Docker 的 `-p` 与 `kubectl port-forward` 在机制上有什么区别？ | `-p` 是宿主机端口到容器端口的映射，会按字面暴露；Kubernetes 中的端口声明不是强制的；`port-forward` 与 Service 有关 | 方向部分正确，需要补充机制：`-p` 由**内核**的 netfilter 规则完成 DNAT；`containerPort` 与 Dockerfile 的 `EXPOSE` 一样只是声明；`port-forward` 是**用户态隧道**（kubectl → API Server → kubelet → 容器），**不经过 Service**，是绕过 Service 的临时调试通道。 |

### 容器内查看进程与环境的两个操作问题

| 现象 | 原因 | 正确做法 |
|---|---|---|
| `cat hostname` 与 `cat env` 提示找不到文件 | `hostname` 与 `env` 是**可执行命令**，不是文件，因此不能用 `cat` 读取 | 直接执行 `hostname` 与 `env`；如果要读取内核提供的信息，主机名文件是 `/proc/sys/kernel/hostname`，环境变量是 `/proc/1/environ` |
| `cat /proc/1/cmdline` 没有正常显示 | `/proc/<PID>/cmdline` 使用 NUL 字节分隔各个参数，直接输出到终端时多个参数会挤在一起，看起来像空行或乱码 | 用 `tr '\0' ' ' < /proc/1/cmdline` 把分隔符转换为空格，或用 `cat -v /proc/1/cmdline` 查看 |

---

## 八、Linux 每日一题 Day 8 · 文件权限与 umask（讲解式完成）

> 说明：本题涉及的概念此前没有接触过，因此本轮不采用「先自己答」的方式，而是直接给出完整答案与机制，并附上可以自己验证的命令。

| 问题 | 答案 |
|---|---|
| ① `umask` 为 `022` 时，新建文件与新建目录的默认权限分别是多少？为什么文件的权限不是 `666`？ | 新建文件的权限是 `644`（`rw-r--r--`），新建目录的权限是 `755`（`rwxr-xr-x`）。文件不是 `666` 的原因有两层：第一层是 `umask 022` 屏蔽了 group 与 others 的**写位**，因此 `666` 变为 `644`；第二层是**文件的基准权限本来就是 `666`**，其中不包含执行位，因为新建文件默认不应当可执行（否则下载或生成的文件会未经确认就能运行），而目录的基准权限是 `777`，因为目录必须带执行位才能被进入。 |
| ② 希望新建目录为 `750`、新建文件为 `640`，`umask` 应当设置为多少？ | `umask` 应当设置为 `027`。验证：目录 `777 & ~027 = 750`；文件 `666 & ~027 = 640`。 |

### 权限模型（本次补充的基础）

| 概念 | 内容 |
|---|---|
| 权限位的数值 | 读 `r` 为 4，写 `w` 为 2，执行 `x` 为 1；一组三位的最大值是 7。 |
| 三类身份 | 属主（u）、属组（g）、其他人（o），因此一组完整权限由九个位组成，例如 `rw-r--r--` 对应 `644`。 |
| `ls -l` 的第一个字符 | 文件类型：`-` 普通文件、`d` 目录、`l` 符号链接、`c` 字符设备、`b` 块设备、`s` 套接字、`p` 命名管道。 |
| `x` 对文件的含义 | 允许把该文件作为程序执行。 |
| `r` 对目录的含义 | 允许列出目录内的名字，也就是可以执行 `ls`。 |
| `w` 对目录的含义 | 允许在目录内创建、删除、重命名条目。**删除一个文件取决于该文件所在目录的写权限，而不是文件自身的权限。** |
| `x` 对目录的含义 | 允许进入该目录，也允许访问目录内已知名字的条目，称为搜索权限。 |

### umask 的机制

| 要点 | 内容 |
|---|---|
| 定义 | `umask` 是一个**权限掩码**，作用是**屏蔽**新建文件或目录将要获得的权限位，而不是赋予权限。 |
| 计算公式 | `最终权限 = 基准权限 & ~umask`，也就是「按位与非」。 |
| 基准权限 | 文件为 `666`，目录为 `777`。更准确地说，程序创建文件时会向内核请求一个模式（`touch` 请求 `0666`，`mkdir` 请求 `0777`），内核执行 `mode & ~umask` 得到最终权限。 |
| 为什么不能用减法 | 常见掩码（`022`、`002`、`077`）用减法恰好得到相同结果，因此容易形成错误习惯。`umask 027` 时减法会算出 `637`，而正确结果是 `640`，原因是减法在 others 组发生了借位，破坏了每个三位组互相独立的语义。 |
| 生效范围 | `umask` 是**进程属性**。在终端里执行 `umask 027` 只影响当前 shell 及其启动的子进程，关闭终端后恢复。 |
| `umask -S` 的差别 | 该命令输出的是**允许**的权限，例如 `u=rwx,g=rx,o=rx`，与八进制掩码的语义相反，两者容易混淆。 |
| 永久修改 | 写进 `~/.zshrc`、`~/.bashrc` 或系统级配置（`/etc/profile`、`/etc/login.defs`）。 |
| 只影响新建 | `umask` 不影响已经存在的文件；修改已有文件的权限要使用 `chmod`。 |

### 建议自己实际验证的命令

| 目的 | 命令 | 说明 |
|---|---|---|
| 查看当前掩码 | `umask` 与 `umask -S` | 同时观察八进制形式与符号形式，理解两者语义相反。 |
| 观察默认权限 | `touch /tmp/f1; mkdir /tmp/d1; ls -l /tmp/f1; ls -ld /tmp/d1` | 在当前掩码下创建文件与目录，比较两者权限的差异。 |
| 观察掩码改变后的效果 | `(umask 027; touch /tmp/f2; mkdir /tmp/d2; stat -c '%a %n' /tmp/f2 /tmp/d2)` | 括号表示在子 shell 中执行，退出之后当前 shell 的掩码不受影响。预期输出为 `640` 与 `750`。 |
| 对比减法与按位与非 | `(umask 027; touch /tmp/f3; stat -c '%a' /tmp/f3)` | 结果是 `640`；而按八进制做 `666 - 027` 得到 `637`，两者不同，说明必须使用按位与非。 |
