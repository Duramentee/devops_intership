# Day 5 · 滚动升级与回滚（在不中断服务的前提下发布新版本）

> 目标：把一个正在运行的 Deployment 从 `webapp:v6` 升级到 `webapp:v7`，在升级过程中从一个固定的 Service 地址连续发起请求，
> 用「请求全部得到应答、版本标识逐步切换」这一组数据证明服务没有中断；随后执行回滚，观察控制器如何把旧版本的 ReplicaSet 重新扩容回来；
> 最后制造一次失败的升级，观察控制器如何保留可用的旧版本并停止推进。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 5 节、`docs/k8s_in_action/05-Deployment与StatefulSet.md`、
> 教材 9.3.2 节（p.417-422，升级 Deployment）、9.3.3 节（p.422-426，回滚 Deployment）、
> 9.3.4 节（p.426-429，控制滚动升级速率）、9.3.5 节（p.429-431，暂停滚动升级）、9.3.6 节（p.431-436，阻止出错版本的滚动升级）。
> 笔记落点：`notes/week2/day5.md`
> 起点资产：Deployment `webapp`（副本数量为 2、镜像 `webapp:v6`、带存活探针与就绪探针）、Service `webapp`（选择器为 `app=webapp`）、
> ConfigMap `webapp-config`、Secret `webapp-secret`、镜像 `webapp:v4` 至 `webapp:v6`。
> 今日新增资产：镜像 `webapp:v7`、两份 Deployment 清单、`outputs/` 目录中的实测记录。

---

## 一、基本概念与字段说明

> 阅读顺序建议：先读第 1 小节，确认今天要变更的对象到底是哪几个；再读第 2 小节，确认两种升级策略在替换 Pod 的顺序上有什么区别；然后读第 3 小节，逐字段确认每一处尖括号应当填写什么；最后读第 4 小节，建立「一次升级从提交命令到请求进入新版本」的整体印象。第 5 小节把今天用到的命令与它们实际修改的对象对应起来，第 6 小节给出术语速查表。

### 1.1 今天要变更的三层对象

从提交到运行一共存在四层对象：Deployment 管理 ReplicaSet，ReplicaSet 管理 Pod，Pod 内部运行容器。今天的所有操作只会改动最上面的两层，容器这一层由节点上的 kubelet 依据新的 Pod 模板重新创建。

| 对象 | 它是哪种 API 资源、属于哪个层级 | 谁创建它 | 它管理谁 | 它的生命周期与谁绑定 | 它不是什么 |
|---|---|---|---|---|---|
| Deployment | `apps/v1` 中的 Deployment，属于命名空间级资源，因此读写它时都受命名空间限制 | 由你执行 `kubectl apply` 创建，今天要修改的正是这个已经存在的对象 | 它管理 ReplicaSet，并且只能通过 ReplicaSet 间接管理 Pod | 与所在命名空间绑定，只有执行 `kubectl delete deploy` 才会消失，升级与回滚都不会删除它 | 它不是容器的运行载体，Pod 的创建与调度都不由它执行；它也不是版本历史的存放处，历史版本表现为被缩容到 0 的旧 ReplicaSet |
| ReplicaSet | `apps/v1` 中的 ReplicaSet，属于命名空间级资源 | 由控制平面上的 Deployment 控制器创建，因此人不应当手工创建它 | 它管理 Pod，通过持续对账把处于运行状态的 Pod 数量维持成期望数量 | 由 Deployment 通过 `metadata.ownerReferences` 字段持有，Deployment 被删除时它会被级联删除 | 它不是「一次升级的日志」：旧 ReplicaSet 之所以还能被回滚选中，是因为控制器把它缩容到 0 而不是删除它，而它自身保存着一份完整的 Pod 模板 |
| Pod | `v1` 中的 Pod，属于命名空间级资源 | 由 ReplicaSet 控制器创建，因此 Pod 的名称由「ReplicaSet 名称 + 五个随机字符」拼成 | 它管理容器，准确地说，是节点上的 kubelet 依据 Pod 的定义创建并监控容器 | 它是一次性对象：ReplicaSet 控制器负责维持数量，但已经被删除的 Pod 对象无法恢复 | 它不是升级的基本单位：升级的推进方式是新建 Pod 并删除旧 Pod，因此升级与回滚之后 Pod 的名称与 IP 地址都会发生变化 |

贯穿今天全部判断标准的一组概念是「就绪（ready）」与「可用（available）」，Deployment 在升级过程中把两者严格区分开来。

| 状态 | 判定条件 | 由谁判定 | 它的后果 |
|---|---|---|---|
| 就绪 | Pod 中的容器全部通过就绪探针，并且失败次数没有达到 `failureThreshold` 指定的上限 | 由 Pod 所在节点上的 kubelet 上报 | Pod 被加入 Service 的端点列表，因此它可以接收请求 |
| 可用 | Pod 进入就绪状态之后，又连续保持就绪达到 `spec.minReadySeconds` 指定的秒数 | 由控制平面上的 Deployment 控制器统计到 `status.availableReplicas` 字段中 | 该 Pod 被计入可用数量，Deployment 才会认为这一次升级又向前推进了一步 |

当清单中没有显式书写 `minReadySeconds` 时，它的取值是 0，此时「就绪」与「可用」在同一瞬间发生，一次就绪探针成功就会把一个 Pod 计入可用。教材 p.437 用一条提示专门说明这一点：只定义就绪探针而没有正确设置 `minReadySeconds` 时，一旦有一次就绪探针调用成功，控制器便会认为新的 Pod 已经处于可用状态。

### 1.2 两种升级策略的区别

| 对照项 | `RollingUpdate`（本次主线实验使用） | `Recreate`（本次对照实验使用） |
|---|---|---|
| 控制器替换 Pod 的顺序 | 渐进替换：先创建一部分新 Pod，等它们进入可用状态之后再删除相应数量的旧 Pod，如此反复直到新 ReplicaSet 的副本数量等于期望数量 | 一次性删除全部旧 Pod，等旧 Pod 全部消失之后再创建新 Pod |
| 升级期间是否存在不可用时间窗 | 不存在，只要 `maxUnavailable` 的取值小于期望副本数量，任何时刻都至少有一个旧 Pod 处于可用状态 | 存在，删除旧 Pod 与创建新 Pod 之间必然出现一段「可用 Pod 数量为 0」的时间，此时 Service 的端点列表为空 |
| `spec.strategy.rollingUpdate` 段落 | 必须书写，或者由 API Server 在持久化对象时补全 `maxSurge` 与 `maxUnavailable` 的默认取值 | 不允许书写，因为这两个字段只在 `RollingUpdate` 策略下才有意义，保留该段落会让 API Server 直接返回校验错误 |
| 教材依据 | 教材 p.414 说明这是 Deployment 默认使用的升级策略，并且说明升级期间 Pod 数量可以在期望副本数量的一定区间内浮动 | 教材 p.414 说明该策略会一次性删除所有旧版本的 Pod，然后创建新的 Pod，因此会导致应用程序出现短暂的不可用 |

