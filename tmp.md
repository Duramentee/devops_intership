# tmp

## pod
1. apiVersion: v1 kind: Pod
2. 命名空间级
3. pod控制器
4. 如果是由deployment创建, 那么deployment创建replicaset, 然后replicaset创建pod 生命周期是由replicaset管理的, 裸pod的话是由创建者来手动管理
5. 不是集群级的资源, 也不是容器对象, 他是k8s中的最小可调度单位也是基石, 里面可以有多个容器, 比如一个工作容器, 一个日志容器一个监控容器按照sidecar组织在一起协同工作
判据字段的话这是我执行的指令, 在这能看到
❯ kc get pods -n shortener -o yaml | head
apiVersion: v1
items:
- apiVersion: v1
  kind: Pod

## deployment
1. apiVersion: app/v1 kind: Deployment
2. 命名空间级
3. 人执行kubectl apply, 或者ci/cd gitops operator等方式创建
4. 生命周期只由人来管理, 不受其他管理, 和replicaset以及pod都不绑定, 但是反过来依赖成立, replicaset以及pod由deployment创立时生命周期收到其管理
5. 不是 replicaset, pod等等的工作负载或者控制对象, deployment是一个负责管理replicaset的控制对象, 之后再有replicaset用来管理副本, deployment控制pod回滚等操作
判据字段:
可以通过kubectl查yaml来看到是否是deployment
❯ kc get deploy api -n shortener -o yaml
apiVersion: apps/v1
kind: Deployment
另外由spec.selector来确定其对应的pod, 由spec.template来确定其将要创建的pod的label, 这两个值要对应, 否则会导致Deployment创建的replicaset内为空, 没有受管理的pod

## replicaset
1. apiVersion: apps/v1 kind: ReplicaSet
2. 命名空间级
3. 由replicaset创建, 或者人执行kubectl apply, 或者ci/cd gitops operator等方式创建
4. 声明周期绑定于对应的deployment, 在spec.ownerreference能看到它是由哪个deployment创建的
5. 不是 deployment, pod 等等的工作负载或者控制对象, replicaset是一个负责控制pod副本数量的控制对象
可以通过kubectl查yaml来看到是否是replicaset
❯ kc get replicaset -n shortener -o yaml | head
apiVersion: v1
items:
- apiVersion: apps/v1
  kind: ReplicaSet
另外有一些关键字段用来表示当前的副本数以及期望副本数等等, 不过我记不清了

## Service
1. apiVersion: v1 kind: Deployment
2. 命名空间级
3. 人执行kubectl apply, 或者ci/cd gitops operator等方式创建
4. 生命周期只由人来管理, 不受其他管理
5. svc是一个抽象控制对象, 可以看作是一个四层网关, 用来描述一个集群的虚拟ip以及提供DNS服务, 另外在pod可接受流量时, 会将流量转发给对应pod, 分为NodePort, LoadBalancer等等
不是ingress或者其他的负载均衡七层网关, 也不是 Endpoints 与 EndpointSlice等
通过对应指令可以查到:
❯ kc get svc -n shortener -o yaml | head
apiVersion: v1
items:
- apiVersion: v1
  kind: Service
另外还有字段表明svc类型, 还有一些字段可以看是否为headless等, 我也记不清了

## Endpoints 与 EndpointSlice
1. apiVersion: v1 kind: Endpoints
apiVersion: v1 kind: EndpointSlice
2. 命名空间级
3. 由Service创建, 或者人执行kubectl apply, 或者ci/cd gitops operator等方式创建
4. 由人管理或者由对应svc管理
5. Endpoints 与 EndpointSlice 是一个存储svc对应后端pod的集合, 用来看pod是否可接受流量
以下两条命令用来查看是否正确
❯ kc get endpoints -n shortener -o yaml | head
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
apiVersion: v1
items:
- apiVersion: v1
  kind: Endpoints
❯ kc get endpointslice -n shortener -o yaml | head
metadata.ownerReferences看属于哪个svc, 另外可接受流量的pod为空时, EndpointSlice有一个字段会标记为null, svc创建时也要注意写清spec.selector否则创建的endpoint将会为空

L4: 命令不会写, 我对awk的语法基本忘光了, uniq 只会对相邻对象去重, 不做sort排序会得到错误结果
D1: overlay2是容器运行时的文件系统, 和构建时无关, 然后层cache是通过对比cache key来判断是否为同一缓存的, cache key由父层cache+本层指令字符串+本层输入内容的哈希组成
K25: 控制链路: 客户端->apiserver->etcd->Deployment controller->replicaset controller->kubelet(调用容器运行时创建容器)
数据链路: 客户端->svc的ClusterIP->每个节点上kube proxy写入的转发规则->pod的ip和端口->容器
CI2: 前端不能直接读到, 这两者分属于不同的job, 是跑在不同的runner上的(比如说不同的操作系统), 所以存在环境隔离, 哪怕不让两者并行执行而是串行执行也不行

第一题: 执行ENTRYPOINT的指令

第二题: docker的构建是逐层的, 参考cache key构成, 如果之前的cache发生了变更, 那么对应的变更层以及之后的所有层都不会cache, 而是会重构建, COPY go.mod ./ + RUN 下载依赖 + COPY . . 这样的方式就是按照不变的稳定的层在前原则构建的, 如果把COPY . .放在最前面, 那每次出现文件内容文件变更那都要重cache, 肯定会损失效率