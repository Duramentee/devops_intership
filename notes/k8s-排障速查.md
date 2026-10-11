# Kubernetes 排障速查（状态模型 · 分段职责 · 字段对照 · 取证顺序）

> 建立日期：2026-09-25。
> 建立原因：第 3 周的排障任务要求把判断依据落到具体的字段上，而不是依赖记忆去猜测原因。在进入排障任务之前，需要先建立四个认知模型与一条操作纪律，否则即使 `kubectl describe` 的输出摆在面前也读不出结论。
> 与 `notes/k8s-对象词典.md` 的分工：对象词典记录每一个对象的定义、层级与字段清单；本文件记录故障发生时应当查看哪一层的哪一个字段，以及取证与判断的先后顺序。
> 与 `notes/weekN/dayN.md` 的分工：日笔记只记录当天新确认的字段、被实测推翻的结论与新确认的边界条件；本文件是跨天使用的速查表，允许与日笔记重复。
> 与 `docs/k8s_in_action/` 的分工：模块讲义按主题组织知识；本文件按故障现象组织判断路径。
> 教材对应章节：第 11 章讲解组成 Kubernetes 集群的全部组件及其职责划分，第 14 章讲解如何限制每个应用程序允许使用的计算资源，第 16 章讲解如何确保 Pod 只被调度到特定的节点。

---

## 一、四个认知模型（摘要）

| 编号 | 模型 | 一句话说明 | 缺少它会出现的后果 |
|---|---|---|---|
| 1 | Pod 的四层状态字段 | `STATUS` 列只是客户端拼出来的显示值，真实状态分散在 `phase`、`containerStatuses[].state`、`reason` 与 `conditions` 四层之中 | 看到 `Pending` 却无法判断故障落在哪一段 |
| 2 | 一次提交经过的五段链路 | 一次提交依次经过准入、调度、卷与镜像准备、容器创建、运行与退出五段，每一段由不同的组件负责 | 会在错误的组件上寻找原因，例如把镜像拉取失败当成调度失败 |
| 3 | 内存不可压缩、CPU 可压缩 | 超过 `limits` 时，内存的处置结果是终止进程，CPU 的处置结果是暂停进程 | 无法解释为什么内存超限被杀死而 CPU 超限只是变慢 |
| 4 | 四层日志各回答一个问题 | 应用日志、上一个容器的日志、kubelet 日志与内核日志分别回答不同的问题 | 会在应用日志里反复查找一个只被 kubelet 记录下来的错误 |

---

## 二、模型 1：Pod 的四层状态字段

### 2.1 四层的字段位置、写入者与取值范围

| 层 | 字段位置 | 由谁写入 | 取值范围 | 在排障中的用途 |
|---|---|---|---|---|
| 粗粒度阶段 | `status.phase` | 创建时由 API Server 置为 `Pending`，此后由节点上的 kubelet 通过状态子资源上报更新 | `Pending`、`Running`、`Succeeded`、`Failed`、`Unknown` | 只能判断 Pod 是否已经进入运行阶段，粒度很粗，无法定位原因 |
| 容器状态机 | `status.containerStatuses[].state` | kubelet | `waiting`、`running`、`terminated` 三者之中同时只有一个成立 | 决定故障发生在容器创建之前还是容器运行之后 |
| 具体原因 | `waiting.reason`、`terminated.reason`、`terminated.exitCode` | kubelet 与容器运行时 | `ImagePullBackOff`、`CrashLoopBackOff`、`CreateContainerConfigError`、`OOMKilled`、`Completed` 等 | 排障的主战场，绝大多数结论在这一层得出 |
| 条件汇总 | `status.conditions[]` | 调度器写入 `PodScheduled`，kubelet 写入其余条件 | `PodScheduled`、`Initialized`、`ContainersReady`、`Ready` 四个条件，每个条件带 `status`、`reason`、`message`、`lastTransitionTime` | 判断 Pod 是否已经完成调度、是否已经完成初始化、是否已经进入就绪状态 |

### 2.2 `STATUS` 列的拼接规则

`kubectl get po` 输出中的 `STATUS` 列并不是 API 中的一个字段，而是客户端依据容器状态拼出来的显示值。当需要判断某一行输出代表什么时，按下面的顺序解读：