### 1.3 字段清单：每一处尖括号填什么

| 字段（YAML 路径） | 是否必须书写 | 含义 | 默认取值与由谁补全 | 今天填什么 |
|---|---|---|---|---|
| `metadata.name` | 必须书写 | 指明这份清单要就地更新哪一个已经存在的 Deployment，而不是创建一个新的对象 | 不由服务端补全 | 写 `webapp`，与 Day 1 至 Day 4 创建的对象同名；如果写错，集群中会出现第二个 Deployment，而不是更新原来的那一个 |
| `spec.replicas` | 可以省略 | 期望副本数量，也就是 ReplicaSet 需要维持的 Pod 个数，它是控制器对账的目标值而不是当前值 | 省略时默认值为 1 | 写 2，与 Day 4 保持一致，这样连续访问的输出中才会同时出现两个 Pod 的响应 |
| `spec.strategy.type` | 可以省略 | 指定控制器使用哪一种策略来替换 Pod | 省略时默认值为 `RollingUpdate` | 主线清单写 `RollingUpdate`，对照清单写 `Recreate` |
| `spec.strategy.rollingUpdate.maxSurge` | 在 `RollingUpdate` 策略下可以省略 | 在期望副本数量之外，最多允许额外创建多少个 Pod，它决定升级期间 Pod 总数的上限 | 省略时默认值为 25%，由 API Server 在持久化对象时补全；取整数时表示绝对个数，取百分数时由控制平面向上取整 | 写 1：期望副本数量为 2，因此升级期间 Pod 总数最多为 3 |
| `spec.strategy.rollingUpdate.maxUnavailable` | 在 `RollingUpdate` 策略下可以省略 | 在升级期间最多允许多少个 Pod 处于不可用状态，它决定可用 Pod 数量的下限 | 省略时默认值为 25%，由 API Server 在持久化对象时补全；取百分数时由控制平面向下取整，并且它与 `maxSurge` 不允许同时为 0 | 写 0：表示升级期间必须始终保持 2 个 Pod 可用，因此控制器必须先创建新 Pod 才能删除旧 Pod |
| `spec.minReadySeconds` | 可以省略 | 新 Pod 进入就绪状态之后还必须连续成功运行多少秒，才被计入可用 | 省略时默认值为 0 | 第一次实验按骨架第 6 条的要求留空不写，其余步骤也保持留空，这样升级的推进速度只由两个速率参数决定。选做：把它改为大于就绪探针周期（5 秒）的取值并重复一次升级，可以观察到升级耗时变长 |
| `spec.revisionHistoryLimit` | 可以省略 | Deployment 最多保留多少个旧 ReplicaSet 作为历史版本，也就是回滚时可以选到的目标数量上限 | 教材 p.426 按照写作时的 API 版本写明默认取值是 2，并在同一页说明 apps/v1beta2 起默认取值改为 10；本集群的 Deployment 属于 apps/v1，因此实际默认取值是 10（补充：这一条以 `kubectl get deploy webapp -o jsonpath='{.spec.revisionHistoryLimit}'` 的实测输出为准）。无论默认取值是多少，超出限制的更早 ReplicaSet 都会被删除 | 必须写成不小于 3 的取值（本次写成 5），因为今天要依次经历升级、回滚与失败的升级三步，取值过小会让第一步产生的 ReplicaSet 被清理掉，回滚时无法选中它 |
| `spec.progressDeadlineSeconds` | 可以省略 | 升级过程被卡住多少秒之后，Deployment 的 `Progressing` 条件被写成 `False` | 省略时默认值为 600 秒，也就是 10 分钟，教材 p.437 写明这一条 | 写一个便于观察的小取值（例如 30）。补充说明：`kubectl rollout status` 会参考这个字段的取值决定是否继续等待，因此把取值改小可以让「升级卡住」这件事更快被观察到；这个字段只影响状态报告，控制器不会因为超过它而自动回滚 |
| `spec.paused` | 只在选做步骤中使用 | 把 Deployment 置于暂停状态，此时控制器不推进升级，但仍然会处理其他字段的变化 | 省略时默认值为 `false` | 选做步骤 17 执行 `kubectl rollout pause deploy/webapp` 时由该命令把取值改为 `true`，选做步骤 18 执行 `kubectl rollout resume deploy/webapp` 时改回 `false` |
| `spec.selector.matchLabels` | 必须书写 | Deployment 用它筛选出自己管理的 Pod，它必须与 Pod 模板中的标签保持一致 | 不由服务端补全，并且对象创建之后不允许再修改 | 写 `app: webapp`，与 Day 1 至 Day 4 的取值相同 |
| `spec.template` | 必须书写 | Pod 模板，也就是控制器创建 Pod 时使用的样板。模板的内容一旦发生变化，控制器就计算出一个新的哈希值，并据此创建新的 ReplicaSet | 不由服务端补全 | 与 Day 4 的清单保持一致，只在骨架要求的那一步把 `image` 的取值改动，否则观察到的现象无法归因到滚动升级这一件事上 |
| `status` 段落中的 `observedGeneration`、`replicas`、`updatedReplicas`、`readyReplicas`、`availableReplicas`、`unavailableReplicas`、`conditions` | 一律不书写 | 记录控制器对账之后得到的实际状态，例如有多少个 Pod 已经更新、有多少个 Pod 处于可用状态 | 全部由 Deployment 控制器写入 | 不写；它们只在 `kubectl get deploy webapp -o yaml` 或 `kubectl describe deploy webapp` 的输出中读取，步骤 7 正是读取它们来说明「升级过程中三个统计值并不相等」 |
| `metadata.generation` | 一律不书写 | API Server 维护的递增计数，用来记录这个对象的 `spec` 被修改过多少次 | 由 API Server 写入（补充） | 不写；步骤 2 与步骤 4 分别读取它的取值并与 `kubectl rollout history` 的输出对照。需要注意：哪些字段的变化会让它递增，应当以步骤 4 的实测输出为准，不要把记忆当作结论 |
| `metadata.annotations` 中的 `deployment.kubernetes.io/revision` | 一律不书写 | 记录当前 Pod 模板对应的 revision 编号，`kubectl rollout history` 显示的编号就来自这个注解 | 由 Deployment 控制器写入（补充） | 不写；步骤 11 用它说明「执行回滚本身也是一次模板修改，因此会占用一个新的编号」 |
| `metadata.ownerReferences`（写在 ReplicaSet 与 Pod 上） | 一律不书写 | 指明父对象，它既是控制器识别「这个对象归我管」的依据，也是级联删除与垃圾回收的依据 | 由创建它的控制器写入（补充） | 不写；可以用 `kubectl get rs -o jsonpath='{.items[*].metadata.ownerReferences[*].name}'` 查看每个 ReplicaSet 的父对象名称 |

