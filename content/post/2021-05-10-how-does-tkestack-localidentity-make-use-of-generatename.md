---
layout:     post 
title:      "TKEStack中LocalIdentity如何利用generateName机制生成Name"
date:       2021-05-10
author:     "Chris Li"
URL: "/2021/05/10/how-does-tkestack-localidentity-make-use-of-generatename/"
tags:
    - kubernetes
    - TKEStack
    - code
categories: [ Tech ]
showtoc: false
---

日前在研究TKEStack用户机制中，发现创建LocalIdentiy时，并没有传入`metadata.name`，而最终系统会生成一个随机值，类似：
```
usr-2t455l2z
usr-dsa54sdf
usr-xxxxxxxx
```
这显然是一个随机值。由于我们希望自定义这个值，所以进行了一番测试，结果发现：
* 不设置`metadata.name`时，生成随机值
* 设置`metadata.name`之后，使用设置值

显然这个值是可以直接设置的。但是我对这个随机值的生成产生了兴趣，带着问题翻看了下源码，在`pkg\auth\registry\localidentity\strategy.go`中，找到如下片段：
```golang
func (Strategy) PrepareForCreate(ctx context.Context, obj runtime.Object) {
	localIdentity, _ := obj.(*auth.LocalIdentity)

	_, tenantID := authentication.UsernameAndTenantID(ctx)
	if len(tenantID) != 0 {
		localIdentity.Spec.TenantID = tenantID
	}
	if localIdentity.Name == "" && localIdentity.GenerateName == "" {
		localIdentity.GenerateName = "usr-"
	}

	localIdentity.Spec.Finalizers = []auth.FinalizerName{
		auth.LocalIdentityFinalize,
	}
}
```
这是localIdentity reststorage的创建预处理函数，可以看到其中对`localIdentity.Name`做了检查，但是这里却没有直接生成随机值，而是对`GenerateName`进行了一个赋值。那最终的随机值`Name`是怎么生成了呢？

看到这个`usr-`，其实已经猜到了一大半，猜想这里设置的是一个前缀，而随机值部分应该是由K8s自身的机制实现的。官网[相关文档](https://kubernetes.io/docs/reference/using-api/api-concepts/)解释如下：

> Generated values
> Some values of an object are typically generated before the object is persisted. It is important not to rely upon the values of these fields set by a dry-run request, since these values will likely be different in dry-run mode from when the real request is made. Some of these fields are:
> * name: if generateName is set, name will have a unique random name
> * creationTimestamp/deletionTimestamp: records the time of creation/deletion
> * UID: uniquely identifies the object and is randomly generated (non-deterministic)
> * resourceVersion: tracks the persisted version of the object
> * Any field set by a mutating admission controller
> * For the Service resource: Ports or IPs that kube-apiserver assigns to v1.Service objects

这里说得比较含糊，而stackoverflow中有个[问题](https://stackoverflow.com/questions/48023475/add-random-string-on-kubernetes-pod-deployment-name)说得很明确：
> You can replace name with generateName, which adds a random suffix.

以后在需要随机值的场合，可以不用自己动手了，直接依赖系统机制即可。