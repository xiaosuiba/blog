---
layout:     post 
title:      "TKEStack v1.6.0 1.19版本中pod告警策略失效问题分析"
date:       2021-04-13
author:     "Chris Li"
tags:
    - kubernetes
    - TKEStack
    - code
categories: [ Tech ]
showtoc: false
---
本文从探索了TKEStack 1.6中部分告警失效的原因，并提出修复手段。
<!--more-->

日前在使用TKEStack v1.6.0的时候，发现针对工作负载的（也就是pod状态、重启次数）告警失效。我们进行了一定的分析，最终找到原因和Kubernetes 1.19以后版本中一个kubelet metrics名称修改有关。

TKEStack v1.6.0针对pod的告警使用了`k8s_pod_status_ready`, `k8s_pod_restart_total`两个metrics作为判定参数。继续查看这两个metrics的定义，发现他们都与一个名为`__pod_info2`的metrics相关，其定义如下：
```yaml
- record: __pod_info2
  expr:  label_replace(label_replace(__pod_info1{workload_kind="ReplicaSet"} * on (workload_name,namespace) group_left(owner_name, owner_kind) label_replace(kube_replicaset_owner,"workload_name","$1","replicaset","(.*)"),"workload_name","$1","owner_name","(.*)"),"workload_kind","$1","owner_kind","(.*)")  or on(pod_name,namesapce)  __pod_info1{workload_kind != "ReplicaSet"}
```
`__pod_info2`又与`__pod_info1`相关，其定义如下：
```yaml
  - record: __pod_info1
    expr: kube_pod_info* on(node) group_left(node_role) kube_node_labels
```
由`__pod_info1`，关联到`kube_node_labels`。到这里时，我们发现在v1.19版本中，`kube_node_labels`已经没有数据，看来问题就出在这里。查看其定义如下：
```yaml
  - record: kube_node_labels
    expr: kubelet_running_pod_count*0 + 1
```
定义很简单，只与`kubelet_running_pod_count`相关，而这个值在prometheus中也未能查询到，看来问题发生在这里。

简单的google之后，我们迅速发现了问题的原因：kubernetes在v1.19版本中进行了两个kubelet metrics的修改([kubernetes/kubernetes#92407](https://github.com/kubernetes/kubernetes/pull/92407))：
```
kubelet: following metrics have been renamed:
kubelet_running_container_count --> kubelet_running_containers
kubelet_running_pod_count --> kubelet_running_pods
```
该修改造成了`kube_node_labels`的失效，从而导致许多tke自定义的metrics失效。

解决方案有两种：
1. 按选择版本配置不同的prometheus
2. 使用正则表达式匹配所有版本的metrics

毫无疑问第二种方式更加简单。相关代码位于：`pkg/monitor/controller/prometheus/yamls.go`
![](/img/2021-04-13-1.PNG)
测试之后问题解决。相关[issue](https://github.com/tkestack/tke/issues/1184)和[pr](https://github.com/tkestack/tke/pull/1187)已经提交到TKEStack。