手写清单时应当省略的字段可以归纳为四类：第一类是 `status` 整个段落；第二类是 `metadata` 中的 `creationTimestamp`、`uid`、`resourceVersion`、`generation` 与 `managedFields`，它们都由服务端写入；第三类是取值等于服务端默认值的字段，省略与显式书写在语义上等价，区别只在于记录是否明确，例如省略整个 `spec.strategy` 段落与显式写 `type: RollingUpdate` 的结果相同；第四类是由控制器写入的注解与 `ownerReferences`。反过来说，有三类字段不能省略：`metadata.name`、`spec.selector.matchLabels` 与 `spec.template`，缺少其中任何一个字段，对象都无法创建成功。

与镜像拉取有关的还有一个位于容器段落中的字段 `spec.template.spec.containers[].imagePullPolicy`，它决定节点上的 kubelet 是否会去镜像仓库拉取镜像。当镜像标签不是 `latest` 时它的默认取值是 `IfNotPresent`，因此只要节点镜像库中已经存在同名同标签的镜像，kubelet 就直接使用本地镜像、不发起网络请求；当镜像标签是 `latest` 时它的默认取值是 `Always`，此时 kubelet 每次创建容器都会尝试拉取镜像。本环境中的节点无法访问镜像仓库，因此「先在宿主机准备好镜像、把它导入节点，并且在清单中写明确切的标签」是这里的唯一可行做法。

### 1.4 全流程工作链路：从执行 apply 到请求进入新版本

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 | 依据 |
|---|---|---|---|---|---|---|
| 1 | 你与 `kubectl` | `deploy.rollout.yaml` 的内容 | 执行 `kubectl apply`，客户端把清单转换成 HTTP 请求并提交给 API Server | 请求体就是这份清单的内容 | `03-dry-run.txt`；需要注意加上 `--dry-run=client` 时只做本地校验，不会发送任何请求，因此输出中不会出现默认值与 `status` 段落 | 补充 |
| 2 | API Server | 来自客户端的 HTTP 请求 | 校验字段与取值，例如在 `Recreate` 策略下出现 `rollingUpdate` 段落会被直接拒绝，然后把对象写入 etcd | etcd 中保存的对象被补全默认值，`metadata.generation` 递增 | `04-apply-strategy-only.txt`；`kubectl get deploy webapp -o yaml` 中可以看到被补全的字段 | 补充 |
| 3 | Deployment 控制器（运行在 kube-controller-manager 中） | 监听（watch）到的 Deployment 变化事件 | 依据 `spec.template` 计算出一个哈希值，然后检查以「Deployment 名称 + 哈希值」命名的 ReplicaSet 是否已经存在 | 出现一个新的 ReplicaSet，它的副本数量初始为 0，它的 `metadata.ownerReferences` 指向 Deployment | `kubectl get rs -o wide`；步骤 7 的 `07-rs-watch.txt` 连续输出 | 教材 p.417 至 p.421 |
| 4 | Deployment 控制器 | `maxSurge`、`maxUnavailable`、`minReadySeconds` 三个字段的取值，以及新旧两个 ReplicaSet 的实际状态 | 反复调整两个 ReplicaSet 的副本数量：先按上限扩大新 ReplicaSet，等新 Pod 进入可用状态之后再按下限缩小旧 ReplicaSet | 新 ReplicaSet 的 `DESIRED` 一列由 0 增长到期望值，旧 ReplicaSet 的 `DESIRED` 一列由期望值减少到 0，`status.updatedReplicas` 与 `status.availableReplicas` 随之变化 | `kubectl get rs -w -o wide`；`kubectl get deploy webapp -o yaml` 的 `status` 段落 | 教材 p.426 至 p.429 |
| 5 | ReplicaSet 控制器 | 被修改的 ReplicaSet 的 `spec.replicas` | 创建缺少的 Pod 对象，并删除多余的 Pod 对象 | 出现新的 Pod 对象，名称形如 `webapp-<新哈希值>-<五个随机字符>`；旧 Pod 进入 `Terminating` 状态 | `kubectl get po -o wide`；步骤 7 的 `07-po-midflight.txt` | 教材 p.417 至 p.421 |
| 6 | kube-scheduler | 新创建的、`spec.nodeName` 为空的 Pod | 依据节点资源与调度约束挑选一个节点，并把挑选结果写入 Pod 的 `spec.nodeName` 字段 | Pod 的 `STATUS` 一列由 `Pending` 变为 `ContainerCreating` | `kubectl get po -o wide` 的 `NODE` 一列 | 补充 |
| 7 | 节点上的 kubelet 与容器运行时 | 被调度到本节点的 Pod 定义 | 从节点内部的镜像库拉取 `webapp:v7`，创建容器，并按 `periodSeconds` 指定的周期执行就绪探针 | 容器开始运行；就绪探针成功之后 Pod 的 `READY` 一列变为 `1/1` | `kubectl get po`；`kubectl describe po <名称>` 输出末尾的 Events 段落 | 补充 |
| 8 | 端点控制器（运行在 kube-controller-manager 中） | Pod 的就绪状态与 Service 的选择器 | 把处于就绪状态的 Pod 的地址写入与 Service 同名的 EndpointSlice 对象，旧版本集群中写的是 Endpoints 对象 | 端点列表中增加新 Pod 的地址，随着旧 Pod 被删除，旧地址被移除 | `kubectl get endpoints webapp -o wide`；集群版本较新时执行 `kubectl get endpointslices -o wide` | 教材 p.435（就绪状态决定 Pod 是否进入端点列表） |
| 9 | 每个节点上的 kube-proxy | EndpointSlice 对象的变化 | 更新本节点上的转发规则，实现方式是 iptables 或 IPVS | 新 Pod 开始接收来自 Service 的请求。因为 Service 的地址在这个阶段完全不变，所以连续访问的输出中先出现 `version=v6` 的行，随后出现 `version=v7` 的行 | `05-continuous-access.txt` 中 `grep -c 'version=v7'` 的计数结果 | 补充 |
| 10 | Deployment 控制器 | 升级全部完成之后的实际状态 | 更新 Deployment 的 `status` 段落 | `status.availableReplicas` 等于 `spec.replicas`，`Progressing` 条件被写成 `NewReplicaSetAvailable`，旧 ReplicaSet 的副本数量保持为 0 但不被删除 | `kubectl rollout status deploy/webapp` 的最终输出；`kubectl get rs -o wide` | 补充 |
| 11 | 你与 Deployment 控制器（步骤 9 执行回滚时） | 执行 `kubectl rollout undo deploy/webapp` | 控制器把目标历史 ReplicaSet 的 Pod 模板写回 Deployment 的 `spec.template` 字段，随后重复第 3 步到第 10 步 | 目标历史 ReplicaSet 的副本数量重新扩大，当前版本的 ReplicaSet 被缩容到 0；`metadata.generation` 再次递增，版本历史中新增一条记录 | `09-undo.txt`、`09-rollout-status-after-undo.txt`、`11-history-after-undo.txt` | 教材 p.422 至 p.425 |
| 12 | Deployment 控制器（步骤 13 制造失败的升级时） | 新 Pod 一直无法进入就绪状态这一事实 | 在 `maxUnavailable` 的约束之下停止删除旧 Pod；等待时间超过 `progressDeadlineSeconds` 之后把 `Progressing` 条件写成 `False` | 旧 Pod 保持 `1/1 Running`，新 Pod 停留在 `ImagePullBackOff`，`status.unavailableReplicas` 不为 0 | `13-failed-upgrade-status.txt`、`13-failed-upgrade-po.txt`、`13-failed-upgrade-describe.txt` | 教材 p.431 至 p.437 |

