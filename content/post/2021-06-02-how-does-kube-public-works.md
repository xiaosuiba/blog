---
layout:     post 
title:      "kube-public命名空间工作原理"
date:       2021-06-02
author:     "Chris Li"
tags:
    - kubernetes
    - code
categories: [ Tech ]
showtoc: false
---

kube-public中的资源可以被所有用户读取，本文探索了其实现方式和当前的现状
<!--more-->

kube-public命名空间工作原理
===================

在开发中，我们使用到了`kube-public`命名空间中的`cluster-info` configmap。按照官方文档的说法，`kube-public`是任何用户（包括未认证用户）都可以访问的，[官网的说明](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)如下：

> `kube-public` This namespace is created automatically and is readable by all users (including those not authenticated). This namespace is mostly reserved for cluster usage, in case that some resources should be visible and readable publicly throughout the whole cluster. The public aspect of this namespace is only a convention, not a requirement.

而我们在实际测试当中，却发现使用`kubeadm`创建的集群中，匿名用户仅能实现对`kube-public`中`cluster-info`对象的`get`操作，而对该命名空间的其余动作或者操作其余资源均会返回`403Forbidden`，这显然与官网文档说法有出入。那么`kube-public`命名空间到底怎么实现的呢？我们进行了一番探索。

首先，从kubernetes源码当中，进行一番搜索，找到两处可疑的代码： 
plugin/pkg/auth/authorizer/rbac/bootstrappolicy/namespace\_policy.go#L140
```golang
    addNamespaceRole(metav1.NamespacePublic, rbacv1.Role{
    		// role for the bootstrap signer to be able to write its configmap
    		ObjectMeta: metav1.ObjectMeta{Name: saRolePrefix + "bootstrap-signer"},
    		Rules: []rbacv1.PolicyRule{
    			rbacv1helpers.NewRule("get", "list", "watch").Groups(legacyGroup).Resources("configmaps").RuleOrDie(),
    			rbacv1helpers.NewRule("update").Groups(legacyGroup).Resources("configmaps").Names("cluster-info").RuleOrDie(),
    			eventsRule(),
    		},
    	})
    	addNamespaceRoleBinding(metav1.NamespacePublic,
    		rbacv1helpers.NewRoleBinding(saRolePrefix+"bootstrap-signer", metav1.NamespacePublic).SAs(metav1.NamespaceSystem, "bootstrap-signer").BindingOrDie())
```   

此处创建了一个角色`saRolePrefix + "bootstrap-signer"`，并和名为`bootstrap-signer`的`sa`进行绑定。看起来和匿名访问关系不大。

cmd/kubeadm/app/phases/bootstraptoken/clusterinfo/clusterinfo.go#L85
```golang
    // CreateClusterInfoRBACRules creates the RBAC rules for exposing the cluster-info ConfigMap in the kube-public namespace to unauthenticated users
    func CreateClusterInfoRBACRules(client clientset.Interface) error {
    	klog.V(1).Infoln("creating the RBAC rules for exposing the cluster-info ConfigMap in the kube-public namespace")
    	err := apiclient.CreateOrUpdateRole(client, &rbac.Role{
    		ObjectMeta: metav1.ObjectMeta{
    			Name:      BootstrapSignerClusterRoleName,
    			Namespace: metav1.NamespacePublic,
    		},
    		Rules: []rbac.PolicyRule{
    			{
    				Verbs:         []string{"get"},
    				APIGroups:     []string{""},
    				Resources:     []string{"configmaps"},
    				ResourceNames: []string{bootstrapapi.ConfigMapClusterInfo},
    			},
    		},
    	})
    	if err != nil {
    		return err
    	}
    
    	return apiclient.CreateOrUpdateRoleBinding(client, &rbac.RoleBinding{
    		ObjectMeta: metav1.ObjectMeta{
    			Name:      BootstrapSignerClusterRoleName,
    			Namespace: metav1.NamespacePublic,
    		},
    		RoleRef: rbac.RoleRef{
    			APIGroup: rbac.GroupName,
    			Kind:     "Role",
    			Name:     BootstrapSignerClusterRoleName,
    		},
    		Subjects: []rbac.Subject{
    			{
    				Kind: rbac.UserKind,
    				Name: user.Anonymous,
    			},
    		},
    	})
    }
```

这段代码首先创建了名为`BootstrapSignerClusterRoleName`也就是`kubeadm:bootstrap-signer-clusterinfo`的角色，该角色对`kube-public`中的`cluster-info` configmap具有`get`权限。然后创建了一个绑定，将上面的角色与`user.Anonymous`绑定起来，这样实现任意用户对`cluster-info`的`get`操作授权。同时也说明了为什么未授权用户不能读取其余自定义的资源。

一切都没有魔法，只是`kubeadm`初始化集群时进行了权限配置。再次看一遍官方的文档，其中有一句：`is only a convention`。这仅仅是一个约定，系统不会帮你实现这个约定，而是需要用户自己遵守并实现。