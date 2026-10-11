# Day 5 学习笔记 · 滚动升级与回滚（在不中断服务的前提下发布新版本）

> 日期：2026-09-22 · 代码：`code/week2/day5/`（`deploy.rollout.yaml`、`deploy.recreate.yaml`、`go-webapp/`、`outputs/`）
> 状态：**已提炼为归档**（2026-09-22）。复习时不需要通读本文件，只需阅读 `notes/week2/提炼-反例与关系.md`；本文件保留采集记录与逐字段解析，用于回查具体取值。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 5 节、`docs/k8s_in_action/05-Deployment与StatefulSet.md`、教材 9.3 节（p.413-438），其中 9.3.2 升级、9.3.3 回滚、9.3.4 控制速率、9.3.5 暂停、9.3.6 阻止出错版本
> 起点资产：Deployment `webapp`（副本数量为 2、镜像 `webapp:v6`、`revision=10`、`generation=12`、带存活探针与就绪探针）、Service `webapp`（ClusterIP 为 `10.96.135.12`、端口 8080）、ConfigMap `webapp-config`、Secret `webapp-secret`
> 今日的模型变化：Pod 模板没有新增字段，新增的是 Deployment 自身的四个字段，也就是 `spec.strategy`、`spec.minReadySeconds`、`spec.revisionHistoryLimit` 与 `spec.progressDeadlineSeconds`。应用改动只有一处，也就是新增了 `/version` 端点（镜像 `webapp:v7`）。
> 今日新增资产：镜像 `webapp:v7`、ReplicaSet `webapp-54c66c8c74`（v7）、ReplicaSet `webapp-7f78498c55`（v6）、客户端镜像 `curlimages/curl:8.10.1`、`outputs/` 中的实测记录

---

## 一、今日速览（结论）

| 编号 | 结论 | 原始输出依据 |
|---|---|---|
| 1 | 只修改 `strategy` 字段不会创建新的 ReplicaSet，也不会替换任何 Pod：`maxSurge` 由 1 改成 2 时 `generation` 由 14 增到 15，而 `revision` 一直是 12，ReplicaSet 的名称、`DESIRED` 与 Pod 的名称、`AGE` 全部不变 | `04b-apply-strategy-clean.txt` |
| 2 | `metadata.generation` 记录的是 `spec` 被修改的次数（含策略字段），`deployment.kubernetes.io/revision` 记录的是 Pod 模板被修改的次数。本次四次策略变更让 `generation` 由 12 增到 28，而同一个区间内 `revision` 只由 10 增到 22 | `04b-apply-strategy-clean.txt`、`16-final-state.txt` |
| 3 | 一次滚动升级的中间状态可以直接读到：`replicas=3`、`updatedReplicas=1`、`readyReplicas=2`、`availableReplicas=2`、`unavailableReplicas=1`，也就是说 Pod 总数在那一刻等于期望副本数量加上 `maxSurge` | `06-rollout-status.txt` |
| 4 | `kubectl get rs -w` 的连续输出给出了完整的替换顺序：新 ReplicaSet 的 `DESIRED` 由 0 增到 1，旧 ReplicaSet 由 2 减到 1，随后新 ReplicaSet 由 1 增到 2、旧 ReplicaSet 由 1 减到 0。两个 ReplicaSet 的 `DESIRED` 之和最大为 3、最小为 2 | `07-rs-watch.txt` |
| 5 | 当 Pod 模板与某个已经存在的 ReplicaSet 完全一致时，控制器不会创建新的 ReplicaSet，而是把这个旧 ReplicaSet 重新变为当前版本，并给它分配一个新的 `revision` 编号。实测：`webapp-7f78498c55` 的 `revision` 由 13 变成 15，`webapp-54c66c8c74` 的 `revision` 由 14 变成 16、再由 16 变成 18 | `09-history-before-undo.txt`、`11-history-after-undo.txt`、`12-surge-unavailable-combos.txt` |
| 6 | 回滚的实现方式是把目标历史 ReplicaSet 的副本数量重新调大。回滚之后 Pod 的名称与 IP 地址全部改变：回滚之前是 `webapp-54c66c8c74-lx9cs` 与 `webapp-54c66c8c74-v9kn2`，地址是 `10.244.0.18` 与 `10.244.0.19`；回滚之后变成 `webapp-7f78498c55-88kbg` 与 `webapp-7f78498c55-94tvr`，地址是 `10.244.0.20` 与 `10.244.0.21` | `10-after-undo.txt` |
| 7 | 回滚会占用一个新的 `revision` 编号，而不是把编号退回。回滚之前的历史是 6、7、9、10、13、14，回滚之后是 6、7、9、10、14、15，原来的 13 消失、新增 15 | `09-history-before-undo.txt`、`11-history-after-undo.txt` |
| 8 | `revisionHistoryLimit=5` 时版本历史恰好保留 6 条记录，也就是 1 个当前版本加 5 个历史版本，实测六次采集的历史列表长度都是 6 | `11-history-after-undo.txt`、`16-final-state.txt` |
| 9 | `maxSurge=0 maxUnavailable=1` 时控制器采用先删后建：扩缩容事件显示同一秒内既执行了「把新的 ReplicaSet 由 0 扩到 1」也执行了「把旧的 ReplicaSet 由 2 缩到 1」，因此 Pod 总数始终保持 2，同一时刻 `kubectl get po` 中一个旧 Pod 处于 `Terminating` | `12-surge-unavailable-combos.txt` |
| 10 | `maxSurge=100% maxUnavailable=0` 时 Pod 总数达到 4，等于 2 乘以 2：同一时刻 `kubectl get po` 中有 2 个旧 Pod 处于 `Running`、2 个新 Pod 处于 `ContainerCreating`，扩缩容事件显示新的 ReplicaSet 一次性由 0 扩到 2 | `12-surge-unavailable-combos.txt` |
| 11 | 升级被阻止时旧版本保持可用：镜像指向不存在的标签时新 Pod 停在 `ImagePullBackOff`，`Available` 条件是 `True` 且原因为 `MinimumReplicasAvailable`，`availableReplicas` 仍是 2，同一阶段的 178 个客户端请求全部得到 200 应答 | `13-failed-upgrade.txt`、`05-continuous-access.txt` |
| 12 | 升级被阻止 20 秒之后 `Progressing` 条件被写成 `False`，原因为 `ProgressDeadlineExceeded`，消息为 `ReplicaSet "webapp-679979b5d6" has timed out progressing.`，而控制器不会自动回滚 | `13-failed-upgrade.txt` |
| 13 | 客户端在 `webapp:v6` 上的请求由根路径处理器应答：状态码是 200，正文是配置来源报告，第一行形如 `env  GREETING    = "Hello from ConfigMap"`。因此判别响应来自哪个版本只能看正文，不能看状态码 | `05-continuous-access.txt` 的判别标记一节 |
| 14 | 滚动替换期间确实存在连接失败的窗口：`v6` 与 `v7` 之间的每一次替换都会出现 2 到 4 次 `http=000`，占该窗口请求数的 4% 到 7%。12 个窗口中共有 9 个窗口出现失败，连稳定运行窗口内也会零星出现 1 次 | `05-continuous-access.txt` 的统计表 |
| 15 | `Recreate` 策略的失败次数显著高于滚动升级：同一次替换中共 232 个请求、13 个失败，失败集中在 `07:33:35` 到 `07:33:41` 这 7 秒之内，同一时刻两个旧 Pod 都是 `Terminating` 而新 Pod 尚未创建 | `15-recreate-access.txt`、`15-recreate-deploy.txt` |
| 16 | 稳定运行期间客户端的请求全部到达应用：`07:28:31` 到 `07:29:15` 之间客户端每一秒发出 4 到 5 个请求，服务端日志里每一秒也收到 4 到 5 个 `/version` 请求，两栏逐秒对应 | `07b-failure-attribution.txt` |
| 17 | 暂停状态下控制器不推进升级：执行 `kubectl rollout pause` 之后把镜像改为 `webapp:v7`，新的 ReplicaSet 被创建出来但它的 `DESIRED` 一直是 0，旧 ReplicaSet 的 `DESIRED` 保持为 2，Pod 全部还是 v6 | `17-pause.txt` |
| 18 | 恢复之后升级立即推进：执行 `kubectl rollout resume` 之后新 ReplicaSet 的 `DESIRED` 由 0 增到 2、旧 ReplicaSet 由 2 减到 0 | `18-resume.txt` |
| 19 | 集群的节点无法访问镜像仓库：节点内部的容器运行时把镜像仓库请求交给代理 `127.0.0.1:9674`，该地址在节点内部没有服务监听，拉取镜像会以 `proxyconnect tcp: dial tcp 127.0.0.1:9674: connect: connection refused` 失败 | `13-failed-upgrade.txt` 中失败 Pod 的 Events 段落 |