### 1.5 命令与它们实际修改的对象

| 命令 | 它实际修改的对象 | 是否创建新的 ReplicaSet | 说明 |
|---|---|---|---|
| `kubectl apply -f deploy.rollout.yaml` | Deployment 的 `spec` 段落 | 当 `spec.template` 发生变化时创建，只修改 `replicas` 或 `strategy` 时不会创建 | 今天要用两次 apply 把「修改策略」与「修改镜像」分开，因此这一个命令会给出两种不同的结果 |
| `kubectl set image deploy/webapp webapp=webapp:v7` | `spec.template.spec.containers[0].image` | 创建 | 与手工修改 YAML 之后再执行 apply 等价；步骤 13 用它把镜像指向一个不存在的标签 |
| `kubectl scale deploy/webapp --replicas=3` | `spec.replicas` | 不创建 | 只改变副本数量，不替换任何 Pod |
| `kubectl rollout status deploy/webapp` | 只读取状态，不修改任何对象 | 不创建 | 默认等待时间是 600 秒，因此步骤 13 显式加上 `--timeout=30s` |
| `kubectl rollout history deploy/webapp` | 只读取 Deployment 与历史 ReplicaSet | 不创建 | 显示的编号来自 `deployment.kubernetes.io/revision` 注解 |
| `kubectl rollout undo deploy/webapp` | Deployment 的 `spec.template` 段落 | 创建 | 回滚是一次新的模板修改，因此它会占用一个新的 revision 编号，而不是把原编号退回去 |
| `kubectl rollout undo deploy/webapp --to-revision=N` | Deployment 的 `spec.template` 段落 | 创建 | 回滚到指定编号的历史版本，`N` 的取值从 `rollout history` 的输出中读取 |
| `kubectl rollout pause` 与 `kubectl rollout resume` | `spec.paused` 字段 | 不创建 | 暂停期间控制器不推进升级，此时执行 `kubectl rollout undo` 不会生效 |
| `kubectl rollout restart deploy/webapp` | `spec.template.metadata.annotations` 中的 `kubectl.kubernetes.io/restartedAt` 注解 | 创建 | 用「修改模板」的方式强制重建全部 Pod，因此它同样会产生一个新的 revision |
| `kubectl annotate deploy/webapp kubernetes.io/change-cause="升级到 v7"` | `metadata.annotations` | 不创建 | 它是已经废弃的 `--record` 参数的替代做法，作用是在 `rollout history` 的 `CHANGE-CAUSE` 一列留下这次变更的原因 |

### 1.6 术语速查

| 术语 | 含义 |
|---|---|
| Pod 模板 | Deployment 的 `spec.template` 字段，它是控制器创建 Pod 时使用的样板；模板一旦变化，控制器就认为出现了一个新版本 |
| revision | 一次 Pod 模板修改的编号，由 Deployment 控制器写入注解与旧 ReplicaSet；升级、回滚与重启都会占用一个新的编号 |
| rollout | 一次把新的 Pod 模板铺开到全部副本的过程，它既包括升级，也包括回滚 |
| 期望副本数量 | `spec.replicas` 的取值，它是控制器对账的目标值，而不是当前实际运行的 Pod 数量 |
| Pod 总数上限 | 在 `RollingUpdate` 策略下等于期望副本数量加上 `maxSurge` 的取值 |
| 可用 Pod 数量下限 | 在 `RollingUpdate` 策略下等于期望副本数量减去 `maxUnavailable` 的取值 |
| 不可用时间窗 | 在任意时刻都取不到响应的那一段时间；本次实验中它以连续访问输出里 `http=000` 的行数来度量 |
| 就绪与可用 | 见 1.1 节的对照表：就绪决定 Pod 是否能够接收请求，可用决定 Deployment 能否继续推进升级 |

---

## 二、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `go-webapp/main.go` | 应用源码。与 v6 相比新增了一个 `/version` 端点，并在 `/state` 输出的末尾增加了一行版本标识；Day 3 的配置来源报告与 Day 4 的三个探针端点保持原样 | 已提供 |
| `go-webapp/go.mod` | 模块声明，与 Day 4 完全相同 | 已提供 |
| `go-webapp/Dockerfile` | 多阶段构建、非 root 用户 uid 10001，与 Day 4 完全相同 | 已提供 |
| `deploy.rollout.skeleton.yaml` | 滚动升级清单的填空骨架，`strategy`、`minReadySeconds`、`revisionHistoryLimit`、`progressDeadlineSeconds` 四个字段以及镜像标签留空 | 已提供 |
| `deploy.rollout.yaml` | 滚动升级与回滚实验实际使用的 Deployment 清单 | 你自己编写，从骨架另存 |
| `deploy.recreate.skeleton.yaml` | `Recreate` 策略对照实验的填空骨架 | 已提供 |
| `deploy.recreate.yaml` | `Recreate` 策略对照实验实际使用的 Deployment 清单 | 你自己编写，从骨架另存 |
| `outputs/` | 命令的原始输出记录 | 你自己记录 |

---

## 三、动手之前必须先记录的基线

