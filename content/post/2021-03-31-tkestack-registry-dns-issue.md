---
layout:     post 
title:      "TKEStack组件不能访问registry域名问题"
description:   ""
date:       2021-03-31
author:     "Chris Li"
tags:
    - kubernetes
    - code
    - TKEStack
categories: [ Tech ]
showtoc: false
---
本文从探索了TKEStack 1.5版本中TKEStack组件不能访问registry域名的原因，并给出解决办法。
<!--more-->

TKEStack需要配置registry域名，默认为`default.registry.tke.com`，application组件将使用该域名解析到`tke-registry-api`服务（或者直接解析到gateway也可以）。

在v1.5版本中，Coredns默认没有配置对该域名的处理，导致用户只能通过Coredns的forward插件，使用外部的DNS做处理；或者修改Coredns配置文件。

很高兴看到在v1.6.0版本中，该问题得到了解决，Corefile中添加了如下配置：
```
 ………………
 rewrite name default.registry.tke.com tke-registry-api.tke.svc.cluster.local
```
官方对于rewrite插件的解释如下：
> Rewrites are invisible to the client. There are simple rewrites (fast) and complex rewrites (slower), but they’re powerful enough to accommodate most dynamic back-end applications.

也即将`default.registry.tke.com`rewrite到`tke-registry-api.tke.svc.cluster.local`，也即tke-registry-api地址。

相关pr: [feat(registry): add registry's domain names to coredns by tenant](https://github.com/tkestack/tke/pull/702)