---

## 二、任务清单

| 编号 | 任务的名称 | 完成情况 | 原始输出留在哪 |
|---|---|---|---|
| 1 | 记录七项基线（集群、工作负载、策略默认值、版本历史、镜像标签、客户端镜像、Service 与端点） | 完成 | `outputs/00-*.txt` |
| 2 | 构建 `webapp:v7` 并导入节点 | 完成（由导入命令确认节点镜像库中存在该标签） | `outputs/01-build-and-load.txt`、`00-baseline-images.txt` |
| 3 | 填写 `deploy.rollout.yaml` 并做客户端校验 | 完成 | `outputs/03-dry-run.txt` |
| 4 | 第一次 apply：只修改策略字段 | 完成，并且补做了一次干净的对照 | `outputs/04-apply-strategy-only.txt`、`04-rs-after-strategy.txt`、`04-history-after-strategy.txt`、`04b-apply-strategy-clean.txt` |
| 5 | 启动持续访问的客户端 | 完成（客户端镜像 `curlimages/curl:8.10.1` 由宿主机导入节点） | `outputs/00-baseline-client-image.txt` |
| 6 | 第二次 apply：把镜像升级到 `webapp:v7`，客户端保持运行 | 完成 | `outputs/06-rollout-status.txt`、`06a-rollback-to-v6.txt` |
| 7 | 采集升级过程中的中间状态 | 完成 | `outputs/07-rs-watch.txt`、`06-rollout-status.txt` 的中间状态一节 |
| 8 | 导出连续访问的记录并统计结果 | 完成 | `outputs/05-continuous-access.txt`、`07b-failure-attribution.txt` |
| 9 | 查看版本历史并执行回滚 | 完成 | `outputs/09-history-before-undo.txt` |
| 10 | 确认回滚之后的镜像、Pod 名称与地址 | 完成 | `outputs/10-after-undo.txt` |
| 11 | 观察 `revision` 编号的变化 | 完成 | `outputs/11-history-after-undo.txt` |
| 12 | 速率参数的取值组合实验 | 完成，共三组：`maxSurge=1 maxUnavailable=0`、`maxSurge=0 maxUnavailable=1`、`maxSurge=100% maxUnavailable=0` | `outputs/12-surge-unavailable-combos.txt` |
| 13 | 制造一次失败的升级 | 完成 | `outputs/13-failed-upgrade.txt` |
| 14 | 从失败的升级中恢复 | 完成 | `outputs/14-recover.txt` |
| 15 | `Recreate` 策略的对照实验 | 完成 | `outputs/15-recreate-deploy.txt`、`15-recreate-access.txt`、`15-recreate-po.txt` |
| 16 | 收尾：把 Deployment 恢复成滚动升级并记录最终状态 | 完成 | `outputs/16-final-state.txt` |
| 17 | 选做：暂停滚动升级 | 完成 | `outputs/17-pause.txt` |
| 18 | 选做：恢复滚动升级 | 完成 | `outputs/18-resume.txt` |
| 19 | 收尾：删除持续访问的客户端 | 完成 | `outputs/19-cleanup.txt` |

---

## 三、概念（机制）

> 阅读顺序建议：先读 3.1，确认今天变更的对象是哪几个、以及 `revision` 与 `generation` 这两个计数各自统计什么；再读 3.2，掌握新增的四个字段；然后读 3.3，把一次升级从提交到请求切换走一遍完整的链路；接着读 3.4 与 3.5 做策略对照与编号变化的对照；最后读 3.6，把命令与它们实际修改的字段对应起来。

### 3.1 今天涉及的对象，以及两个计数字段

今天没有新出现的对象类型，出现的是同一个 Deployment 的多份版本。需要分清楚的是：Deployment 是被人管理的对象，ReplicaSet 与 Pod 是由控制器创建的对象，而 `revision` 与 `generation` 连对象都不是，它们是写在注解与元数据里的两个计数。

| 对象 | 它是哪种 API 资源、属于哪个层级 | 谁创建它 | 它管理谁 | 它的生命周期与谁绑定 | 它不是什么 |
|---|---|---|---|---|---|
| Deployment | `apps/v1` 中的 Deployment，命名空间级资源 | 由人执行 `kubectl apply` 创建，今天的全部变更都作用在这一个对象上 | 它管理 ReplicaSet，并且只能通过 ReplicaSet 间接管理 Pod | 与所在命名空间绑定，只有执行 `kubectl delete deploy` 才会消失；升级与回滚都不会删除它 | 它不是容器的运行载体，Pod 的创建与调度都不由它执行；它也不是版本历史的存放处，历史版本表现为被缩容到 0 的旧 ReplicaSet |
| ReplicaSet | `apps/v1` 中的 ReplicaSet，命名空间级资源 | 由 Deployment 控制器创建，名称由「Deployment 名称 + Pod 模板的哈希值」拼成，因此可以在名称中直接看出它承载的是哪一份 Pod 模板 | 它管理 Pod，通过持续对账把处于运行状态的 Pod 数量维持成期望数量 | 由 Deployment 通过 `metadata.ownerReferences` 字段持有，Deployment 被删除时它会被级联删除；`revisionHistoryLimit` 决定最多保留几个旧 ReplicaSet | 它不是「一次升级的日志」：回滚能够选中它，是因为控制器把它缩容到 0 而不是删除它，而它自身保存着一份完整的 Pod 模板 |
| Pod | `v1` 中的 Pod，命名空间级资源 | 由 ReplicaSet 控制器创建，名称由「ReplicaSet 名称 + 五个随机字符」组成 | 它管理容器，准确地说，是节点上的 kubelet 依据 Pod 的定义创建并监控容器 | 它是一次性对象：本次每一次替换与回滚之后 Pod 的名称与 IP 地址都发生了变化 | 它不是升级的基本单位：升级的推进方式是新建 Pod 并删除旧 Pod，因此它无法被「恢复」，只能被重新创建 |
| 客户端 Pod `curl-loop` | `v1` 中的 Pod，命名空间级资源，它不带任何控制器 | 由人执行 `kubectl run` 创建 | 它不管理别的对象，它自身只是为了从一个固定的 Service 地址持续发起请求 | 与 `--restart=Never` 的约定绑定：容器结束之后不会被重启，因此它不会自我恢复 | 它不是被升级的那一侧。把它与 `webapp` 的 Pod 分开看，是「服务没有中断」这个结论能够成立的前提，因为失败必须能够归因到服务侧还是客户端侧 |
| Endpoints 与 EndpointSlice | `v1` 中的 Endpoints 与 `discovery.k8s.io/v1` 中的 EndpointSlice，都是命名空间级资源 | 由端点控制器创建，人不需要也不应当手工创建 | 它记录 Service 的选择器当前选中了哪些就绪的 Pod 地址 | 与 Service 同名并且随 Service 一起存在，地址列表随 Pod 的就绪状态变化 | 它不是负载均衡器，转发动作由每个节点上的 kube-proxy 依据它来更新规则 |
| `revision`（不是对象） | 写在 Deployment 与 ReplicaSet 的注解 `deployment.kubernetes.io/revision` 中的编号 | 由 Deployment 控制器写入 | 不管理任何对象 | 每次 Pod 模板变更时新增一个编号，编号一去不复返 | 它不统计 `spec` 的全部修改：只修改 `strategy` 时它不变化 |
| `metadata.generation`（不是对象） | Deployment 的元数据字段 | 由 API Server 写入 | 不管理任何对象 | 每次 `spec` 发生变化时递增 | 它不表示 Pod 模板变化：本次实测中策略字段的两次修改让它由 14 增到 16，而 `revision` 一直是 12 |