| 项目 | 命令 | 输出文件 | 为什么要先记录 |
|---|---|---|---|
| 节点容器与节点状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes -o wide` | `outputs/00-baseline-cluster.txt` | 节点容器被重新启动时，节点上的全部容器都会随之重建，Pod 的名称与地址都会变化。今天的实验以「升级前后 ReplicaSet 的副本数量」和「连续请求是否全部得到应答」为依据，节点状态必须在这一刻固定下来 |
| 现有的 Deployment、ReplicaSet、Pod | `kubectl get deploy,rs,po -o wide --show-labels` | `outputs/00-baseline-workload.txt` | 升级之前必须知道已经存在几个 ReplicaSet、它们的名称分别是什么。没有这份基线，升级之后看到一个陌生的 ReplicaSet 名称就无法判断它是本次升级产生的还是之前遗留的 |
| Deployment 的 `strategy` 字段默认取值 | `kubectl get deploy webapp -o yaml`，或者执行 `kubectl get deploy webapp -o jsonpath='{.spec.strategy}{"\n"}'` | `outputs/00-baseline-strategy.txt` | 计划文件要求记录两个速率参数的默认取值。这份取值是后面「显式写入与默认取值是否产生差异」这一判断的对照基线 |
| 当前的版本历史 | `kubectl rollout history deploy/webapp` 与 `kubectl get deploy webapp -o jsonpath='{.metadata.generation}{"\n"}'` | `outputs/00-baseline-history.txt` | 回滚的可选目标由 ReplicaSet 决定，而 `generation` 的取值记录的是 Pod 模板被修改过多少次。两份取值放在一起，才能说明「回滚目标」与「模板修改次数」之间的关系 |
| 镜像标签 | `docker images webapp --format '{{.Repository}}:{{.Tag}} {{.Size}}'` | `outputs/00-baseline-images.txt` | 记录构建之前的标签集合，用于确认新构建出来的镜像确实使用了 `v7` 这个标签，并且节点内部的镜像库中也存在它 |
| 节点镜像库中的客户端镜像 | 执行 `docker exec kind-control-plane crictl images`，然后在输出中查找名称包含 `curl` 的行 | `outputs/00-baseline-client-image.txt` | 节点内部的容器运行时只能使用节点自己镜像库中的镜像，而本环境中的节点无法访问镜像仓库：节点内部的容器运行时把镜像仓库请求交给代理 `127.0.0.1:9674`，该地址在节点内部没有服务监听，因此连接会被拒绝。必须先确认 `curlimages/curl:8.10.1` 已经在节点镜像库中，否则步骤 5 创建的客户端 Pod 会一直停留在 `ContainerCreating`，最终返回 `error: timed out waiting for the condition` |
| Service 与端点列表 | `kubectl get svc webapp -o wide` 与 `kubectl get endpoints webapp -o wide` | `outputs/00-baseline-endpoints.txt` | 今天的连续访问实验全程访问 Service 的地址，因此这个地址在整个实验期间必须保持不变。端点列表的取值用于说明「地址不变、后端的 Pod 在替换」这件事 |

---

## 四、步骤与命令

> 下面每一步都写成「执行什么 → 输出到哪里 → 观察什么」的形式。属于补充而非书本原文的步骤在备注列中标出。
>
> 记录规则一共三条。第一条：本表中列出的每一个输出文件都放在本目录下的 `outputs/` 目录中，文件名前缀编号与步骤编号一致。
> 第二条：一次性完成的命令用重定向保存，例如执行 `kubectl get rs -o wide > outputs/06-rs-after-upgrade.txt 2>&1`，把标准输出与标准错误一起写入文件。
> 第三条：需要持续观察的命令分成两类。第一类是 `kubectl get ... -w` 这类由客户端持续打印输出的命令，它无法用重定向完整保存，应当把观察到的关键片段粘贴进对应的文件，并在文件开头写一行说明这段输出对应的起止时刻；第二类是把输出写在容器内部的命令，例如步骤 5 的连续访问客户端，它的输出全部保存在容器的日志中，因此可以在实验结束时用 `kubectl logs <Pod 名称> > <输出文件>` 一次性导出完整记录。

| 步骤 | 命令 | 输出文件（位于 `outputs/`） | 观察什么 | 备注 |
|---|---|---|---|---|
| 1. 构建 v7 并导入节点 | 在 `go-webapp/` 目录中执行 `docker build -t webapp:v7 .`，然后执行 `kind load docker-image webapp:v7` | `01-build-and-load.txt` | 构建输出的最后一行给出镜像标识；导入命令输出中包含 `Image: "webapp:v7" with ID ... loaded` | 补充：教材使用 Docker Hub 上的现成镜像，本次从本地构建。与 Day 4 的差别只有 `/version` 一个端点，因此两次实验的现象不会互相影响 |
| 2. 记录基线 | 按第三节的表格逐项执行 | `00-*.txt` | 七份基线文件全部生成，其中 `00-baseline-strategy.txt` 中可以看到 `maxSurge` 与 `maxUnavailable` 的默认取值 | 补充：第 1 周的教训是知识空白类错误最多，因此观察类实验一律先记录基线 |
| 3. 填写骨架并做客户端校验 | 从 `deploy.rollout.skeleton.yaml` 另存为 `deploy.rollout.yaml` 并填写全部尖括号，其中 `image` 先保持 `webapp:v6`，然后执行 `kubectl apply --dry-run=client -f deploy.rollout.yaml` | `03-dry-run.txt` | 校验命令不报错；`strategy` 段落的结构符合预期；客户端校验不会补全默认值，因此输出中的取值就是你在文件里写的取值 | |
| 4. 第一次 apply：只修改策略字段 | `kubectl apply -f deploy.rollout.yaml`，然后执行 `kubectl get rs -o wide`、`kubectl get deploy webapp -o yaml`、`kubectl rollout history deploy/webapp` | `04-apply-strategy-only.txt`、`04-rs-after-strategy.txt`、`04-history-after-strategy.txt` | ReplicaSet 的数量与名称是否发生变化；`metadata.generation` 是否增加；版本历史中是否新增一条记录 | 补充：这一步把「策略字段」与「Pod 模板」拆成两次变更，因此它可以回答「修改哪些字段会触发滚动升级」这个问题。教材 p.413 至 p.418 只描述了修改 Pod 模板这一条路径 |
| 5. 启动连续访问 | 执行 `kubectl run curl-loop --image=curlimages/curl:8.10.1 --restart=Never --pod-running-timeout=3m -- sh -c 'while :; do printf "%s " "$(date +%H:%M:%S)"; curl -s -o /tmp/b -w "http=%{http_code} " --max-time 2 http://webapp:8080/version; echo "body=$(cat /tmp/b 2>/dev/null)"; sleep 0.2; done'`，然后执行 `kubectl get po curl-loop -o wide` 确认它进入 `1/1 Running` | 本步骤不写输出文件：循环的输出全部保存在容器日志中，等到步骤 8 再一次性导出 | 每一条输出都包含时刻、HTTP 状态码与响应正文。如果当前 Deployment 使用的镜像是 `webapp:v7`，这些行的状态码是 200 并且正文是 `body=version=v7`；如果当前使用的镜像是 `webapp:v6`，这些行的状态码同样是 200，但正文变成了配置来源报告，第一行形如 `body=env  GREETING    = ...`。原因是 v6 没有 `/version` 这个端点，该请求落到了根路径处理器 `/`，因此判别响应来自哪个版本只能看正文，不能看状态码 | 补充：命令形状做过一次修正，去掉了 `-it` 与 `--rm`，并把 `--pod-running-timeout` 放宽到 3 分钟。`-it` 会让 `kubectl` 在附加之前先等到 Pod 进入 `Running`，默认只等 60 秒；`--rm` 会在命令结束时删除 Pod，因此等待超时之后 Pod、Events 与容器日志会一起消失，失败现场无法复现。`http=000` 表示连接未能建立，它是「服务中断」的判定依据 |
| 6. 第二次 apply：把镜像改为 v7 | 把 `deploy.rollout.yaml` 中的 `image` 改为 `webapp:v7`，然后执行 `kubectl apply -f deploy.rollout.yaml`，紧接着执行 `kubectl rollout status deploy/webapp` | `06-apply-v7.txt`、`06-rollout-status.txt` | 升级状态依次出现「等待新的副本被创建」「等待旧副本被终止」「成功完成」三类输出 | 教材 p.417 至 p.419 给出了同样的观察顺序 |
| 7. 采集升级过程中的中间状态 | 在这次升级开始之前，先在另一个终端窗口中执行 `kubectl get rs -w -o wide`，升级结束之后再终止它；另外在升级过程中执行一次 `kubectl get po -o wide` 与 `kubectl get deploy webapp -o yaml` | `07-rs-watch.txt`、`07-po-midflight.txt`、`07-deploy-midflight.txt` | 新 ReplicaSet 的 `DESIRED` 一列由 0 逐步增加到 2；旧 ReplicaSet 的 `DESIRED` 一列由 2 逐步减少到 0；同一时刻两个 ReplicaSet 的副本数量之和最多等于 `replicas` 加上 `maxSurge`；`kubectl get deploy webapp -o yaml` 的 `status` 段落中 `updatedReplicas`、`replicas`、`availableReplicas` 三个字段在过程中并不相等 | 补充：教材 p.426 至 p.429 用插图描述这个过程。本次用 `kubectl get rs -w` 的连续输出替代定时采样，因此不需要执行等待命令就能采到中间状态 |
| 8. 导出连续访问的记录并统计结果 | 依次执行 `kubectl logs curl-loop > outputs/05-continuous-access.txt`、`grep -c 'http=000' outputs/05-continuous-access.txt`、`grep -c 'body=version=v7' outputs/05-continuous-access.txt` 与 `grep -c 'body=env' outputs/05-continuous-access.txt`；统计完成之后执行 `kubectl delete po curl-loop` | `05-continuous-access.txt` | 一是 `body=version=v7` 的行数，它说明有多少个请求由新版本应答；二是 `body=env` 的行数，它说明有多少个请求由旧版本 `webapp:v6` 应答；三是 `http=000` 的行数，它说明有多少个请求未能建立连接。三者的行数之和应当等于含 `http=` 的总行数 | 补充：实测结果表明「`http=000` 的行数为 0」这个判断标准过于理想。本次 12 个窗口中有 9 个窗口出现了失败：每次滚动替换出现 2 到 4 次失败（占该窗口请求数的 4% 到 7%），`Recreate` 策略下出现 13 次失败（占 5.6%），连稳定运行窗口内也会零星出现 1 次。因此正确的判断标准是「失败集中在 Pod 被终止的那一到两秒内，并且占比很低」，而不是「一次也没有」。失败的机制与排查方式见 `07b-failure-attribution.txt` |
| 9. 查看版本历史并执行回滚 | 依次执行 `kubectl rollout history deploy/webapp`、`kubectl rollout undo deploy/webapp`、`kubectl rollout status deploy/webapp` | `09-history-before-undo.txt`、`09-undo.txt`、`09-rollout-status-after-undo.txt` | 回滚命令的输出中包含 `deployment.apps/webapp rolled back`；执行完成之后 `kubectl get rs -o wide` 中原来已经缩容到 0 的那个 ReplicaSet 的 `DESIRED` 一列重新变成 2 | 教材 p.422 至 p.425 给出了 `kubectl rollout undo` 的用法与回滚结果 |
| 10. 确认回滚之后的镜像与版本历史 | 执行 `kubectl describe deploy webapp` 并查看 `Image` 一行，再执行 `kubectl get po -o wide` 与 `kubectl exec deploy/webapp -- wget -q -O- http://localhost:8080/version` | `10-describe-after-undo.txt`、`10-version-after-undo.txt` | `Image` 一行回到 `webapp:v6`；`/version` 端点返回的状态码是 404，因为 v6 没有这个端点，这一点反过来证明了回滚已经生效；Pod 的名称与地址与升级之前不同，因为回滚过程中新建了 Pod | 补充：回滚的目标是「恢复 Pod 模板」，而不是「把原来的 Pod 找回来」。教材 p.423 说明每个 ReplicaSet 保存了一个完整的版本，因此回滚的实现方式是让旧 ReplicaSet 重新扩容 |
| 11. 观察 revision 编号的变化 | 执行 `kubectl rollout history deploy/webapp` | `11-history-after-undo.txt` | 历史列表中新增了一条记录，而不是把原来那条记录的编号退回 | 补充：`kubectl rollout undo` 本身也是一次 Pod 模板修改，因此它会占用一个新的 revision 编号 |
| 12. 参数组合实验 | 依次修改 `maxSurge` 与 `maxUnavailable` 的取值并执行 `kubectl apply`，每次升级在另一个终端窗口中执行 `kubectl get po -w` | `12-surge-unavailable-combos.txt` | 每一种组合下 Pod 总数的最大值与最小值。三种推荐组合分别是 `maxSurge=1 maxUnavailable=0`、`maxSurge=0 maxUnavailable=1` 与 `maxSurge=100% maxUnavailable=0` | 补充：教材 p.426 至 p.429 用 3 个副本的例子解释这两个参数。本次的副本数量是 2，因此百分数取值的取整方向可以直接通过 Pod 总数观察到 |
| 13. 制造一次失败的升级 | 执行 `kubectl set image deploy/webapp webapp=webapp:does-not-exist`，然后执行 `kubectl rollout status deploy/webapp --timeout=30s`，再执行 `kubectl get po -o wide` 与 `kubectl describe po <新 Pod 的名称>` | `13-failed-upgrade-status.txt`、`13-failed-upgrade-po.txt`、`13-failed-upgrade-describe.txt` | `kubectl rollout status` 在等待结束之后以非零状态返回并给出 `error: timed out waiting for the condition`，如果 `progressDeadlineSeconds` 先到期，则给出 `error: deployment "webapp" exceeded its progress deadline`，两者都表示等待结束而升级没有完成；新 Pod 的 `STATUS` 一列为 `ErrImagePull` 或 `ImagePullBackOff`；旧版本的 Pod 仍然处于 `1/1 Running`，因此服务本身仍然可用 | 教材 p.431 至 p.436 描述了「出错版本的滚动升级被阻止」这一行为 |
| 14. 从失败的升级中恢复 | 执行 `kubectl rollout undo deploy/webapp`，然后执行 `kubectl rollout status deploy/webapp`、`kubectl get po -o wide` 与 `kubectl describe deploy webapp` | `14-recover.txt` | 升级重新完成；全部 Pod 回到 `1/1 Running`；`Image` 一行回到可用的标签 | 教材 p.424 与 p.436 |
| 15. 对照实验：`Recreate` 策略 | 从 `deploy.recreate.skeleton.yaml` 另存为 `deploy.recreate.yaml` 并填写全部尖括号；然后用步骤 5 的同一条命令启动一个新的 `curl-loop`（步骤 8 已经把上一个删除，因此名称不会冲突），确认它进入 `1/1 Running` 之后再执行 `kubectl apply -f deploy.recreate.yaml`；观察结束之后执行 `kubectl logs curl-loop > outputs/15-recreate-access.txt` 与 `kubectl delete po curl-loop`，并执行 `kubectl get po -o wide` | `15-recreate-access.txt`、`15-recreate-po.txt`、`15-recreate-deploy.txt` | 连续访问的输出中出现 `http=000` 的行；`kubectl get po -o wide` 的输出中曾经出现「任何 Pod 都不处于 Running 且 Ready」的时间窗。实测结果：本次替换共 232 个请求，其中 13 个失败，失败集中在 07:33:35 到 07:33:41 这 7 秒之内，同一时刻 `kubectl get po` 显示两个旧 Pod 都是 `Terminating` 而新 Pod 尚未创建 | 补充：`Recreate` 策略会先删除全部旧 Pod 再创建新 Pod，因此它必然产生一段不可用的时间。这一步与步骤 8 构成一组对照：同样是一次替换，滚动升级只出现 2 到 4 次失败，`Recreate` 出现 13 次，这一点证明了「滚动升级不中断」这个结论确实来自策略本身。另需注意：骨架的填写要点说「镜像标签必须写成 deploy.rollout.yaml 中当前的取值」，但那样就不会发生任何 Pod 模板变更，也就不会有任何 Pod 被替换，因而观察不到该策略的行为；本次让镜像由 `webapp:v7` 变为 `webapp:v6`，与策略变更一起生效 |
| 16. 收尾：把 Deployment 恢复成滚动升级 | 把 `deploy.rollout.yaml` 中的 `image` 写回 `webapp:v7`、策略写回 `RollingUpdate`，执行 `kubectl apply -f deploy.rollout.yaml`，最后执行 `kubectl get deploy,rs,po -o wide` | `16-final-state.txt` | Deployment 处于可用状态，Pod 数量等于期望副本数量 | |