| 顺序 | 判定条件 | 显示结果 |
|---|---|---|
| 1 | 容器处于 `waiting` 状态并且带有 `reason` | 直接显示这个 `reason`，例如 `ImagePullBackOff`、`CrashLoopBackOff`、`CreateContainerConfigError` |
| 2 | 初始化容器尚未全部完成 | 显示 `Init:0/1` 这种形式；初始化容器失败时显示 `Init:Error`，初始化容器反复重启时显示 `Init:CrashLoopBackOff` |
| 3 | 容器全部处于 `running` 状态并且没有 `waiting.reason` | 显示 `Running`，此时真正的信息在独立的 `READY` 列，也就是已就绪容器数量除以容器总数 |
| 4 | 容器已经终止并且带有 `terminated.reason` | 显示这个 `reason`，例如 `Completed`、`Error`、`OOMKilled` |
| 5 | 以上都不成立 | 回退到 `phase` 的取值 |

由于 `STATUS` 列在多数情况下显示的是 `waiting.reason`，同一个 `Pending` 后面可以对应四种完全不同的原因，因此**不能只看 `STATUS` 列就下结论**，必须继续读取 `reason` 所在的容器状态。

### 2.3 `waiting.reason` 的常见取值

| 取值 | 含义 | 故障落在哪一段 | 第一个应当观察的位置 |
|---|---|---|---|
| `ContainerCreating` | 容器正在被创建，包含卷准备与沙箱创建两个动作 | 第三段 | 若长时间停留，查看事件中是否出现 `FailedMount` 或 `FailedAttachVolume` |
| `ErrImagePull` | 单次镜像拉取失败 | 第三段 | 事件中 `Failed` 事件的 `message` 字段 |
| `ImagePullBackOff` | 镜像持续拉取失败，kubelet 已经进入退避重试 | 第三段 | 事件中 `Failed` 事件的 `message` 字段，以及节点上 `crictl images` 的镜像缓存 |
| `InvalidImageName` | 镜像名称的书写不合法 | 第一段或第三段 | Pod 的 `spec.containers[].image` 字段 |
| `ImageInspectError` | 镜像元数据无法读取 | 第三段 | 事件中的具体报错文本 |
| `ErrImageNeverPull` | `imagePullPolicy` 为 `Never`，而节点上不存在该镜像 | 第三段 | `spec.containers[].imagePullPolicy` 字段与节点的镜像缓存 |
| `CrashLoopBackOff` | 容器反复启动后立即退出，kubelet 已经进入退避重试 | 第五段 | `lastState.terminated` 的 `exitCode` 与 `reason` |
| `CreateContainerConfigError` | 组装容器配置时引用的对象不存在 | 第四段 | 容器引用的 ConfigMap 名称、Secret 名称与键名 |
| `CreateContainerError` | 容器创建失败，原因不由配置引用造成 | 第四段 | 事件中的具体报错文本 |
| `RunContainerError` | 容器运行时拒绝启动容器 | 第四段 | 节点上的 kubelet 日志 |
| `PodInitializing` | 初始化容器尚未完成 | 第四段 | `initContainerStatuses` |
| `ContainerStatusUnknown` | 节点失联，kubelet 无法上报容器状态 | 第五段 | 节点的 `Ready` 条件与 kubelet 日志 |

### 2.4 `terminated.reason` 的常见取值

| 取值 | 含义 | 与退出码的关系 |
|---|---|---|
| `Completed` | 容器主进程以退出码 0 正常结束 | `exitCode` 为 0 |
| `Error` | 容器主进程以非零退出码结束 | `exitCode` 为非零值，具体取值由应用决定 |
| `OOMKilled` | 容器使用的内存超过 `limits`，被 cgroup 级 OOM 终止 | `exitCode` 为 137，也就是 128 加上信号编号 9 |
| `ContainerCannotRun` | 容器运行时无法启动容器主进程 | `exitCode` 由运行时给出，常见 128 以上取值 |
| `DeadlineExceeded` | 任务超过 `activeDeadlineSeconds` 被终止 | 只出现在 Job 管理的 Pod 上 |

### 2.5 退出码与信号的对应关系

第 1 周已经打下的退出码基础可以直接迁移到这一层，因为两者都由内核记录：