### 3.2 今日新增字段清单

| 字段（YAML 路径） | 是否必须书写 | 含义 | 默认取值与由谁补全 | 本次的取值与实测结果 |
|---|---|---|---|---|
| `spec.strategy.type` | 可以省略 | 指定控制器替换 Pod 的方式，取值为 `RollingUpdate` 或 `Recreate` | 省略时由 API Server 补全为 `RollingUpdate`，教材 p.414 说明这是默认策略 | 主线清单写 `RollingUpdate`，对照清单写 `Recreate` |
| `spec.strategy.rollingUpdate.maxSurge` | 在 `RollingUpdate` 策略下可以省略 | 在期望副本数量之外，最多允许额外创建多少个 Pod，它决定升级期间 Pod 总数的上限 | 省略时默认值为 25%，取百分数时由控制平面向上取整 | 本次实测取值：`1` 时 Pod 总数最大为 3；`100%` 时 Pod 总数最大为 4；`0` 时 Pod 总数始终为 2 |
| `spec.strategy.rollingUpdate.maxUnavailable` | 在 `RollingUpdate` 策略下可以省略 | 升级期间最多允许多少个 Pod 处于不可用状态，它决定可用 Pod 数量的下限 | 省略时默认值为 25%，取百分数时由控制平面向下取整，并且与 `maxSurge` 不允许同时为 0 | 本次实测取值：`0` 时可用 Pod 数量始终不小于 2；`1` 时同一秒内既扩容又缩容，可用数量一度降到 1 |
| `spec.minReadySeconds` | 可以省略 | 新 Pod 进入就绪状态之后还必须连续成功运行多少秒，才被计入可用 | 省略时默认值为 0，此时就绪与可用在同一瞬间发生 | 本次全程没有显式书写，最终状态中该字段仍为空 |
| `spec.revisionHistoryLimit` | 可以省略 | Deployment 最多保留多少个旧 ReplicaSet 作为历史版本，也就是回滚时可以选到的目标数量上限 | 教材 p.426 按写作时的版本写明默认值是 2，并在同一页说明 apps/v1beta2 起默认值是 10；本集群为 apps/v1，基线实测该字段尚未书写时取值是 10 | 本次显式写成 5，实测版本历史恰好保留 6 条记录 |
| `spec.progressDeadlineSeconds` | 可以省略 | 升级过程被卡住多少秒之后，`Progressing` 条件被写成 `False` | 省略时默认值为 600 秒，教材 p.437 写明这一条；基线实测未书写时的取值确实是 600 | 本次显式写成 20，实测失败升级持续约 20 秒之后 `Progressing` 变成 `False`，原因为 `ProgressDeadlineExceeded` |
| `spec.paused` | 只在暂停实验中变化 | 暂停状态下控制器不推进升级，但仍然会处理其他字段的变化 | 省略时默认为 `false` | 执行 `kubectl rollout pause` 之后取值变为 `true`，新 ReplicaSet 的 `DESIRED` 保持为 0；执行 `kubectl rollout resume` 之后该字段被清空 |
| `status` 段落中的 `replicas`、`updatedReplicas`、`readyReplicas`、`availableReplicas`、`unavailableReplicas` 与 `conditions` | 一律不书写 | 记录控制器对账之后得到的实际状态 | 全部由 Deployment 控制器写入 | 升级中间状态实测：`replicas=3`、`updatedReplicas=1`、`readyReplicas=2`、`availableReplicas=2`、`unavailableReplicas=1` |
| `spec.template.spec.containers[].imagePullPolicy` | 可以省略 | 决定节点上的 kubelet 是否去镜像仓库拉取镜像 | 镜像标签不是 `latest` 时默认值为 `IfNotPresent`；标签是 `latest` 时默认值为 `Always` | 本集群的节点无法访问镜像仓库，因此只能写明确切的标签并事先把镜像导入节点 |

手写清单时应当省略的是 `status` 整个段落、`metadata` 中的 `generation` 与 `creationTimestamp` 一类由服务端写入的字段、以及全部取值等于默认值的字段。反过来说，`metadata.name` 与 `spec.selector.matchLabels` 必须书写，而且后者的取值一旦创建就不允许修改。

### 3.3 全流程工作链路：从执行 apply 到请求切换到新版本