### 选做：暂停与恢复

| 步骤 | 命令 | 观察什么 | 备注 |
|---|---|---|---|
| 17. 暂停滚动升级 | 执行 `kubectl rollout pause deploy/webapp`，然后把 `image` 改为 `webapp:v6` 并执行 `kubectl apply -f deploy.rollout.yaml` | 新 ReplicaSet 被创建出来，但它的副本数量一直保持为 0，因为控制器在暂停状态下不推进升级 | 教材 p.429 至 p.431 把暂停作为金丝雀发布的手段：先让少量流量进入新版本，确认无误之后再恢复 |
| 18. 恢复滚动升级 | 执行 `kubectl rollout resume deploy/webapp`，然后执行 `kubectl rollout status deploy/webapp` | 升级在恢复之后继续推进直到完成 | 暂停状态下 `kubectl rollout undo` 不生效，必须先执行 `resume` |

---

## 五、观察点与判断标准

| 现象 | 判断结论 | 判断依据 |
|---|---|---|
| 只修改 `strategy` 字段之后 ReplicaSet 的数量与名称都没有变化 | Pod 模板没有发生变化，因此控制器不创建新的 ReplicaSet，也不替换任何 Pod | 教材 p.414 与 p.418：ReplicaSet 由 Pod 模板的哈希值命名，模板不变则名称不变 |
| 修改 `image` 之后出现一个新的 ReplicaSet | Pod 模板发生了变化，控制器创建新的 ReplicaSet 并把升级工作交给它 | 教材 p.417 至 p.421 |
| 升级过程中两个 ReplicaSet 的副本数量之和最多等于 `replicas` 加上 `maxSurge` | `maxSurge` 控制的是超出期望副本数量的上限 | 教材 p.427 |
| 升级过程中处于可用状态的 Pod 数量最少等于 `replicas` 减去 `maxUnavailable` | `maxUnavailable` 是相对于期望副本数量的比例，不是绝对个数 | 教材 p.429 明确写出这一条限定条件 |
| 连续访问的输出中 `http=000` 只出现在 Pod 被终止的那一刻前后，且占该次替换总请求数的 4% 到 7% | 替换瞬间确实存在一个短暂的连接失败窗口：旧 Pod 的进程已经退出，而转发规则还没来得及不把请求转发给它。要做到零失败，需要给应用加上 `preStop` 钩子并实现优雅停机，同时让客户端具备重试 | 补充：`curl` 的状态码 000 表示连接未能建立；判定依据是失败的时刻分布而不是总行数（见 `07b-failure-attribution.txt` 与 `05-continuous-access.txt` 的统计表） |
| 失败升级期间新 Pod 处于 `ImagePullBackOff` 而旧 Pod 保持 `1/1 Running` | 控制器在无法推进升级时保留全部旧副本，因此可用性不受影响 | 教材 p.431 至 p.436 |
| 回滚之后 Pod 的名称与地址都发生变化 | 回滚的实现方式是让旧 ReplicaSet 重新创建 Pod，而不是恢复原来的 Pod 对象 | 补充：Pod 是一次性对象，删除之后无法恢复 |
| 回滚之后 `kubectl rollout history` 中新增一条记录 | 回滚本身也是一次 Pod 模板修改 | 补充 |
| `Recreate` 策略下连续访问出现 `http=000` | 该策略先删除全部旧 Pod 再创建新 Pod，因此必然产生不可用的时间窗 | 教材 p.414 |
| 执行 `kubectl run` 之后返回 `error: timed out waiting for the condition` | Pod 在 `--pod-running-timeout` 指定的期限之内没有进入 `Running` 状态。在本环境中，最常见的原因是节点镜像库中没有所需的镜像，而节点又无法访问镜像仓库 | 补充：`kubectl run` 的默认等待时间是 60 秒，错误原文只说明「等待超时」，具体原因要看 `kubectl describe po <Pod 名称>` 输出末尾 Events 段落中的 `Pulling`、`Pulled`、`Failed to pull image` 与 `BackOff` 这几类事件；如果命令中使用了 `--rm`，Pod 已经被删除，Events 也就无从查看 |
| 连续访问的输出中 `http=000` 的行数不为 0，而 `kubectl get po` 显示 `webapp` 的 Pod 始终是 `1/1 Running` | 中断来自客户端一侧，而不是来自被升级的服务 | 补充：判断依据是「服务一侧始终存在可用的 Pod」与「客户端一侧出现了连接失败」这两件事同时成立，因此需要分别检查客户端 Pod 自身的状态与它所在节点的状态 |