| 退出码 | 计算方式 | 对应信号 | 在 Kubernetes 中的常见来源 |
|---|---|---|---|
| 0 | 应用自行返回 | 无 | 主进程正常结束，配合 `restartPolicy: Always` 时会触发重启 |
| 1 与 2 | 应用自行返回 | 无 | 应用自身的配置错误、依赖缺失、参数错误 |
| 126 与 127 | 应用自行返回 | 无 | 命令不存在或者不可执行，问题出在镜像的 `ENTRYPOINT` 与 `CMD` |
| 137 | 128 加上 9 | `SIGKILL` | 内存超限被终止、被 `kubectl delete --force` 强制删除、优雅终止期超时后升级为 `SIGKILL` |
| 143 | 128 加上 15 | `SIGTERM` | 收到优雅终止信号，通常由 `kubectl delete`、滚动升级或者 `preStop` 之后的标准流程发出，属于正常流程 |

---

## 三、模型 2：一次提交经过的五段链路

### 3.1 五段链路总表

| 段 | 执行者 | 它执行的动作 | 失败时写入什么 | 在哪个对象上观察 |
|---|---|---|---|---|
| 第一段 准入与持久化 | API Server 与 etcd | 校验字段合法性、执行准入控制器、写入期望状态 | 客户端直接收到报错，严重时 Pod 根本没有被创建 | 终端输出，以及 `kubectl apply --dry-run=server` 的返回结果 |
| 第二段 调度 | kube-scheduler | 依据资源余量、`nodeSelector`、`nodeAffinity`、污点与容忍筛选节点，把选中的节点写入 `spec.nodeName` | 事件 `FailedScheduling`，事件的 `source.component` 为 `default-scheduler` | `kubectl describe po` 输出末尾的 `Events` 段落 |
| 第三段 卷与镜像准备 | 节点上的 kubelet 与容器运行时 | 挂载卷、通过 CRI 拉取镜像、创建 Pod 沙箱 | `FailedAttachVolume`、`FailedMount`、`ErrImagePull`、`Failed` | 事件以及 `waiting.reason` 字段 |
| 第四段 容器创建 | kubelet、容器运行时、runc | 把环境变量、卷、命令组装成容器配置，再调用 runc 启动容器 | `CreateContainerConfigError`、`CreateContainerError`、`RunContainerError`、`ContainerCannotRun` | `waiting.reason` 与节点上的 kubelet 日志 |
| 第五段 运行与退出 | 容器内的进程、kubelet 的探针与重启逻辑 | 执行三种探针、按 `restartPolicy` 决定是否重启容器 | `CrashLoopBackOff`、`OOMKilled`、`Completed`、`Error` | `kubectl get po` 的 `READY`、`STATUS`、`RESTARTS` 三列，以及 `kubectl describe po` 中的 `State` 与 `Last State` 段落 |

### 3.2 这张表的使用方式

判断故障时不要从「可能是什么原因」开始列举，而是先从字段判断故障落在第几段，再从该段的执行者出发列出候选原因。判断出段号之后，候选原因通常只剩两到三条，定位时间因此可以压缩到十分钟以内。

| 观察到的字段 | 落在第几段 | 应当从哪里开始查 |
|---|---|---|
| `phase` 为 `Pending`，事件中出现 `FailedScheduling` | 第二段 | 检查 `nodeSelector`、`nodeAffinity`、污点与容忍、节点资源余量 |
| `waiting.reason` 为 `ImagePullBackOff` 或 `ErrImagePull` | 第三段 | 检查镜像名称、标签、私有仓库凭据，以及节点上的镜像缓存 |
| `waiting.reason` 为 `CreateContainerConfigError` | 第四段 | 检查容器引用的 ConfigMap 与 Secret 是否存在，键名是否匹配 |
| `waiting.reason` 为 `CrashLoopBackOff` | 第五段 | 检查 `lastState.terminated` 的退出码与原因，再读取上一个容器的日志 |
| `terminated.reason` 为 `OOMKilled` | 第五段 | 检查容器的 `limits` 取值、QoS 等级，以及节点上的内核日志 |

### 3.3 沙箱与容器的关系

