# Day 3 · ConfigMap 与 Secret（把配置从镜像中分离）

> 目标：让 Deployment 从 ConfigMap 与 Secret 中读取配置，并亲手验证「以环境变量注入」与「以文件方式挂载」这两种注入方式在配置变更之后的更新行为差异。
> 配套资料：`plan/week2/任务明细.md` 中的 Day 3 节、`docs/k8s_in_action/04-配置与API.md`、教材第 7 章 7.4 至 7.5 节（p.323-357）。
> 笔记落点：`notes/week2/day3.md`
> 起点资产：Day 1 创建的 Deployment `webapp`（副本数量为 3）、Day 2 创建的 Service `webapp`（ClusterIP，选择器为 `app=webapp`）、以及镜像 `webapp:v4`。

今日的模型变化：Pod 模板中除了「镜像与端口」之外，新增了两类引用，也就是对 ConfigMap 的引用与对 Secret 的引用。配置文件不再位于镜像内部，而是在容器创建之前由节点上的 kubelet 依据这些引用写入容器：以环境变量方式注入的取值被写入容器进程的环境，以文件方式注入的取值被写入挂载进容器内的卷。

---

## 一、本目录中应当出现的文件

| 文件 | 说明 | 由谁编写 |
|---|---|---|
| `go-webapp/main.go` | 应用源码。与 `code/week1/day7/go-webapp/main.go` 相比，新增了「从环境变量与挂载文件读取配置」的能力，并用一个报告函数把四种来源的输出统一成同一种格式 | 已提供 |
| `go-webapp/go.mod` | 模块声明，与第 1 周的发布包完全相同 | 已提供 |
| `go-webapp/Dockerfile` | 多阶段构建、非 root 用户 uid 10001，与第 1 周的发布包完全相同 | 已提供 |
| `cm.skeleton.yaml` | 两个 ConfigMap 对象的填空骨架，字段名齐全，取值留空 | 已提供 |
| `cm.yaml` | ConfigMap 的清单文件 | 你自己编写，从骨架开始 |
| `secret.skeleton.yaml` | Secret 对象的填空骨架，字段名齐全，取值留空 | 已提供 |
| `secret.yaml` | Secret 的清单文件 | 你自己编写，从骨架开始 |
| `deploy.env.skeleton.yaml` | 以环境变量方式注入配置的 Deployment 填空骨架 | 已提供 |
| `deploy.env.yaml` | 以环境变量方式注入配置的 Deployment 清单文件 | 你自己编写，从骨架开始 |
| `deploy.volume.skeleton.yaml` | 以文件方式挂载配置的 Deployment 填空骨架 | 已提供 |
| `deploy.volume.yaml` | 以文件方式挂载配置的 Deployment 清单文件 | 你自己编写，从骨架开始 |
| `outputs/` | 命令的原始输出记录，命名规则见 `outputs/README.md` | 你自己记录 |

编写顺序建议：先改应用并构建镜像，再创建 ConfigMap 与 Secret 两个对象并观察它们的存储形式，然后创建以环境变量方式注入的 Deployment 并确认注入结果，最后创建以文件方式挂载的 Deployment，用它观察配置变更之后的差异。

---

## 二、动手之前必须先记录的基线

