---
layout:     post 
title:      "手动注入cloud init并执行"
date:       2022-02-11
author:     "Chris Li"
tags:
    - cloudinit
    - code
categories: [ Tech ]
showtoc: false
---

本文介绍了如何在没有userdata能力的场景注入cloud init脚本并手动执行。
<!--more-->

最近遇到一个场景，我司虚拟化产品不支持userdata注入功能，但我们需要实现kubernetes cluster-api功能。由于kubeadmbootstrap机制使用了cloud-init作为初始化方式，为了完全利用开源能力，我们研究了如何手动注入userdata并手动运行cloud-init。

cloud-init是一个存在已久的云主机初始化机制，从AWS开始，几乎所有的公私有云厂商都利用cloud-init进行初始化。（然而我司就是个例外。。。。）

cloud-init支持一种名为NoCloud的provider，其官方解释如下：
> The data source NoCloud allows the user to provide user-data and meta-data to the instance without running a network service (or even without having a network at all).

也即是自行提供user-data和meta-data，不依赖元数据服务，这正是我们想要的。

我们基于如下方式使用NoCloud完成自定义的初始化：

1. 安装cloud-init，cloud-init在各个发行版的源中应该都存在，直接安装即可。
2. 禁用cloud-init service。由于我们没有userdata注入能力，所以必须要禁止cloud-init服务的自动运行，在后面注入userdata之后采取手动方式运行。

3. 禁用network config：
   ```bash
   root@host22:~# cat /etc/cloud/cloud.cfg.d/99_disable_network.cfg
   network:
     config: disabled
   ```
   
4. 配置NoCloud provider并使用自定义seed位置：

   ```bash
   root@host22:~# cat /etc/cloud/cloud.cfg.d/10_datasource.cfg
   #cloud-config
   
   datasource:
     NoCloud:
       seedfrom: /opt/seed/
   ```

   其中`/opt/seed/`是本地存放`meta-data`和`user-data`的路径

5. 创建seed文件夹并填写`meta-data`和`user-data`:

   ```bash
   root@host22:/opt/seed# pwd
   /opt/seed
   root@host22:/opt/seed# ls
   meta-data  user-data
   root@host22:/opt/seed# cat meta-data
   instance-id: instance01
   local-hostname: instance01
   dsmode: local
   root@host22:/opt/seed# cat user-data
   #cloud-config
   
   write_files:
     - path: /tmp/myfile
       owner: root:root
       permissions: '0640'
       content: "this is a placeholder"
   
   runcmd:
     - "echo hello > /tmp/helloworld"
   ```

6. 手动执行cloud-init:

   ```bash
   root@host22:/opt/seed# cloud-init clean --log
   root@host22:/opt/seed# cloud-init init --local
   Cloud-init v. 21.4-0ubuntu1~20.04.1 running 'init-local' at Fri, 11 Feb 2022 08:02:40 +0000. Up 368515.39 seconds.
   ......
   root@host22:/opt/seed# cloud-init modules -m config
   Cloud-init v. 21.4-0ubuntu1~20.04.1 running 'modules:config' at Fri, 11 Feb 2022 08:03:06 +0000. Up 368540.63 seconds.
   root@host22:/opt/seed# cloud-init modules -m final
   Cloud-init v. 21.4-0ubuntu1~20.04.1 running 'modules:final' at Fri, 11 Feb 2022 08:03:10 +0000. Up 368545.18 seconds.
   ```

   查看执行结果：

   ```bash
   root@host22:/opt/seed# cat /tmp/helloworld
   hello
   root@host22:/opt/seed# cat /tmp/myfile
   this is a placeholderroot
   ```

可以看到我们自定义的write_files和runcmd已经成功运行了，使用此方式，可以自定义userdata的存放位置并选择cloud-init的运行时机。