前置条件的说明：本次实测中 Deployment 的镜像由 `webapp:v6` 变为 `webapp:v7`，客户端 Pod `curl-loop` 在整个过程中持续向 `http://webapp:8080/version` 发起请求。

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 | 依据 |
|---|---|---|---|---|---|---|
| 1 | 人 | `deploy.rollout.yaml` | 执行 `kubectl apply` | 请求被提交给 API Server | `03-dry-run.txt` 记录了客户端校验的结果；加上 `--dry-run=client` 时只做本地校验，不发送请求 | 补充 |
| 2 | API Server | 来自客户端的请求 | 校验字段，把对象写入 etcd，并补全默认值 | 对象的 `spec` 被更新，`metadata.generation` 增加 | 实测：本次升级时 `generation` 由 17 增到 18 | 补充 |
| 3 | Deployment 控制器 | 监听到的 Deployment 变化 | 依据 `spec.template` 计算哈希值，并检查对应名称的 ReplicaSet 是否存在 | 已经存在的 ReplicaSet 被重新选为当前版本，或者出现一个新的 ReplicaSet | 实测：镜像由 v6 变为 v7 时，昨天已经存在的 `webapp-54c66c8c74` 被重新选中，`revision` 由 12 变成 14 | 教材 p.417 至 p.421 |
| 4 | Deployment 控制器 | `maxSurge`、`maxUnavailable`、`minReadySeconds` 与两个 ReplicaSet 的实际状态 | 反复调整两个 ReplicaSet 的副本数量 | 两个 ReplicaSet 的 `DESIRED` 交替变化，Pod 总数在 `replicas` 与 `replicas + maxSurge` 之间 | `07-rs-watch.txt`：新 RS 的 `DESIRED` 依次为 0、1、1、2、2，旧 RS 依次为 2、1、1、1、0 | 教材 p.426 至 p.429 |
| 5 | ReplicaSet 控制器 | 被修改的 ReplicaSet 的 `spec.replicas` | 创建缺少的 Pod，删除多余的 Pod | 出现新的 Pod 对象（名称形如 `webapp-54c66c8c74-lx9cs`），旧 Pod 进入 `Terminating` | `06-rollout-status.txt` 的中间状态一节 | 教材 p.417 至 p.421 |
| 6 | kube-scheduler | 新创建的、`spec.nodeName` 为空的 Pod | 挑选节点并把结果写入 `spec.nodeName` | Pod 的 `STATUS` 由 `Pending` 变为 `ContainerCreating` | 升级中间状态里新 Pod 的 `STATUS` 一列是 `ContainerCreating` | 补充 |
| 7 | 节点上的 kubelet 与容器运行时 | 被调度到本节点的 Pod 定义 | 从节点内部的镜像库取用镜像，创建容器，并按 `periodSeconds` 的周期执行就绪探针 | 容器开始运行，就绪探针成功之后 `READY` 变为 `1/1` | `13-failed-upgrade.txt` 的 Events 段落恰好展示了失败时的反向过程：`Pulling` 与 `Failed to pull image` | 补充 |
| 8 | 端点控制器 | Pod 的就绪状态与 Service 的选择器 | 把就绪的 Pod 地址写入同名 EndpointSlice | 地址列表增加新 Pod 的地址、移除旧 Pod 的地址 | `00-baseline-endpoints.txt`、`16-final-state.txt` 的端点一节 | 教材 p.435 |
| 9 | 每个节点上的 kube-proxy | EndpointSlice 的变化 | 更新本节点上的转发规则 | 新 Pod 开始接收请求；因为 Service 地址不变，所以客户端日志中先出现旧版本的正文、随后出现新版本的正文 | `05-continuous-access.txt`：升级窗口 54 个请求中，44 个由 v6 应答、10 个由 v7 应答，另有 2 个连接失败 | 补充 |
| 10 | Deployment 控制器 | 升级完成之后的实际状态 | 更新 `status` 段落 | `availableReplicas` 等于期望副本数量，`Progressing` 条件为 `NewReplicaSetAvailable` | `14-recover.txt` 的 conditions 一节 | 补充 |
| 11 | 人 | 执行 `kubectl rollout undo deploy/webapp` | 控制器把目标历史 ReplicaSet 的 Pod 模板写回 Deployment，随后重复第 3 步到第 10 步 | 目标历史 ReplicaSet 的副本数量重新扩大，当前版本的 ReplicaSet 被缩容到 0，版本历史中新增一条记录 | 实测：`revision` 由 14 变成 15，`webapp-7f78498c55` 的 `DESIRED` 由 0 变回 2 | 教材 p.422 至 p.425 |
| 12 | Deployment 控制器（升级被卡住时） | 新 Pod 一直无法就绪这一事实 | 在 `maxUnavailable` 的约束之下停止删除旧 Pod；超过 `progressDeadlineSeconds` 之后把 `Progressing` 条件写成 `False` | 旧 Pod 保持 `1/1 Running`，新 Pod 停在 `ImagePullBackOff`，`unavailableReplicas` 为 1 | `13-failed-upgrade.txt`：`availableReplicas=2`、`unavailableReplicas=1`、`Progressing=False reason=ProgressDeadlineExceeded` | 教材 p.431 至 p.437 |

### 3.4 两种升级策略的对照

| 对照项 | `RollingUpdate` | `Recreate` |
|---|---|---|
| 控制器替换 Pod 的顺序 | 渐进替换：先扩容新的 ReplicaSet，等新 Pod 可用之后缩小旧的 ReplicaSet，如此反复 | 先一次性删除全部旧 Pod，等旧 Pod 全部消失之后再把新的 ReplicaSet 扩容 |
| 本次实测的过程 | 新 RS 的 `DESIRED` 为 0、1、1、2、2，旧 RS 为 2、1、1、1、0，Pod 总数最大 3 最小 2 | 同一时刻两个旧 Pod 都是 `Terminating` 而新 Pod 尚未创建，`kubectl rollout status` 输出 `0 of 2 updated replicas are available` |
| 本次实测的客户端结果 | 替换窗口 54 个请求中出现 2 次连接失败 | 共 232 个请求中出现 13 次失败，集中在 7 秒之内 |
| 是否允许出现 `rollingUpdate` 段落 | 允许，`maxSurge` 与 `maxUnavailable` 只在该策略下有意义 | 不允许，保留该段落会被 API Server 直接拒绝 |
| 适用场景 | 应用能够同时提供两个版本的服务时使用，教材 p.414 推荐优先使用这一策略 | 应用不能同时运行两个版本时使用，代价是必然出现一段不可用的时间 |
| 教材依据 | 教材 p.414 | 教材 p.414 |

### 3.5 `revision` 与 `generation` 的区别

| 对照项 | `deployment.kubernetes.io/revision` | `metadata.generation` |
|---|---|---|
| 它记录什么 | Pod 模板被修改过多少次，也就是「这是第几个版本」 | 对象的 `spec` 被修改过多少次 |
| 由谁写入 | Deployment 控制器 | API Server |
| 变更策略字段时是否递增 | 不递增，本次 `maxSurge` 由 1 改到 2 时它一直是 12 | 递增，本次同一次修改让 `generation` 由 14 增到 15 |
| 变更镜像时是否递增 | 递增，本次升级时它由 13 变成 14 | 递增，本次升级时 `generation` 由 17 增到 18 |
| 回滚时的行为 | 占用一个新的编号，本次由 14 变成 15 | 递增 |
| 它决定什么 | 回滚的可选目标，历史列表中的每一行对应一个 ReplicaSet | 控制器是否已经处理完这次变更，由 `status.observedGeneration` 与之对齐 |
| 本次的最终取值 | 22 | 28 |

### 3.6 命令与它们实际修改的字段

| 命令 | 它实际修改的对象与字段 | 是否产生新的 ReplicaSet | 说明 |
|---|---|---|---|
| `kubectl apply -f deploy.rollout.yaml` | Deployment 的 `spec` | 当 `spec.template` 变化时产生 | 本次实测中策略字段变化不产生，镜像变化产生 |
| `kubectl patch deploy webapp --type=merge -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":2}}}}'` | `spec.strategy.rollingUpdate.maxSurge` | 不产生 | 本次用它完成「只修改策略字段」的干净对照 |
| `kubectl set image deploy/webapp webapp=webapp:does-not-exist` | `spec.template.spec.containers[0].image` | 产生 | 本次用它制造失败升级；它不会更新 `last-applied-configuration` 注解 |
| `kubectl rollout status deploy/webapp` | 只读取状态 | 不产生 | 升级被卡住时它以非零状态结束 |
| `kubectl rollout history deploy/webapp` | 只读取 Deployment 与全部历史 ReplicaSet | 不产生 | 历史列表的长度等于 `revisionHistoryLimit` 的值加 1 |
| `kubectl rollout undo deploy/webapp` | `spec.template` 与 `deployment.kubernetes.io/revision` | 会把历史 ReplicaSet 重新扩容 | 它不更新 `last-applied-configuration`，因此之后执行 `kubectl apply` 会出现三方合并基准不一致的警告 |
| `kubectl rollout pause` 与 `resume` | `spec.paused` | 暂停期间会创建新 ReplicaSet 但不扩容 | 本次实测：暂停期间新 RS 的 `DESIRED` 保持为 0；恢复之后立即推进到 2 |
| `kubectl get events --field-selector involvedObject.kind=Deployment` | 只读取事件 | 不产生 | 事件中的 `ScalingReplicaSet` 记录带时刻，是还原替换顺序最可靠的依据 |