| 项目 | 命令 | 输出文件 | 为什么要先记录 |
|---|---|---|---|
| 节点容器与节点状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes -o wide` | `outputs/00-baseline-cluster.txt` | 确认节点容器处于运行状态；如果节点容器处于 `Exited` 状态，先执行 `docker start kind-control-plane`。节点重启会让全部容器重启，`RESTARTS` 计数与 Pod 的 IP 地址都会随之变化，因此这组取值必须在实验开始之前记录 |
| Pod 列表、IP 地址、所在节点、标签 | `kubectl get po -o wide --show-labels` | `outputs/00-baseline-pods.txt` | 记录创建新对象之前的 Pod 清单，用于在 `kubectl apply` 之后确认 Deployment 是被就地修改还是被新建 |
| 现有的 ConfigMap | `kubectl get cm -A` | `outputs/00-baseline-cm.txt` | 记录创建之前的 ConfigMap 数量。默认命名空间中会存在一个由系统自动创建的 `kube-root-ca.crt`，它不属于本次实验创建的对象 |
| 现有的 Secret | `kubectl get secret -A` | `outputs/00-baseline-secret.txt` | 记录创建之前的 Secret 数量，其中包含服务账户令牌这类系统自动创建的对象 |
| 现有的 Deployment 与 Service | `kubectl get deploy,svc -o wide` | `outputs/00-baseline-workload.txt` | 确认 Deployment `webapp` 当前的镜像标签是 `webapp:v4`、副本数量是 3，作为镜像变更之前的对照 |
| 容器内是否存在配置目录 | `kubectl exec deploy/webapp -- sh -c 'ls -l /etc | grep -E "webapp" || echo 配置目录不存在'` | `outputs/00-baseline-appdir.txt` | 证明镜像内部本来没有配置文件。这一条输出是「配置不在镜像里，而是部署时注入」这个结论的直接依据 |
| 宿主机上的镜像标签 | `docker images webapp --format '{{.Repository}}:{{.Tag}} {{.Size}}'` | `outputs/00-baseline-images.txt` | 记录构建之前的镜像标签与体积，用于确认新构建出来的镜像确实使用了新的标签 |

---

## 三、动手之前的三处预判

> 只有第一处预判属于「可以用已有机制外推」的问题，请你先写下依据再动手；第二处与第三处属于新知识，请你从给出的选项中选择一个，不要凭猜测填写具体数值。

| 编号 | 问题 | 可选答案 | 我的预判 | 判断依据 |
|---|---|---|---|---|
| 1 | 修改 ConfigMap 中 `GREETING` 的取值之后，已经运行的 Pod 内部该环境变量的取值会不会跟着变化？ | ① 立即变成新取值；② 保持旧取值，直到容器被重建；③ 环境变量变成新取值，但只对新建的连接生效 | 3 | 如果能用「Day 2 硬结论第 11 条：环境变量是容器创建时刻的快照」外推，就在这里写出外推过程  我的依据:  作为环境变量读取是 kube-let 完成的注入动作, 会在容器将要启动之前完成, 所以旧容器要重启才能看到新的值, 新容器则是直接就会看到新值 |
| 2 | 修改 ConfigMap 中 `GREETING` 的取值之后，容器内 `/etc/webapp/GREETING` 这个文件会在什么时候变成新取值？ | ① 立即；② 大约一分钟之内；③ 永不变化；④ 必须重启容器才会变化 | 2 | 新知识，先选一个选项，实验之后再解释机制  从题目来看这应该是用的挂载卷形式读取配置, 所以应该是会随着k8s的自动扫描变化而读到新值, 时间周期也是符合自动扫描周期的, 所以应该是1分钟之内 |
| 3 | 把键名为 `FOO-BAR` 的条目通过 `envFrom` 注入之后，容器内是否存在名为 `FOO-BAR` 的环境变量？ | ① 存在；② 不存在，并且不产生任何事件；③ 不存在，但会产生一条 Warning 事件 | 1 | 新知识，先选一个选项 这个确实不清楚机制, 按照1选了 |



---

## 四、操作顺序

| 顺序 | 操作 | 命令 | 要观察的内容 |
|---|---|---|---|
| 0 | 检查集群状态 | `docker ps -a --filter name=kind`，然后执行 `kubectl get nodes -o wide` | 确认节点容器处于运行状态，节点的 STATUS 列显示为 `Ready` |
| 1 | 记录第二节表格中的全部基线 | 第二节给出的命令 | 得到今天全部对比结论的参照物 |
| 2 | 阅读应用源码，确认它从哪三个位置读取配置 | 打开 `go-webapp/main.go`，找到 `greetingEnvKey`、`greetingFilePath`、`configFilePath` 三个常量的声明 | 明确应用需要哪些注入方式才能输出完整报告；路径写错时应用会输出「读取失败」而不是报错退出 |
| 3 | 构建新镜像 | 在 `code/week2/day3/go-webapp/` 目录内执行 `docker build -t webapp:v5 .` | 构建结束后执行 `docker images webapp`，确认出现 `v5` 标签，并且体积与 `v4` 属于同一量级 |
| 4 | 把镜像导入节点 | `kind load docker-image webapp:v5` | 节点上的 kubelet 只能看到节点镜像库中的镜像，因此这一步不能省略 |
| 5 | 生成两个对象的清单模板（只输出到文件，不创建资源） | `kubectl create configmap webapp-config --from-literal=GREETING=placeholder --dry-run=client -o yaml > outputs/01-dry-run-cm.yaml`，以及 `kubectl create secret generic webapp-secret --from-literal=DB_PASSWORD=placeholder --dry-run=client -o yaml > outputs/01-dry-run-secret.yaml` | 逐字段阅读两个模板。**重点观察：Secret 的模板中 `data` 段落里的取值已经是 base64 编码的字符串，而 ConfigMap 的模板中取值仍然是明文** |
| 6 | 编写 `cm.yaml` 与 `secret.yaml` | 从两个骨架改写，替换掉全部尖括号 | 两个 ConfigMap 对象各自的用途见骨架文件顶部的注释 |
| 7 | 创建两个对象 | `kubectl create -f cm.yaml -f secret.yaml` | 输出应当是 `configmap/webapp-config created` 这一类以对象类型开头的结果 |
| 8 | 观察两个对象的存储形式 | `kubectl get cm webapp-config -o yaml > outputs/02-cm-yaml.txt`、`kubectl get secret webapp-secret -o yaml > outputs/02-secret-yaml.txt`、`kubectl describe cm webapp-config > outputs/02-describe-cm.txt`、`kubectl describe secret webapp-secret > outputs/02-describe-secret.txt` | 对比两个 YAML：ConfigMap 的 `data` 中取值是明文，Secret 的 `data` 中取值是 base64 编码。再执行 `kubectl get secret webapp-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d`，确认任何人都可以解码还原，从而得出结论：base64 是编码而不是加密 |
| 9 | 编写并创建以环境变量方式注入的清单 | 从 `deploy.env.skeleton.yaml` 写出 `deploy.env.yaml`，然后执行 `kubectl apply -f deploy.env.yaml` | 因为 `metadata.name` 与 Day 1 的对象相同，`kubectl apply` 会就地修改已有的 Deployment。执行 `kubectl get deploy webapp -o wide` 确认镜像标签已经变成 `webapp:v5`，并且 `kubectl get rs` 中出现了一个新的 ReplicaSet |
| 10 | 确认环境变量已经注入 | `kubectl exec deploy/webapp -- env > outputs/03-env-injected.txt` | 逐个键核对：`GREETING`、`APP_ENV`、`DB_PASSWORD` 是否出现，`FOO-BAR` 是否出现。这一步同时验证预判 3 |
| 11 | 观察应用读到的配置 | `kubectl exec deploy/webapp -- wget -qO- http://localhost:8080/ > outputs/03-app-report-env.txt`，以及 `kubectl exec deploy/webapp -- wget -qO- http://localhost:8080/config` | 第一个端点中 `env GREETING` 一行显示注入结果，`file GREETING` 一行显示读取失败；第二个端点返回 500，因为这一份 Deployment 没有挂载卷 |
| 12 | 编写并创建以文件方式挂载的清单 | 从 `deploy.volume.skeleton.yaml` 写出 `deploy.volume.yaml`，然后执行 `kubectl apply -f deploy.volume.yaml` | 新增的对象名称是 `webapp-vol`。注意它的 Pod 标签与 Day 2 的 Service 选择器不同，因此不会进入该 Service 的端点列表 |
| 13 | 确认卷内出现了文件 | `kubectl exec deploy/webapp-vol -- ls -la /etc/webapp /etc/webapp-file > outputs/04-volume-files.txt`，然后执行 `kubectl exec deploy/webapp-vol -- cat /etc/webapp-file/config.conf` | 观察「对象中的一个键对应容器内的一个文件，键名就是文件名」这一行为；同时观察目录内的 `..data` 符号链接以及 `..2026_...` 形式的目录，它们与原子更新有关 |
| 14 | 修改 ConfigMap 中的一个取值 | 执行 `kubectl edit cm webapp-config`，把 `GREETING` 改成新的取值 | 编辑过程中不要修改键名，只改取值。修改完成后执行 `kubectl get cm webapp-config -o yaml` 确认写入结果 |
| 15 | 观察两种注入方式在配置变更之后的差异 | 依次执行 `kubectl exec deploy/webapp-vol -- env | grep GREETING`、`kubectl exec deploy/webapp-vol -- cat /etc/webapp/GREETING`、`kubectl exec deploy/webapp-vol -- wget -qO- http://localhost:8080/` | 把三条输出并排记录到 `outputs/05-config-drift.txt`。要观察的现象是：同一次请求的响应中，环境变量仍然是旧取值，而文件已经变成新取值。这一步同时验证预判 1 与预判 2 |
| 16 | 观察环境变量方式要怎样才能读到新取值 | 执行 `kubectl rollout restart deploy/webapp`，等新 Pod 就绪之后执行 `kubectl exec deploy/webapp -- env | grep GREETING` | 确认只有容器被重建之后，环境变量才会变成新取值；同时记录 `kubectl get po` 的输出，说明 Pod 的名称与 IP 地址都发生了变化 |
| 17 | 观察 `subPath` 挂载不随配置更新（选做） | 在 `deploy.volume.yaml` 的 `volumeMounts` 中新增一个列表项：复用 `webapp-file` 这个卷，把 `mountPath` 写成 `/etc/webapp-file/sub-config.conf`（也就是**文件路径**），并增加 `subPath: config.conf`。`kubectl apply` 之后先记录两个文件的取值，再修改 `webapp-file-config` 中的配置，最后把两个文件的取值与 `ls -l` 的输出并排对比 | 确认以 `subPath` 方式挂载的单个文件在 ConfigMap 更新之后保持不变，原因是这种方式不会经过原子切换的符号链接。**注意：只要写了 `subPath`，`mountPath` 就必须指向文件，不能指向目录；如果保留目录形式的 `mountPath` 并在同一项上增加 `subPath`，容器内该路径会变成一个普通文件，应用读取 `/etc/webapp-file/config.conf` 时会失败** |
| 18 | 观察以文件方式挂载 Secret（选做） | 在 `deploy.volume.yaml` 的 `volumes` 中新增一项 `secret` 类型的卷，其中引用 Secret 对象的字段名是 `secretName`（`configMap` 类型使用的是 `name`），再增加对应的 `volumeMounts` 列表项把该卷挂载到 `/etc/webapp-secret`，然后执行 `kubectl exec deploy/webapp-vol -- ls -la /etc/webapp-secret` 与 `kubectl exec deploy/webapp-vol -- cat /etc/webapp-secret/DB_PASSWORD` | 确认卷内保存的是解码之后的明文，应用不需要自己做 base64 解码，因此把 Secret 当文件用比当环境变量用更不容易泄漏 |
| 19 | 清理临时对象 | 执行 `kubectl delete deploy webapp-vol`，然后执行 `kubectl get po` | 确认只剩 Deployment `webapp` 管理的 Pod。保留 `cm.yaml` 与 `secret.yaml`，因为 Day 4 与 Day 5 的清单还要引用这两个对象 |