第四段中有一个容易混淆的对象：Pod 沙箱。沙箱是容器运行时为这个 Pod 创建的运行环境，它承载 Pod 的 Network 命名空间与 IPC 命名空间；同一 Pod 内的所有容器都加入这个沙箱。因此当沙箱被重建时，Pod 会得到一个新的地址，事件中出现 `SandboxChanged`，此前运行的容器会以 255 退出码终止，而 Pod 的 `uid` 与 `creationTimestamp` 保持不变。这一条已经在第 2 周的实测中确认过，`status.startTime` 不随沙箱重建更新，因此不能用它判断沙箱是否被重建。

---

## 四、模型 3：内存不可压缩、CPU 可压缩

### 4.1 两种资源在超过 `limits` 时的不同处置

| 资源 | 超过 `limits` 时内核的动作 | 观察字段 | 判断依据来自哪一条机制 |
|---|---|---|---|
| 内存 | 触发 cgroup 级 OOM，选择并终止进程，发出 `SIGKILL` | `terminated.reason` 为 `OOMKilled`、`terminated.exitCode` 为 137，节点内核日志中出现 `Memory cgroup out of memory` | 已经分配出去的内存无法通过延后处理来回收，唯一的回收手段是终止进程 |
| CPU | 在当前周期内暂停这个 cgroup 的进程，等到下一个周期恢复 | 容器内 `/sys/fs/cgroup/cpu.stat` 中的 `nr_throttled` 与 `throttled_usec` 增长，外部表现为响应时间变长 | CPU 属于按时间片分配的份额，可以延后处理，不需要终止进程 |

### 4.2 与 cgroup 有关的观察点

| 观察对象 | 路径或命令 | 说明 |
|---|---|---|
| cgroup 版本 | `stat -fc %T /sys/fs/cgroup` | 输出 `cgroup2fs` 表示当前节点使用 v2，输出 `tmpfs` 表示当前节点使用 v1；两者的文件布局不同，应当先判断版本再读取具体文件 |
| 内存上限 | cgroup v2 下的 `memory.max` | 对应 Pod 中容器的 `resources.limits.memory` |
| 当前内存用量 | cgroup v2 下的 `memory.current` | 与 `memory.max` 比较可以判断距离超限还有多少余量 |
| OOM 计数 | cgroup v2 下的 `memory.events` | 其中的 `oom` 与 `oom_kill` 计数增长说明该 cgroup 发生过内存超限 |
| CPU 上限 | cgroup v2 下的 `cpu.max` | 一行两个取值，前者是配额，后者是周期，配额除以周期就是可见的核心数 |
| CPU 节流计数 | cgroup v2 下的 `cpu.stat` | 其中的 `nr_throttled` 与 `throttled_usec` 增长说明该 cgroup 被限制过 |

### 4.3 QoS 等级的判定条件

| 等级 | 判定条件 | 节点资源紧张时的处理顺序 |
|---|---|---|
| `Guaranteed` | Pod 中的每一个容器都为 CPU 与内存同时设置了 `requests` 与 `limits`，并且每一项资源的 `requests` 与 `limits` 取值相等 | 最后被驱逐，因为它的用量与申请量相等，不会挤占其他 Pod |
| `Burstable` | 至少有一个容器设置了 `requests` 或者 `limits`，并且整个 Pod 不满足 `Guaranteed` 的条件 | 中间被驱逐，其中实际用量超出 `requests` 幅度最大的 Pod 优先 |
| `BestEffort` | Pod 中的每一个容器都没有设置任何 `requests` 与 `limits` | 最先被驱逐，因为它没有为节点提供任何用量依据 |

判定结果可以在 `kubectl describe po` 输出的 `QoS Class` 一行直接读到，不必手工推导。

### 4.4 内核 OOM killer 与 kubelet 驱逐的区别

| 维度 | 内核 OOM killer | kubelet 驱逐 |
|---|---|---|
| 触发时机 | 节点物理内存耗尽的那一刻立即触发 | kubelet 周期性统计之后触发，软阈值还需要压力持续一段时间 |
| 作用对象 | 进程，被终止的进程所属的容器被记为 `OOMKilled`，`exitCode` 为 137 | 整个 Pod，被驱逐的 Pod 的 `status.reason` 为 `Evicted`，`phase` 为 `Failed`，`STATUS` 列显示 `Evicted` |
| 选择依据 | 依据内核的 `oom_score_adj` 打分，该取值由 QoS 等级换算而来：`Guaranteed` 为 -997，`BestEffort` 为 1000，`Burstable` 落在 2 到 999 之间 | 先按 QoS 等级排序，再按用量超出 `requests` 的幅度排序，最后参考 `priorityClassName` |
| 判断依据 | 节点上的内核日志中出现 `Memory cgroup out of memory` 与 `Killed process` | `kubectl describe node` 输出的 `Conditions` 段落中出现 `MemoryPressure` 或 `DiskPressure`，以及被驱逐 Pod 的 `status.reason` 字段 |