---

## 四、实测逐字段解析

### 4.1 「只修改策略字段」的干净对照（`04b-apply-strategy-clean.txt`）

| 采集时刻 | `generation` | `revision` | ReplicaSet 的名称与 `DESIRED` | Pod 的名称与 `AGE` |
|---|---|---|---|---|
| 修改之前 | 14 | 12 | 6 个，当前的是 `webapp-54c66c8c74` 且 `DESIRED=2` | `…-6t8dr` 与 `…-v6cff`，`AGE` 都是 17 分钟 |
| 执行 patch 之后（立即采集） | 15 | 12 | 与修改之前完全相同 | 与修改之前完全相同，名称与 `AGE` 都没有变化 |
| 恢复原取值之后 | 16 | 12 | 与修改之前完全相同 | 与修改之前完全相同 |

判断依据：`generation` 递增说明 API Server 确认 `spec` 发生了变化，而 `revision` 不变、ReplicaSet 列表不变、Pod 的 `AGE` 不变，三者共同说明 Pod 模板没有变化，因此控制器没有做任何替换动作。

### 4.2 升级过程中的三个统计值（`06-rollout-status.txt`）

| 字段 | 采集时刻的取值 | 它的含义 |
|---|---|---|
| `status.replicas` | 3 | 当时实际存在的 Pod 总数，等于期望副本数量 2 加上 `maxSurge` 1 |
| `status.updatedReplicas` | 1 | 已经使用新 Pod 模板的 Pod 数量，控制器刚刚把新的 ReplicaSet 扩到 1 |
| `status.readyReplicas` | 2 | 通过就绪探针的 Pod 数量，两个都是旧版本的 Pod |
| `status.availableReplicas` | 2 | 进入就绪状态并且持续满足 `minReadySeconds` 的 Pod 数量；因为 `minReadySeconds` 没有书写，所以它与 `readyReplicas` 相等 |
| `status.unavailableReplicas` | 1 | 已经存在但还不可用的 Pod 数量，也就是那个正在创建的新 Pod |
| `Progressing` 条件 | `True`，原因为 `ReplicaSetUpdated` | 控制器正在推进升级 |
| `Available` 条件 | `True`，原因为 `MinimumReplicasAvailable` | 可用数量没有低于下限 |

### 4.3 `kubectl get rs -w` 还原出的替换顺序（`07-rs-watch.txt`）

| 采集到的顺序 | `webapp-54c66c8c74`（v7）的 `DESIRED` | `webapp-7f78498c55`（v6）的 `DESIRED` | 两者之和 |
|---|---|---|---|
| 升级之前 | 0 | 2 | 2 |
| 第一次变化 | 1 | 2 | 3 |
| 新 Pod 进入就绪 | 1 | 1 | 2 |
| 第二次变化 | 2 | 1 | 3 |
| 升级完成 | 2 | 0 | 2 |

判断依据：两者之和的最大值是 3，等于 `replicas + maxSurge`；最小值是 2，等于 `replicas - maxUnavailable` 再加上 `maxUnavailable` 自身，也就是说可用数量始终没有低于 2。

### 4.4 客户端各窗口的统计（`05-continuous-access.txt`）

| 窗口 | 行区间 | 请求数 | `http=000` | 由 v7 应答 | 由 v6 应答 |
|---|---|---|---|---|---|
| 准备期（v7 稳定） | 1-2042 | 2042 | 0 | 2042 | 0 |
| 换成 v6 的替换窗口 | 2043-2155 | 57 | 4 | 43 | 14 |
| v6 稳定运行 | 2156-3605 | 290 | 1 | 0 | 290 |
| 步骤 6 升级到 v7 | 3606-3835 | 54 | 2 | 10 | 44 |
| v7 稳定运行 | 3836-4279 | 444 | 1 | 444 | 0 |
| 步骤 9 回滚到 v6 | 4280-4362 | 55 | 2 | 48 | 7 |
| v6 稳定运行 | 4363-4982 | 124 | 1 | 0 | 124 |
| 步骤 12 组合二 `0/1` | 4983-5167 | 41 | 4 | 5 | 36 |
| 步骤 12 组合三 `100%/0` | 5169-5203 | 35 | 2 | 35 | 0 |
| 恢复标准组合并升级到 v7 | 5204-5417 | 58 | 2 | 19 | 39 |
| 步骤 13 失败的升级 | 5418-5595 | 178 | 0 | 178 | 0 |
| 步骤 14 从失败的升级中恢复 | 5596-5603 | 8 | 0 | 8 | 0 |

两个需要记住的判读细节。第一个细节：v6 的响应正文是多行的配置报告，因此一个请求会产生 6 行日志，统计请求数时只能统计含 `http=` 的行。第二个细节：连接失败时 `body=` 后面显示的是上一次请求留下的残留内容，例如 `07:26:22 http=000 body=env  GREETING ...` 这一行并不表示这次连接的响应是配置报告。

### 4.5 连接失败的归因（`07b-failure-attribution.txt`）

| 采集项 | 实测取值 |
|---|---|
| 客户端出现 `http=000` 的行号 | 2075、2076、2077（时刻 `07:26:15`）、2151（`07:26:22`）、2156、3792（`07:27:34`）、3834（`07:27:39`）、3836（`07:27:40`） |
| 稳定期客户端每一秒发出的请求数 | 4 到 5 个 |
| 同一段时刻内服务端每一秒收到的 `/version` 请求数 | 4 到 5 个，与客户端逐秒对应 |
| 结论 | 稳定运行期间每一个请求都到达了应用，连接失败只在 Pod 被终止的前后出现 |

失败机制的解释（补充）：Pod 被删除时先从前端移除地址、再向进程发送终止信号，这两个动作以及各个节点上转发规则的更新都是异步的。本次的应用没有实现优雅停机，收到终止信号之后进程立即退出，因此在「转发规则里还有这个地址」到「转发规则被更新」之间的短暂窗口里，请求会被转发到一个已经退出的进程上，`curl` 因此得到连接失败。要让这一类失败消失，需要在容器上配置 `preStop` 钩子并让应用实现优雅停机，同时让客户端具备重试。

### 4.6 一次失败升级的完整事件链（`13-failed-upgrade.txt`）