---

## 五、镜像标签与实验变体的对应关系 	

| 标签 | 内容 | 用在什么时候 |
|---|---|---|
| `webapp:v4` | 第 1 周的发布包。响应内容硬编码为 `<h1>Hello DevOps</h1>`，不读取任何外部配置 | Day 1 与 Day 2 |
| `webapp:v5` | 在 v4 的基础上增加「从环境变量与挂载文件读取配置」的能力，根路径返回一份文本报告，并增加 `/config` 端点 | Day 3（今天） |
| `webapp:v6` | 在 v5 的基础上增加 `/healthz` 与 `/readyz` 两个端点，用于 Day 4 的两种探针实验 | Day 4 与 Day 5 |

> 与 `plan/week2/任务明细.md` 的偏差说明：原计划把 Day 4 构建的镜像也命名为 `webapp:v5`，但这样会让 Day 5 的「升级与回滚」缺少两个可以区分的版本。因此这里把 Day 4 构建的镜像改名为 `webapp:v6`，Day 5 的升级过程相应地由「v4 升级到 v5」调整为「v5 升级到 v6」，其余步骤不变。

---

## 六、验收标准

| 编号 | 标准 |
|---|---|
| 1 | `kubectl get cm webapp-config -o yaml` 的输出中，`data` 段落里的取值是明文；`kubectl get secret webapp-secret -o yaml` 的输出中，`data` 段落里的取值是 base64 编码，并且能够用 `base64 -d` 还原出原始取值 |
| 2 | 以环境变量方式注入的 Pod 中，`env` 命令的输出包含 `GREETING`、`APP_ENV`、`DB_PASSWORD` 三个变量，不包含 `FOO-BAR` |
| 3 | 以文件方式挂载的 Pod 中，`/etc/webapp` 目录下出现 `GREETING`、`APP_ENV`、`FOO-BAR` 三个文件，`/etc/webapp-file` 目录下出现 `config.conf` 一个文件 |
| 4 | 修改 ConfigMap 之后，在不重启容器的前提下，同一次请求的响应中环境变量显示旧取值、文件显示新取值，并且能够用自己的话解释产生这种差异的机制 |
| 5 | 能够回答「为什么要把配置放在 ConfigMap 中而不是写进镜像」「Secret 是不是加密存储」这两个问题，并且每条回答都能指出对应的实测输出文件 |