kubelet 的驱逐阈值有默认取值，例如内存可用量、节点文件系统可用率与索引节点可用率的硬阈值与软阈值，具体数值随 kubelet 版本与发行版配置不同，因此判断时应当以 `kubectl describe node` 输出的 `Conditions` 以及被驱逐 Pod 的事件为依据，而不是直接套用记忆中的数字。

---

## 五、模型 4：四层日志各回答一个问题

### 5.1 四层日志的分工

| 层 | 取用方式 | 回答什么问题 | 需要注意的限制 |
|---|---|---|---|
| 容器标准输出与标准错误 | `kubectl logs <pod> -c <容器>` | 应用自己是否报错 | 只能读到当前这个容器实例的输出 |
| 上一个被终止的容器 | `kubectl logs <pod> -c <容器> --previous`，可简写为 `-p` | 容器上一次为什么退出 | 只保留最近一次终止的日志，更早的实例已经被覆盖 |
| 节点上的 kubelet | 进入节点后执行 `journalctl -u kubelet -f`，或者查看 `/var/log/pods/` 目录 | 镜像为什么拉不下来、卷为什么挂不上 | 必须进入节点，属于 API 层之外的观察位置 |
| 节点上的内核 | 进入节点后执行 `dmesg -T` 或者 `journalctl -k` | 进程是否被内核终止、是否发生过 OOM | 输出量很大，需要配合关键字过滤 |
| 控制面组件 | `kubectl -n kube-system logs <组件名> -f` | 调度器与控制器为何没有动作 | 静态 Pod 形式部署的组件需要进入节点后才能取到完整日志 |

### 5.2 为什么必须使用 `--previous`

当容器处于 `CrashLoopBackOff` 时，容器正在被反复创建与终止。容器每次启动都会产生一个新的日志文件，节点上的文件名以该容器的重启序号命名，因此执行不带 `--previous` 的 `kubectl logs` 读到的是本次启动之后的输出，很可能为空或者只有启动时的一两行；容器退出之前打印的那段错误信息保存在上一次实例的日志文件里，只有加上 `--previous` 才能读到。

### 5.3 进入 kind 集群节点的方法

kind 集群的节点本身是一个容器，因此进入节点的方式是执行 `docker exec -it <节点容器名> bash`，节点容器名可以先用 `docker ps` 查出。进入节点之后可以执行 `crictl ps -a` 列出全部容器实例，用 `crictl logs <容器 ID>` 读取日志，用 `crictl inspect <容器 ID>` 读取容器详情，用 `crictl images` 列出节点本地已经存在的镜像。这三个命令是 API 层无法替代的，因为 kubelet 把一部分失败原因只写进了自己的日志与运行时的状态里。

---

## 六、故障到字段的对照表（主表）

> 使用方式：先查现象，再看应当读取的字段，最后执行取用命令。判断结论必须落到具体字段上，不允许只写「重启之后恢复正常」。