| 顺序 | 事件类型 | 事件内容 |
|---|---|---|
| 1 | `Normal Scheduled` | `Successfully assigned default/webapp-679979b5d6-jxdj5 to kind-control-plane` |
| 2 | `Normal BackOff` | `Back-off pulling image "webapp:does-not-exist"` |
| 3 | `Warning Failed` | `Error: ImagePullBackOff` |
| 4 | `Normal Pulling` | `Pulling image "webapp:does-not-exist"`，这一条重复出现 2 次 |
| 5 | `Warning Failed` | `Failed to pull image "webapp:does-not-exist": ... proxyconnect tcp: dial tcp 127.0.0.1:9674: connect: connection refused` |
| 6 | `Warning Failed` | `Error: ErrImagePull` |

同一次失败中 Deployment 的状态变化如下：`Available=True reason=MinimumReplicasAvailable`、`Progressing=False reason=ProgressDeadlineExceeded message=ReplicaSet "webapp-679979b5d6" has timed out progressing.`、`replicas=3`、`unavailableReplicas=1`、`availableReplicas=2`。判断依据：`availableReplicas` 仍然是 2，说明控制器在无法推进升级时保留了全部旧副本，因此服务本身仍然可用，同一阶段的 178 个客户端请求全部得到应答。

### 4.7 Recreate 策略下的不可用时间窗（`15-recreate-access.txt`）

| 采集项 | 实测取值 |
|---|---|
| 请求总数 | 232 |
| `http=000` 的次数 | 13，占 5.6% |
| 失败的时间范围 | `07:33:35` 到 `07:33:41`，共 7 秒 |
| 每一秒的失败次数 | `07:33:35` 三次、`07:33:36` 一次、`07:33:38` 四次、`07:33:39` 四次、`07:33:41` 一次 |
| 同一时刻的 Pod 状态 | 两个旧 Pod 都是 `Terminating`，新的 Pod 还没有被创建 |
| `kubectl rollout status` 的输出 | `Waiting for deployment "webapp" rollout to finish: 0 of 2 updated replicas are available...` |

与滚动升级的对照：同一次替换在滚动升级下只出现 2 到 4 次失败，在 `Recreate` 下出现 13 次失败且持续 7 秒，因此「滚动升级不中断」这个结论确实来自策略本身，而不是来自环境或客户端的偶然因素。

### 4.8 暂停与恢复（`17-pause.txt`、`18-resume.txt`）

| 阶段 | `spec.paused` | `generation` | 新 ReplicaSet 的 `DESIRED` | 旧 ReplicaSet 的 `DESIRED` | Pod 使用的镜像 |
|---|---|---|---|---|---|
| 暂停之前 | 未设置 | 26 | 0 | 2 | `webapp:v6` |
| 执行 pause 并把镜像改为 v7 之后 | `true` | 27 | 0 | 2 | `webapp:v6` |
| 执行 resume 并等待完成之后 | 未设置 | 28 | 2 | 0 | `webapp:v7` |

判断依据：暂停期间新 ReplicaSet 已经存在并且占用了 `revision` 22，但它的 `DESIRED` 一直是 0，说明控制器在暂停状态下只建立版本、不替换 Pod。这正是教材 p.429 至 p.431 用来做金丝雀发布的做法：先让新版本存在但不接收流量，确认之后调用 `resume` 把它铺开。

---

## 五、易错点

| 编号 | 易错点 | 正确做法 |
|---|---|---|
| 1 | 认为修改 Deployment 的任意字段都会触发滚动升级 | 只有 Pod 模板发生变化时控制器才创建新的 ReplicaSet。本次实测：`maxSurge` 由 1 改成 2 时 `generation` 由 14 增到 15，而 `revision` 一直是 12，Pod 的 `AGE` 也没有变化 |
| 2 | 在 apply 一份清单时连带删掉了与本次实验无关的模板字段，导致观察无法归因 | 本次 Day 5 第一次执行的「只修改策略字段」这一步同时删掉了 Day 4 留下的 `startupProbe` 与 `SLOW_START_SECONDS` 环境变量，因此它实际触发了一次 Pod 替换。做法是先用 `kubectl get deploy webapp -o yaml` 与清单逐字段比对，再用 `kubectl patch` 只改一个字段 |
| 3 | 把 `metadata.generation` 当作 Pod 模板的版本号 | `generation` 统计 `spec` 的全部修改，`revision` 只统计 Pod 模板的修改。判断「有没有产生新版本」要看 `revision` 与 ReplicaSet 列表，不要把两者混用 |
| 4 | 认为回滚会把 `revision` 编号退回 | 回滚会占用一个新的编号，同时被回滚到的那个 ReplicaSet 的旧编号会从历史列表中消失。本次实测历史列表由 6、7、9、10、13、14 变成 6、7、9、10、14、15 |
| 5 | 认为回滚等于把原来的 Pod 找回来 | 回滚的做法是恢复 Pod 模板并让旧 ReplicaSet 重新扩容，本次回滚之后 Pod 的名称与 IP 地址全部改变 |
| 6 | 把 `maxUnavailable` 当作绝对个数 | 该字段相对期望副本数量计算。本次实测中 `maxUnavailable=1` 时同一秒内既执行扩容又执行缩容，可用数量一度降到 1，因此它限制的是不可用的数量上限，而不是可用数量的下限 |
| 7 | 把「`http=000` 的行数为 0」当作成功的标准 | 本次实测 12 个窗口中有 9 个窗口出现失败。正确的标准是失败集中在 Pod 被终止的那一到两秒内、占比很低。要让失败真正消失，需要 `preStop` 钩子、优雅停机与客户端重试 |
| 8 | 认为 v6 与 v7 的差别是「404 与 200 的差别」 | v6 没有 `/version` 端点，该请求落到根路径处理器 `/`，返回配置报告，状态码同样是 200。判别版本只能看正文 |
| 9 | 把连接失败时 `body=` 后面的内容当作本次响应 | `curl` 在连接失败时不会写输出文件，`/tmp/b` 里保留的是上一次的内容 |
| 10 | 认为 `progressDeadlineSeconds` 到期之后控制器会自动回滚 | 该字段只让 `Progressing` 条件变成 `False` 并停止推进升级，回滚必须由人执行 |
| 11 | 在失败的升级上直接执行 `kubectl rollout status` 而不指定超时 | 该命令的默认等待时间是 600 秒，因此要显式写出 `--timeout=30s`；本次的 `progressDeadlineSeconds` 是 20，所以命令在约 20 秒后就返回了 |
| 12 | 在暂停状态下执行回滚 | 暂停状态下控制器不推进升级，必须先执行 `kubectl rollout resume` |
| 13 | 使用 `--record` 参数记录变更原因 | 该参数已经被废弃。正确做法是在 apply 之前执行 `kubectl annotate deploy webapp kubernetes.io/change-cause="升级到 v7"` |
| 14 | 在 `kubectl apply` 与 `kubectl rollout undo` 之间来回切换而不理会警告 | `rollout undo` 不会更新 `last-applied-configuration` 注解，后续的 `kubectl apply` 会以旧的三方合并基准计算差异。本次实测中该警告出现两次，最后通过再执行一次 `kubectl apply -f deploy.rollout.yaml` 收尾 |
| 15 | 把 `Recreate` 策略的对照清单写成与主线清单完全相同的镜像标签 | 那样不会发生任何 Pod 模板变更，也就不会有 Pod 被替换，观察不到该策略的行为。本次让镜像由 `webapp:v7` 变成 `webapp:v6`，与策略变更一起生效 |
| 16 | 使用标签选择器采集应用日志时直接执行 `kubectl logs -l app=webapp` | 带选择器时客户端默认只返回每个 Pod 的最后 10 行，两个 Pod 一共只得到 20 行，容易误判为「日志丢了」。正确做法是加上 `--tail=-1`，或者逐个 Pod 采集之后再合并 |
| 17 | 认为 kind 集群的节点可以像宿主机一样拉取镜像 | 本集群的节点无法访问镜像仓库，任何新镜像都必须先在宿主机准备好再导入节点，并且在清单中写明确切的标签，这样默认的 `imagePullPolicy` 才会取 `IfNotPresent` 并使用本地镜像 |
| 18 | 使用 `kind load docker-image` 导入从镜像仓库拉取的多平台镜像 | 这一类镜像带有清单列表，导入时会以 `--all-platforms` 方式执行并报 `content digest ... not found`。正确做法是先用 `docker save` 生成 tar 文件，再把内容通过标准输入交给节点内部的 `ctr images import` |
| 19 | 把 `kubectl run` 的 Pod 留下来当作长期观察工具 | `--rm` 会在命令结束时删除 Pod，失败现场与容器日志会一起消失；本次改用 `--restart=Never` 加 `--pod-running-timeout=3m` 让 Pod 在后台运行，需要看输出时执行 `kubectl logs curl-loop` |

