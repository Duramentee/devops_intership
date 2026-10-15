# tmp

## 自测6题
1. 在宿主机上的对应pid应当是不确定的, 用docker ps看当前在运行的容器, 宿主机用ps -aux看进程
2. 不会被修改, docker使用copy-on-write机制, 会在最顶层构建一个可写层, 当需要修改时, 从下层拷贝文件内容到这个可写层, 然后做临时覆盖, 但是下层的文件不会被修改, 下层依然是只读的
3. (这个问题昨天也答过了, 我这里写的粗略一点)这是cache key对比机制导致的, 如果把COPY代码放在了安装依赖之前执行, 那么改一行代码就要重装依赖, 因此构建期应当将变更频率越低的放在越前面, 变更频率高的放在后面, 这样能增加cache命中率
4. 会因为OOMKilled退出, 退出码137
5. 记不清了, 我这里先看一遍资料再回答你
CapBnd是规定容器能力上限的字段, 也就是一个进程在他的全生命周期中可获得的能力上限
CapEff是标记当前生效的能力的字段
--cap-drop=ALL 后 setuid, uid只是一个数字而已, 实际上的容器权限是由capability位来设置的, 使用--cap-drop=ALL 后, 所有的cap能力位都被弃置了, 就算setuid也不过是改了一下uid而已, 实际上的能力位没有修改也就没有能力增强, 所以提不了权
6. 这个也记不清了, 先看资料再回答你
如果容器里的用户就是root权限的(uid=0), 那么逃逸之后也肯定是宿主root, 
同样的的如果容器里的用户就是普通权限的(uid!=0), 那么逃逸之后也肯定是普通权限,
原因是docker实际上是通过限制的方式来进行用户配置, 而不是通过根本性的隔离方式(uid不同),
如果通过 --privileged, 挂载docker.sock, 以及内核漏洞等方式逃逸, 那立刻就从容器内root用户变为宿主root用户

## D6
不是一套缓存, docker的层缓存是构建时的自身机制, gocache则是构建过程中的中间产物, 换成别的有cache的东西也是一样的
会进入镜像层

## D34
说明上面某一层的输入发生了变化, 用 docker build --progress-plain 找到最先变化的那一层

## Linux 每日一题 Day 3（find）
find "/data/" -type f  -name "*.tar.gz" -mtime +30 -size +50M
find "/data/" -type f  -name "*.tar.gz" -mtime +30 -size +50M -delete
原理一: linux命令在执行前会做分词以及通配展开之类的预操作, 不加入引号, 会导致分词问题, 如果-name查出的文件有空格之类会导致错误结果
原理二: 不清楚, 这是find程序要求的吧, 这个指令我记得有一个特殊之处就是要求第一个参数一定要是要搜索的路径
附加: -size 的单位后缀大小写, m代表字节, M代表MB, +30意味着大于三十天

Linux	L4	遇到 grep / sed / awk 命令空白时，如何从输入、匹配、输出拆解命令？
不清楚, 放到下次linux三剑客专题吧
Docker	D6	Docker 层缓存与 Go 编译缓存如何区分？	
这题回答过了
Kubernetes	K25	从用户提交 Deployment 到容器运行，完整控制链路中调度器位于哪里？	
这个问题还真不清楚, 调度器是scheduler吧, 她负责pod调度, 那他应该出现在pod创建之前, replicaset controller之后
CI/CD	CI2	一个 job 的文件能否被另一个 job 直接读取？needs 与 artifact 分别做什么？	
不能直接读取, artifact用于在不同job之间传文件, needs用来指定不同job之间的作业顺序

## 第四部分
K8s	第 20 条（就绪判定失败时的两个对象口径）		
这个题也是想不起来的, 我看答案再回答了, endpoints只列出就绪地址, endpointslice会列出全部地址并且附带状态

Docker	第 31 条（升级因镜像无法拉取而停顿时的旧版本状态）	
旧版本此时仍然是可用的, 这是k8s机制导致的, 在升级过程中会保持一定数目的原副本可用以维持可用性


### 易混主语快复述
Pod	谁直接创建裸 Pod？控制器创建的 Pod 用哪个字段记录 owner？容器重启与 Pod 重建有什么不同？
人kc apply直接创建; metadata.OwnerReferences; 容器重启会影响restarts计数, pod重启会导致沙箱整体重建, 前者范围更小

Deployment / ReplicaSet	谁创建 ReplicaSet？归属字段在哪个路径？Deployment 与模板 selector 不匹配时结果是什么？
Deployment创建, 也是写在 metadata.OwnerReferences

Service / EndpointSlice	Service 是否亲自转发流量或创建端点？EndpointSlice 控制器负责什么？
不亲自转发流量, 由kubeproxy负责转发, 创建端点则是由controller执行, scheduller调度, kubelet启容器; 这个忘了, 感觉是负责将可接受流量的pod加入到自身后端列表吧

Service 无 selector	是“端点对象为空”，还是端点控制器不创建该对象？
是端点对象为空, 即使无selector也会创建对象的, 但是会导致endpoint没有可用后端