| 编号 | 现象 | 应当读取的字段 | 取用命令 | 判断结论落在哪里 |
|---|---|---|---|---|
| 1 | `STATUS` 列为 `Pending`，`READY` 列为 `0/1`，节点的 `NODE` 列显示 `<none>` | Pod 的 `phase`、`conditions` 中的 `PodScheduled`、事件中的 `FailedScheduling` | `kubectl describe po <名称>` | 事件消息 `0/3 nodes are available` 之后的分号列表给出了每一个节点不可用的原因 |
| 2 | `STATUS` 列为 `ImagePullBackOff`，`READY` 列为 `0/1` | `waiting.reason`、事件中 `Failed` 事件的 `message` | `kubectl describe po <名称>`，必要时进入节点执行 `crictl images` | `message` 字段区分了镜像不存在、标签错误、私有仓库认证失败这三类原因 |
| 3 | `STATUS` 列为 `CrashLoopBackOff`，`RESTARTS` 列持续增长 | `lastState.terminated.exitCode` 与 `lastState.terminated.reason` | `kubectl describe po <名称>` 与 `kubectl logs <名称> --previous` | 退出码 1 或 2 指向应用自身，137 配合 `reason` 为 `OOMKilled` 指向内存超限 |
| 4 | `STATUS` 列为 `CreateContainerConfigError` | `waiting.reason` 与事件中的具体消息 | `kubectl describe po <名称>` | 事件消息指明是哪一个 ConfigMap 或者 Secret 的哪一个键无法读取 |
| 5 | `STATUS` 列长时间停留在 `ContainerCreating` | 事件中的 `FailedMount` 或者 `FailedAttachVolume` | `kubectl describe po <名称>` | 卷准备阶段失败的证据只出现在事件里，容器状态此时仍然是 `waiting` |
| 6 | `STATUS` 列为 `Running`，而 `READY` 列为 `0/1` | `conditions` 中的 `Ready` 与 `ContainersReady` | `kubectl get po <名称> -o yaml` 或者 `kubectl describe po <名称>` | 就绪探针未通过，这与容器重启是两回事，`RESTARTS` 列此时保持为 0 |
| 7 | `STATUS` 列为 `OOMKilled`，或者 `LAST STATE` 段落显示 `Reason: OOMKilled` 且退出码为 137 | `lastState.terminated`，容器的 `resources.limits.memory`，节点的内核日志 | `kubectl describe po <名称>`，节点上执行 `dmesg -T \| tail` | 内核日志中出现 `Memory cgroup out of memory` 才完成闭环，否则还要考虑人为终止 |
| 8 | 容器的退出码为 143 | `lastState.terminated.exitCode` 与事件的时间线 | `kubectl describe po <名称>` 与 `kubectl get events --sort-by=.lastTimestamp` | 收到优雅终止信号，属于删除或者升级流程的一部分，不应当被判定为故障 |
| 9 | `STATUS` 列为 `Evicted`，`phase` 为 `Failed` | `status.reason`、`status.message`，以及节点的 `Conditions` | `kubectl describe po <名称>` 与 `kubectl describe node <名称>` | 节点压力触发 kubelet 驱逐，节点的 `Conditions` 中出现 `MemoryPressure` 或者 `DiskPressure` |
| 10 | `STATUS` 列长时间停留在 `Terminating` | `metadata.deletionTimestamp`、`metadata.finalizers`、`spec.terminationGracePeriodSeconds` | `kubectl get po <名称> -o yaml` | 结束流程被 `preStop` 钩子、finalizer 或者失联节点阻塞，三者从这三个字段区分 |
| 11 | `kubectl get endpoints <服务名称>` 的 `ENDPOINTS` 列显示 `<none>` | `Endpoints` 对象的地址列表与 Pod 的 `Ready` 条件 | `kubectl get endpoints <服务名称> -o yaml` 与 `kubectl get po --show-labels` | 三种原因分别是选择器不匹配任何 Pod、Pod 未通过就绪探针、Service 与 Pod 不在同一个命名空间 |
| 12 | `kubectl get pvc` 的 `STATUS` 列长时间停留在 `Pending` | PVC 的 `spec.storageClassName`、`spec.accessModes`、`spec.resources.requests.storage`，以及 `describe pvc` 输出中的事件 | `kubectl describe pvc <名称>` 与 `kubectl get pv` | 绑定要求容量、访问模式、存储类这三项同时匹配，事件消息会指出是哪一项不匹配 |
| 13 | `STATUS` 列为 `Init:0/1` 或者 `Init:CrashLoopBackOff` | `initContainerStatuses` | `kubectl describe po <名称>` 与 `kubectl logs <名称> -c <初始化容器名>` | 初始化容器没有完成之前，业务容器不会被创建，因此故障原因在初始化容器而不是业务容器 |

---

## 七、取证顺序（先取证，后修复）

排障最容易犯的错误是先修复、再回忆当时看见了什么。恢复动作一旦执行，`CrashLoopBackOff` 的计数、`LAST STATE` 段落中的退出码、以及事件内容都会被更新或者不再增长。因此固定按下面的顺序执行。