---

## 六、易错点

| 编号 | 易错点 | 正确做法 |
|---|---|---|
| 1 | 把 `maxUnavailable` 当作绝对个数 | 该字段的取值是相对于期望副本数量的比例，只有写成整数时才表示绝对个数。教材 p.429 专门用一段说明这一条：期望副本数量为 3、`maxUnavailable` 为 1 时，更新过程中必须保持至少 2 个 Pod 可用，而不可用的 Pod 数量可以超过 1 |
| 2 | 认为修改 Deployment 的任意字段都会触发滚动升级 | 只有 Pod 模板发生变化时控制器才创建新的 ReplicaSet。修改 `replicas`、`strategy`、`minReadySeconds` 这类字段会就地更新，不会替换现有 Pod。步骤 4 与步骤 6 把这两种情况分开观察，就是为了得到这个结论 |
| 3 | 认为回滚会把 revision 编号退回或者删除新版本的 ReplicaSet | 回滚是一次新的模板修改，它占用一个新的 revision 编号，新版本的 ReplicaSet 会被缩容到 0 但保留下来，因此还可以再回滚回去 |
| 4 | 把 `revisionHistoryLimit` 留在默认取值就去执行多次升级 | 教材 p.426 按照写作时的 API 版本给出的默认取值是 2，也就是只保留当前版本与上一个版本；本集群使用 apps/v1，该 API 版本的默认取值是 10。无论默认取值是多少，超出限制的更早 ReplicaSet 都会被清理，回滚目标随之减少。今天要经历升级、回滚与失败升级三步，因此必须把这个字段显式写成不小于 3 的取值 |
| 5 | 认为回滚等于把原来的 Pod 找回来 | 回滚的做法是恢复 Pod 模板并让旧 ReplicaSet 重新扩容，因此新产生的 Pod 拥有新的名称与新的地址 |
| 6 | 认为 `progressDeadlineSeconds` 到期之后控制器会自动回滚 | 该字段到期只会把 `Progressing` 条件写成 `False` 并停止推进升级，回滚必须由人显式执行 |
| 7 | 在失败的升级上直接执行 `kubectl rollout status` 并等待它返回 | 该命令的默认超时时间是 600 秒，因此必须显式指定 `--timeout=30s`，否则会长时间阻塞 |
| 8 | 使用 `--record` 参数记录变更原因 | 该参数已经被废弃，在新版本集群上不再产生 `CHANGE-CAUSE` 列的内容。正确做法是在执行 apply 之前执行 `kubectl annotate deploy webapp kubernetes.io/change-cause="升级到 v7"` |
| 9 | 把 `Recreate` 策略下的 `http=000` 当成实验环境问题 | 这一类连接失败正是该策略的行为特征：控制器必须先删除全部旧 Pod 才能创建新 Pod，因此出现不可用的时间窗是预期结果 |
| 10 | 在暂停状态下执行回滚 | 暂停状态下控制器不推进升级，回滚不会生效，必须先执行 `kubectl rollout resume` |
| 11 | 在 `kubectl run` 中同时使用 `-it` 与 `--rm` 来运行长时间循环 | `-it` 会让 `kubectl` 在附加之前先等到 Pod 进入 `Running` 状态，默认只等 60 秒；`--rm` 会在命令结束时删除 Pod，因此一旦等待超时或者终端连接中断，Pod、Events 与容器日志会一起消失，失败现场无法复现。正确做法是只保留 `--restart=Never` 与 `--pod-running-timeout=3m`，让 Pod 在后台运行，需要查看输出时执行 `kubectl logs curl-loop` |
| 12 | 认为 kind 集群的节点可以像宿主机一样从镜像仓库拉取镜像 | 本环境中的节点无法访问镜像仓库：节点内部的容器运行时把镜像仓库请求交给代理 `127.0.0.1:9674`，而这个地址在节点内部没有服务监听，因此节点内拉取镜像会以 `proxyconnect tcp: dial tcp 127.0.0.1:9674: connect: connection refused` 失败。任何新镜像都必须先在宿主机准备好，再导入节点内部 |
| 13 | 使用 `kind load docker-image` 导入从镜像仓库拉取的多平台镜像 | 从镜像仓库拉取的镜像通常带有清单列表（manifest list），`kind load docker-image` 会以 `--all-platforms` 的方式导入，而宿主机上并不存在其他平台的层，因此会报 `content digest ... not found`。正确做法是先在宿主机执行 `docker save curlimages/curl:8.10.1 -o /tmp/curl.tar`，再执行 `docker exec -i kind-control-plane ctr -n k8s.io images import --digests --snapshotter=overlayfs -` 并把上一步生成的 tar 文件从标准输入交给该命令 |
| 14 | 使用 `docker cp` 把镜像文件复制到节点容器的 `/tmp` 目录之后再从节点内读取 | 节点容器中的 `/tmp` 由独立的内存文件系统挂载，`docker cp` 会报告复制成功，但写入的内容被该挂载点遮盖，因此在节点内部看不到这个文件。正确做法是不经过中间文件：把宿主机上生成的 tar 文件内容通过标准输入直接交给节点内部的 `ctr images import` 命令；如果确实需要中间文件，就把目标路径写成 `/root` 这类没有额外挂载的目录 |
| 15 | 把 `webapp:v6` 与 `webapp:v7` 的响应差异理解成「404 与 200 的差异」 | v6 没有 `/version` 这个端点，因此该请求落到根路径处理器 `/`，它返回的是配置来源报告，状态码是 200；v7 则返回单行的 `version=v7`。判别响应来自哪个版本只能看正文，不能看状态码。实测依据：`05-continuous-access.txt` 中 v6 窗口的请求行全部是 `body=env  GREETING    = ...` |
| 16 | 把连接失败时 `body=` 后面的内容当作当次响应的内容 | `curl` 在连接未能建立时不会写输出文件，因此 `/tmp/b` 里保留的是上一次响应留下的内容。判定当次请求的成败只能看 `http=` 的值，正文一律以 `http=200` 的行为准 |
| 17 | 使用标签选择器采集应用日志时直接执行 `kubectl logs -l app=webapp` | 带选择器时 `kubectl` 默认只返回每个 Pod 的最后 10 行，导致两栏输出看起来对不上。正确做法是加上 `--tail=-1`，或者像 `07b-failure-attribution.txt` 那样逐个 Pod 采集之后再合并 |
| 18 | 在 `kubectl apply` 与 `kubectl rollout undo` 之间来回切换而不理会警告 | `rollout undo` 改变的是对象本身，它不会更新 `kubectl.kubernetes.io/last-applied-configuration` 注解，因此后续的 `kubectl apply` 会以旧的三方合并基准去计算差异。本次实测中该警告出现两次，恢复方式是在实验最后再执行一次 `kubectl apply -f deploy.rollout.yaml` |