---

## 六、面试问答卡

先自己口头回答一遍，再对照要点检查遗漏。

| 编号 | 问题 | 答题要点 |
|---|---|---|
| 1 | Deployment 的滚动升级过程是怎样的？ | 控制器先依据新的 Pod 模板确认目标 ReplicaSet（存在则复用、不存在则创建），然后把新 ReplicaSet 的副本数量逐步调大、把旧 ReplicaSet 的副本数量逐步调小，直到新 ReplicaSet 的副本数量等于期望副本数量。本次实测的顺序是新 RS 的 `DESIRED` 为 0、1、1、2、2，旧 RS 为 2、1、1、1、0 |
| 2 | `maxSurge` 与 `maxUnavailable` 分别控制什么？它们的默认取值是多少？ | `maxSurge` 控制在期望副本数量之外最多可以额外创建多少个 Pod，它决定 Pod 总数的上限；`maxUnavailable` 控制升级期间最多允许多少个 Pod 不可用，它决定可用数量的下限。两者的默认取值都是 25%，取百分数时 `maxSurge` 向上取整、`maxUnavailable` 向下取整，并且不允许同时为 0 |
| 3 | 回滚是如何实现的？ | Deployment 保留旧的 ReplicaSet，每个 ReplicaSet 保存着一份完整的 Pod 模板。回滚时控制器把目标历史 ReplicaSet 的模板写回 Deployment，并把它的副本数量重新调大、把当前版本的 ReplicaSet 缩容到 0，因此产生的 Pod 拥有新的名称与新的 IP 地址 |
| 4 | 哪些改动会触发滚动升级，哪些不会？ | 只有 Pod 模板发生变化时才会产生新的版本与新的 ReplicaSet。修改 `replicas`、`strategy`、`minReadySeconds`、`revisionHistoryLimit` 这类字段会就地更新，不会替换 Pod。本次实测：`maxSurge` 由 1 改成 2 时 `generation` 增加而 `revision` 不变 |
| 5 | 升级过程中新版本的镜像拉取失败会怎样？ | 新 Pod 进入 `ErrImagePull` 或 `ImagePullBackOff`，无法进入就绪状态；受 `maxUnavailable` 的约束，控制器不会删除旧 Pod，因此服务仍然可用；超过 `progressDeadlineSeconds` 之后 `Progressing` 条件被写成 `False`，控制器不会自动回滚，需要人执行回滚 |
| 6 | `RollingUpdate` 与 `Recreate` 的区别是什么？ | `RollingUpdate` 渐进替换，任何时刻都保持一定数量的可用 Pod；`Recreate` 先删除全部旧 Pod 再创建新 Pod，必然出现一段可用数量为 0 的时间窗。本次实测：滚动升级的替换窗口出现 2 到 4 次连接失败，`Recreate` 出现 13 次失败并持续 7 秒 |
| 7 | 暂停滚动升级有什么用途？ | 暂停之后控制器只建立新版本、不替换 Pod，新 ReplicaSet 的副本数量保持为 0。这就给金丝雀发布留出了空间：先让少量流量进入新版本确认无误，再执行 `resume` 把新版本铺开 |
| 8 | 滚动升级期间真的一次请求都不会失败吗？ | 不是。本次实测中每一次 Pod 替换都会造成 2 到 4 次连接失败，原因是旧 Pod 的进程退出与各节点转发规则的更新之间存在短暂的时间差，而本次的应用没有实现优雅停机。要做到接近零失败，需要配置 `preStop` 钩子、实现优雅停机，并让客户端具备重试 |

---

## 七、十分钟速记卡

### 7.1 每个对象的一句话定义

| 对象 | 一句话定义 |
|---|---|
| Deployment | 它是声明「要运行哪个版本的 Pod 模板、要几个副本、用什么方式替换」的对象，它自己不创建 Pod，只管理 ReplicaSet |
| ReplicaSet | 它是「一份 Pod 模板加上一个期望副本数量」的载体，名称里带着 Pod 模板的哈希值，由 Deployment 控制器创建与持有 |
| Pod | 它是容器运行的载体，由 ReplicaSet 创建，属于一次性对象，被删除之后名称与 IP 地址都会重新生成 |
| 客户端 Pod `curl-loop` | 它是本次实验的观测工具，不参与被升级的那一侧，它的作用是从固定的 Service 地址持续发起请求并把结果写进容器日志 |
| EndpointSlice | 它记录 Service 当前选中了哪些就绪的 Pod 地址，是转发规则的依据 |

### 7.2 必须记住的字段

| 字段 | 必须记住的取值或含义 |
|---|---|
| `spec.strategy.type` | 取 `RollingUpdate` 或 `Recreate`，默认是前者 |
| `maxSurge` | 默认 25%，百分数向上取整；本次实测取值 1 时 Pod 总数上限为 3、100% 时为 4 |
| `maxUnavailable` | 默认 25%，百分数向下取整；本次实测取值 0 时可用数量始终不小于 2 |
| `minReadySeconds` | 默认 0，表示就绪与可用同时发生 |
| `revisionHistoryLimit` | 教材按写作时的版本给的是 2，本集群 apps/v1 的实测默认值是 10，本次显式写成 5 |
| `progressDeadlineSeconds` | 默认 600 秒，本次写成 20，到期只改条件不自动回滚 |
| `spec.paused` | 取 `true` 时控制器只建立新版本、不替换 Pod |
| `deployment.kubernetes.io/revision` | Pod 模板的版本号，回滚时会占用新的编号 |
| `metadata.generation` | `spec` 被修改的次数，本次最终取值 28 |

### 7.3 全流程链路摘要

执行 `kubectl apply` 提交清单 → API Server 校验并写入 etcd、补全默认值、递增 `generation` → Deployment 控制器按 Pod 模板哈希确认目标 ReplicaSet（存在则复用、不存在则创建）→ 控制器受 `maxSurge` 与 `maxUnavailable` 约束交替调整两个 ReplicaSet 的副本数量 → ReplicaSet 控制器创建新 Pod、删除旧 Pod → 调度器选定节点 → kubelet 取用本地镜像并创建容器、执行就绪探针 → 端点控制器把就绪 Pod 的地址写入 EndpointSlice → kube-proxy 更新转发规则、请求切换到新版本 → 控制器更新 `status` 并把旧 ReplicaSet 缩容到 0 但保留下来 → 需要回滚时由人执行 `kubectl rollout undo`，控制器把历史 ReplicaSet 的模板写回并重新扩容。