| 步骤 | 动作 | 具体命令 | 为什么必须在这一步 |
|---|---|---|---|
| 1 | 保存现场 | 把 `kubectl get po <名称> -o yaml`、`kubectl describe po <名称>`、`kubectl get events --sort-by=.lastTimestamp` 三份输出全部重定向到文件 | 事件保留时间有限，容器状态随重启持续变化，只有先存盘才能保证后续的比对有依据 |
| 2 | 建立时间线 | 把 `status.startTime`、`lastState.terminated.finishedAt`、事件的 `lastTimestamp`、应用日志的时间戳按先后排列 | 故障的原因通常出现在第一个不符合预期的动作之前，而不是在最后一次重启之前 |
| 3 | 定位段号 | 依据第四节与第三节的对照表判断故障落在五段链路中的第几段 | 先确定段号可以避免在错误的组件上查找原因 |
| 4 | 找出变化源 | 执行 `kubectl rollout history`、`kubectl diff`、比对镜像标签与 ConfigMap 的版本 | 绝大多数线上故障由变更引起，先回答「什么被改过」比先回答「可能是什么原因」更有效率 |
| 5 | 一次只改一个变量 | 修改之后立即重新采集同一组输出 | 一次修改多个变量会让因果关系无法判定，这与第 1 周的实验设计教训是同一条 |
| 6 | 修复之后写清判断依据 | 记录「判断依据落在哪一个字段」与「恢复动作是哪一条」 | 只有当判断依据可以被别人复核时，这次排障才构成可复用的经验 |

补充一条与基线有关的要求：没有健康状态下的基线，就无法判断当前取值是否异常。因此排障任务开始之前应当先采集一次正常运行状态下的 `describe` 与 `get po -o yaml` 输出，作为后续比对的对象。

---

## 八、命令分类表

### 8.1 API 层

| 场景 | 命令 | 说明 |
|---|---|---|
| 在全部命名空间中列出 Pod，确认异常范围 | `kubectl get po -A -o wide` | `-o wide` 增加节点与地址两列，`-A` 覆盖全部命名空间 |
| 只列出处于异常阶段的 Pod | `kubectl get po -A --field-selector status.phase!=Running` | 字段选择器由 API Server 执行，比取出全部结果之后再过滤更有效率 |
| 持续观察状态变化 | `kubectl get po -w` | 每次状态变化都会输出一行，适合观察重启与滚动升级过程 |
| 查看对象的完整字段与事件 | `kubectl describe po <名称>` | 输出末尾的 `Events` 段落是排障的第一现场 |
| 查看节点的资源余量与压力状态 | `kubectl describe node <名称>` | 同时给出 `Conditions`、`Allocated resources` 与 `Events` 三段信息 |
| 读取当前容器日志 | `kubectl logs <名称> [-c <容器>] [--tail=<行数>] [--since=<时长>]` | Pod 内只有一个容器时可以省略 `-c` |
| 读取上一个容器的日志 | `kubectl logs <名称> --previous` | 反复重启的容器必须使用这一个选项 |
| 在容器内执行命令 | `kubectl exec -it <名称> -- sh` | 容器必须处于运行状态，否则会返回容器未运行的错误 |
| 把本地端口转发到容器端口 | `kubectl port-forward <名称> <本地端口>:<容器端口>` | 用于绕开 Service 直接验证应用本身是否可用 |
| 在容器内启动临时排查容器 | `kubectl debug -it <名称> --image=<镜像> --target=<容器名>` | 适用于镜像中不含任何排查工具的场合 |
| 在节点上启动临时排查容器 | `kubectl debug node/<节点名> -it --image=<镜像>` | 适用于需要读取节点文件系统的场合 |
| 按时间顺序列出事件 | `kubectl get events --sort-by=.lastTimestamp -A` | 事件是独立对象，不会出现在 `kubectl get po -o yaml` 的输出里 |
| 按字段提取取值 | `kubectl get po <名称> -o jsonpath='{.status.containerStatuses[0].state}'` | 用于把四层状态中的某一层单独取出来比对 |
| 查询字段的含义与必填性 | `kubectl explain pod.spec.containers.livenessProbe` | 比翻书快，且与当前集群的 API 版本一致 |
| 在服务端校验清单 | `kubectl apply -f <文件> --dry-run=server` | 只在服务端做校验与准入，不会真正创建对象 |
| 查看版本历史与差异 | `kubectl rollout history deploy/<名称>` 与 `kubectl diff -f <文件>` | 用于回答「什么被改过」这一个问题 |