---

## 七、与计划文件的对应关系

| `plan/week2/任务明细.md` Day 5 中的任务 | 本目录中对应的步骤 | 差异说明 |
|---|---|---|
| ① 执行 `kubectl get deploy webapp -o yaml`，记录 `strategy` 两个参数的默认取值 | 步骤 2 的 `00-baseline-strategy.txt` | 无差异 |
| ② 把镜像标签由 `webapp:v4` 改为 `webapp:v5` 并执行 `kubectl apply` | 步骤 3 至步骤 8，标签由 `webapp:v6` 改为 `webapp:v7` | 计划文件写作时 Day 4 尚未执行，当时的起点标签是 `v4`。当前集群中的起点标签是 `v6`，因此本次使用 `v7` |
| ③ 执行 `kubectl rollout history` 与 `kubectl rollout undo`，并用 `kubectl describe deploy` 确认镜像标签 | 步骤 9 至步骤 11 | 增加了「回滚之后 revision 编号如何变化」这一项观察 |
| ④ 调整 `maxSurge` 与 `maxUnavailable` 的组合并记录 Pod 总数 | 步骤 12 | 无差异 |
| ⑤ 制造一次失败的升级，观察 `kubectl rollout status` 的处理方式并执行回滚 | 步骤 13 至步骤 14 | 补充了 `--timeout=30s`，原因是该命令的默认超时时间是 600 秒 |
| 自检：解释一次升级过程中 `kubectl get rs` 的副本数量为什么会先增加后减少 | 步骤 7 与步骤 12 的输出，以及笔记中的「十分钟速记卡」 | 无差异 |