### 7.4 当天实测出来的硬结论

| 结论 | 具体取值 |
|---|---|
| 只修改策略字段不产生新版本 | `generation` 由 14 增到 15，`revision` 一直是 12 |
| 升级中间状态的三个统计值不相等 | `replicas=3`、`updatedReplicas=1`、`availableReplicas=2`、`unavailableReplicas=1` |
| 两个 ReplicaSet 的 `DESIRED` 之和的上下限 | 最大 3，等于 `replicas + maxSurge`；最小 2，可用数量始终不小于 2 |
| 回滚会占用新的编号 | `revision` 由 14 变成 15，历史列表中的 13 消失 |
| 版本历史的长度 | `revisionHistoryLimit=5` 时恰好保留 6 条记录 |
| `maxSurge=100%` 时的 Pod 总数 | 4，也就是 2 个旧 Pod 加 2 个新 Pod |
| `maxSurge=0 maxUnavailable=1` 时的替换方式 | 同一秒内既扩容又缩容，Pod 总数保持 2，一个旧 Pod 处于 `Terminating` |
| 滚动替换期间的连接失败次数 | 2 到 4 次，占该窗口请求数的 4% 到 7% |
| `Recreate` 策略下的连接失败次数 | 13 次，占 5.6%，失败时间跨度为 7 秒 |
| 失败升级期间的可用数量 | `availableReplicas=2`、`unavailableReplicas=1`、`Progressing=False reason=ProgressDeadlineExceeded` |
| 稳定运行期间的请求对应关系 | 客户端每秒 4 到 5 个请求，服务端每秒收到 4 到 5 个 `/version` 请求，逐秒对应 |
| 节点的镜像仓库访问能力 | 不可用，代理地址是 `127.0.0.1:9674` 且该地址在节点内部无人监听 |

### 7.5 出现异常时的排查顺序

1. 执行 `kubectl get deploy webapp -o jsonpath='{.spec.template.spec.containers[0].image} {.metadata.annotations.deployment\.kubernetes\.io/revision} {.spec.strategy.type}'`，先确认当前版本、版本编号与策略这三个事实。
2. 执行 `kubectl get rs -o custom-columns=NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,IMG:.spec.template.spec.containers[0].image,DESIRED:.spec.replicas`，确认两个 ReplicaSet 各自的期望副本数量，判断控制器当前停在替换的哪一步。
3. 执行 `kubectl get po -o wide`，把 Pod 的 `STATUS` 与 `AGE` 与上一步的 `DESIRED` 对照，找出处于 `Pending`、`ContainerCreating`、`ImagePullBackOff` 或 `Terminating` 的那一个。
4. 执行 `kubectl describe po <Pod 名称>` 并查看输出末尾的 Events 段落，`Pulling` 与 `Failed to pull image` 指向镜像问题，`Readiness probe failed` 指向应用问题。
5. 执行 `kubectl get deploy webapp -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'`，用 `ProgressDeadlineExceeded` 判断升级是否已经被判定为停滞。
6. 执行 `kubectl get events --field-selector involvedObject.kind=Deployment,involvedObject.name=webapp --sort-by=.lastTimestamp`，用带时刻的 `ScalingReplicaSet` 事件还原替换顺序。
7. 需要回滚时执行 `kubectl rollout undo deploy/webapp`，随后执行 `kubectl rollout status deploy/webapp` 确认它回到可用状态，最后再执行一次 `kubectl apply -f deploy.rollout.yaml` 把三方合并基准恢复正常。

### 7.6 最容易答错的若干点

| 容易答错的地方 | 正确的说法 |
|---|---|
| 「改任何字段都会滚动升级」 | 只有 Pod 模板变化才产生新版本 |
| 「`generation` 就是版本号」 | `generation` 统计 `spec` 的全部修改，版本号是 `revision` |
| 「回滚会把版本号退回去」 | 回滚占用新的版本号，被回滚到的那个编号会从历史列表消失 |
| 「回滚就是把旧 Pod 找回来」 | 回滚是让旧 ReplicaSet 重新创建 Pod，因此 Pod 的名称与 IP 地址都会变化 |
| 「`maxUnavailable` 是可用数量的下限」 | 它是不可用数量的上限，判断可用下限要用期望副本数量减去它 |
| 「滚动升级期间一个请求都不会失败」 | 实测每次替换会出现 2 到 4 次连接失败，原因是进程退出与转发规则更新之间的时间差 |
| 「`progressDeadlineSeconds` 到期会自动回滚」 | 它只把 `Progressing` 条件写成 `False` 并停止推进，回滚必须由人执行 |

### 7.7 合上笔记自测的问题

1. 一个正在运行的 Deployment 只把 `maxSurge` 由 1 改成 2，`generation`、`revision`、ReplicaSet 列表与 Pod 列表这四个观察对象分别会怎样变化？
2. 升级过程中 `replicas`、`updatedReplicas`、`availableReplicas` 与 `unavailableReplicas` 四个字段为什么会在同一时刻取不同的值？把它们与 `replicas`、`maxSurge`、`maxUnavailable` 三个设定值之间的关系写出来。
3. 一个 Deployment 的版本历史列表里为什么会出现「编号不连续」的情况？在什么情况下一个已经出现过的编号会消失？
4. 同样是 2 个副本的一次镜像变更，`maxSurge=1 maxUnavailable=0` 与 `maxSurge=0 maxUnavailable=1` 两种设定下，`kubectl get po` 与集合事件分别会出现什么样的差异？
5. 客户端在升级期间得到 `http=000`，你如何判断这些失败是来自被升级的服务，还是来自客户端本身？
6. 一个应用只提供单行版本标识的端点，另一个应用没有这个端点、所有未知路径都由根路径处理器兜底，这两种情况对「用响应正文判别版本」这件事分别意味着什么？

---

## 八、我的疑问与待补充

| 编号 | 内容 | 状态 |
|---|---|---|
| 1 | 客户端在稳定运行窗口内也会零星出现一次 `http=000`，这一条目前只用「转发规则更新存在时间差」来解释，还没有做服务端与客户端的逐毫秒对齐 | 待补充：需要在应用日志中打印请求接收的毫秒级时刻，并在客户端记录每一行对应的进程号，才能把这一条彻底对齐 |
| 2 | 暂停状态下执行 `kubectl rollout undo` 是否确实不生效 | 待验证：本次只验证了「暂停状态下不替换 Pod」，没有在暂停状态下执行回滚 |
| 3 | `minReadySeconds` 取非零值时升级会慢多少 | 待验证：本次全程没有书写该字段，最终状态中它仍为空 |
| 4 | 给应用加上 `preStop` 钩子并实现优雅停机之后，替换窗口内的连接失败次数能否降到 0 | 待验证：这是把第 14 号结论从「有失败」推进到「零失败」的下一步实验 |
| 5 | `outputs/README.md` 是本目录中一份与本实验无关的副本文件 | 待清理：确认之后删除，避免与正式的实验记录混淆 |