### 8.2 节点层

| 场景 | 命令 | 说明 |
|---|---|---|
| 读取 kubelet 日志 | 进入节点后执行 `journalctl -u kubelet -f` | 镜像拉取与卷挂载的详细失败原因只出现在这里 |
| 读取内核日志 | 进入节点后执行 `dmesg -T \| tail -50` | `-T` 把时间戳转换为可读形式，用于确认是否发生过 OOM |
| 列出节点上的全部容器实例 | 进入节点后执行 `crictl ps -a` | 包含已经退出的容器，与 `kubectl get po` 的口径不同 |
| 读取某个容器实例的日志 | 进入节点后执行 `crictl logs <容器 ID>` | 容器已经无法通过 API 取日志时的替代手段 |
| 读取容器详情 | 进入节点后执行 `crictl inspect <容器 ID>` | 给出运行时视角的配置与退出信息 |
| 列出节点本地镜像 | 进入节点后执行 `crictl images` | 用于确认镜像是否已经被拉取到节点 |
| 进入 kind 节点 | `docker exec -it <节点容器名> bash` | kind 的节点本身是一个容器，因此入口是 `docker exec` |
| 查看端口监听状态 | `ss -ltnp` | 在容器内执行可以确认应用真正监听的端口 |

### 8.3 容器内

| 场景 | 命令 | 说明 |
|---|---|---|
| 确认应用是否监听了预期的端口 | `netstat -tlnp` 或者 `ss -ltnp` | 监听地址是 `127.0.0.1` 还是 `0.0.0.0` 会直接影响可达性 |
| 验证服务自身是否可用 | `curl -v http://localhost:<端口>/<路径>` | `curl` 的退出码与报错前缀指明了失败发生在哪一段 |
| 检查配置文件是否已经写入 | `cat /etc/<路径>` 与 `ls -l /etc/<路径>` | 可以同时看出是普通文件还是符号链接，这一点决定配置是否支持热更新 |
| 检查环境变量是否已注入 | `env \| sort` | 环境变量是容器创建时刻的快照，修改 ConfigMap 之后不会自动更新 |

---

## 九、与第 3 周任务的对应关系

| 任务中要制造的故障 | 需要事先具备的知识 | 判断依据落到哪个字段 |
|---|---|---|
| 把 `nodeSelector` 写成集群中不存在的节点标签 | 第二段的职责、`FailedScheduling` 事件的消息结构 | `phase` 为 `Pending`、`PodScheduled` 条件为 `False`、事件中每一个节点不可用的原因 |
| 把镜像标签写成一个不存在的取值 | 第三段的职责、退避重试机制、kind 环境的镜像导入方式 | `waiting.reason` 为 `ImagePullBackOff`、事件中 `Failed` 事件的 `message` |
| 让容器主进程启动之后立即以非零退出码结束 | 第五段的职责、退出码与 `restartPolicy` 的交互 | `lastState.terminated.exitCode`、`RESTARTS` 列增长、`lastState.terminated.reason` |
| 让 Pod 模板引用一个不存在的 ConfigMap 名称 | 第四段的职责，以及按引用方式分成两条路径的差异 | 作为卷引用时出现 `FailedMount` 事件，作为环境变量引用时 `waiting.reason` 为 `CreateContainerConfigError` |
| 让内存占用超过 `limits` 触发内核终止 | 模型 3 的全部内容与 QoS 判定条件 | `terminated.reason` 为 `OOMKilled`、`terminated.exitCode` 为 137、节点内核日志中出现 `Memory cgroup out of memory` |
| 让 PersistentVolumeClaim 的访问模式与已有 PersistentVolume 不一致 | 绑定条件与事件写入位置 | `kubectl describe pvc` 输出中的 `STATUS` 为 `Pending` 与 `Events` 段落中的不匹配说明 |

---

## 十、待回填

> 每完成一次排障任务，把自己实测得到的新现象与新字段追加到这里。追加的内容必须写成「现象 → 字段依据 → 取用命令」三段，不允许只写命令。

| 现象 | 字段依据 | 取用命令 | 实测日期 |
|---|---|---|---|
| （示例）Pod 引用不存在的 Secret 键 | `waiting.reason` 为 `CreateContainerConfigError`，事件消息指明缺少的键名 | `kubectl describe po <名称>` | 待填 |
