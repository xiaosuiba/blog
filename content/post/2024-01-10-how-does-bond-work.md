---
layout:     post 
title:      "[转载]bond是如何工作的"
date:       2024-01-10
author:     "Chris Li"
tags:
    - network
    - tips
categories: [ Tech ]
showtoc: false
---

随手记录linux bond工作原理。转载[Linux主机网卡绑定bond0详解](https://www.cnblogs.com/dachenzi/articles/6078219.html)。
<!--more-->

同组的小伙子问了我一个问题，bond0是怎么工作的，找了篇简洁的文章。

## 1 什么是bond
网卡bond是通过多张网卡绑定为一个逻辑网卡，实现本地网卡的冗余，带宽扩容和负载均衡，在生产场景中是一种常用的技术。Kernels 2.4.12及以后的版本均供bonding模块，以前的版本可以通过patch实现。可以通过以下命令确定内核是否支持 bonding：
```bash
[root@lixin network-scripts]# cat /boot/config-2.6.32-573.el6.x86_64 |grep -i bonding

CONFIG_BONDING=m
```

## 2 bond模式

bond的模式常用的有两种：

1. mode=0（balance-rr）

　　表示负载分担round-robin，并且是轮询的方式比如第一个包走eth0，第二个包走eth1，直到数据包发送完毕。

　　a) 优点：流量提高一倍

　　b) 缺点：需要接入交换机做端口聚合，否则可能无法使用。

 2. mode=1（active-backup）

　　表示主备模式，即同时只有1块网卡在工作。

　　a) 优点：冗余性高

　　b) 缺点：链路利用率低，两块网卡只有1块在工作

bond其他模式：

1.mode=2(balance-xor)(平衡策略)

    表示XOR Hash负载分担，和交换机的聚合强制不协商方式配合。（需要xmit_hash_policy，需要交换机配置port channel）

特点：基于指定的传输HASH策略传输数据包。缺省的策略是：(源MAC地址 XOR 目标MAC地址) % slave数量。其他的传输策略可以通过xmit_hash_policy选项指定，此模式提供负载平衡和容错能力

2. mode=3(broadcast)(广播策略)

    表示所有包从所有网络接口发出，这个不均衡，只有冗余机制，但过于浪费资源。此模式适用于金融行业，因为他们需要高可靠性的网络，不允许出现任何问题。需要和交换机的聚合强制不协商方式配合。

特点：在每个slave接口上传输每个数据包，此模式提供了容错能力

3.mode=4(802.3ad)(IEEE 802.3ad 动态链接聚合)

    表示支持802.3ad协议，和交换机的聚合LACP方式配合（需要xmit_hash_policy）.标准要求所有设备在聚合操作时，要在同样的速率和双工模式，而且，和除了balance-rr模式外的其它bonding负载均衡模式一样，任何连接都不能使用多于一个接口的带宽。

特点：创建一个聚合组，它们共享同样的速率和双工设定。根据802.3ad规范将多个slave工作在同一个激活的聚合体下。外出流量的slave选举是基于传输hash策略，该策略可以通过xmit_hash_policy选项从缺省的XOR策略改变到其他策略。需要注意的 是，并不是所有的传输策略都是802.3ad适应的，尤其考虑到在802.3ad标准43.2.4章节提及的包乱序问题。不同的实现可能会有不同的适应 性。

    必要条件：

    　- 条件1：ethtool支持获取每个slave的速率和双工设定

    　- 条件2：switch(交换机)支持IEEE 802.3ad Dynamic link aggregation

   　 - 条件3：大多数switch(交换机)需要经过特定配置才能支持802.3ad模式

4. mode=5(balance-tlb)(适配器传输负载均衡)

    是根据每个slave的负载情况选择slave进行发送，接收时使用当前轮到的slave。该模式要求slave接口的网络设备驱动有某种ethtool支持；而且ARP监控不可用。

特点：不需要任何特别的switch(交换机)支持的通道bonding。在每个slave上根据当前的负载（根据速度计算）分配外出流量。如果正在接受数据的slave出故障了，另一个slave接管失败的slave的MAC地址。

    必要条件：

    　- ethtool支持获取每个slave的速率

5.mode=6(balance-alb)(适配器适应性负载均衡)

    在5的tlb基础上增加了rlb(接收负载均衡receive load balance).不需要任何switch(交换机)的支持。接收负载均衡是通过ARP协商实现的.

特点：该模式包含了balance-tlb模式，同时加上针对IPV4流量的接收负载均衡(receive load balance, rlb)，而且不需要任何switch(交换机)的支持。接收负载均衡是通过ARP协商实现的。bonding驱动截获本机发送的ARP应答，并把源硬件地址改写为bond中某个slave的唯一硬件地址，从而使得不同的对端使用不同的硬件地址进行通信。来自服务器端的接收流量也会被均衡。当本机发送ARP请求时，bonding驱动把对端的IP信息从ARP包中复制并保存下来。当ARP应答从对端到达 时，bonding驱动把它的硬件地址提取出来，并发起一个ARP应答给bond中的某个slave。使用ARP协商进行负载均衡的一个问题是：每次广播 ARP请求时都会使用bond的硬件地址，因此对端学习到这个硬件地址后，接收流量将会全部流向当前的slave。这个问题可以通过给所有的对端发送更新 （ARP应答）来解决，应答中包含他们独一无二的硬件地址，从而导致流量重新分布。当新的slave加入到bond中时，或者某个未激活的slave重新 激活时，接收流量也要重新分布。接收的负载被顺序地分布（round robin）在bond中最高速的slave上当某个链路被重新接上，或者一个新的slave加入到bond中，接收流量在所有当前激活的slave中全部重新分配，通过使用指定的MAC地址给每个 client发起ARP应答。下面介绍的updelay参数必须被设置为某个大于等于switch(交换机)转发延时的值，从而保证发往对端的ARP应答 不会被switch(交换机)阻截。

    必要条件：

   　 - 条件1：ethtool支持获取每个slave的速率；

   　 - 条件2：底层驱动支持设置某个设备的硬件地址，从而使得总是有个slave(curr_active_slave)使用bond的硬件地址，同时保证每个bond 中的slave都有一个唯一的硬件地址。如果curr_active_slave出故障，它的硬件地址将会被新选出来的 curr_active_slave接管其实mod=6与mod=0的区别：mod=6，先把eth0流量占满，再占eth1，….ethX；而mod=0的话，会发现2个口的流量都很稳定，基本一样的带宽。而mod=6，会发现第一个口流量很高，第2个口只占了小部分流量。

bond模式小结：

    mode5和mode6不需要交换机端的设置，网卡能自动聚合。mode4需要支持802.3ad。mode0，mode2和mode3理论上需要静态聚合方式。

## 3 配置方式

### 3.1 使用NetworkManager
假设使用eno1和eno2创建bond0，模式为0。
```bash
nmcli connection add type bond ifname bond0 mod 0

nmcli connection add type cond-slave ifname eno1 master bond0
nmcli connection add type cond-slave ifname eno2 master bond0
```
然后重启network服务，使用ip a可查看到聚合口，切接口状态为up。

最后可手动配置bond0的配置文件：ifcfg-bond-bond0。如果存在ifcfg-eno1, ifcfg-eno2,，还需删除这些配置并重启network服务。

### 3.2 使用network配置

可以使用ifcfg文件方式直接配置bond：

物理网卡：
```bash
[root@lixin network-scripts]#cat ifcfg-eth0    

DEVICE=eth0

TYPE=Ethernet

ONBOOT=yes

BOOTPROTO=none

MASTER=bond0

SLAVE=yes         //可以没有此字段，就需要开机执行ifenslave bond0 eth0 eth1命令了。

[root@lixin network-scripts]#

[root@lixin network-scripts]#cat ifcfg-eth1    

DEVICE=eth1

TYPE=Ethernet

ONBOOT=yes

BOOTPROTO=none

MASTER=bond0

SLAVE=yes       
```

配置逻辑网卡：
```bash
[root@lixin network-scripts]#cat ifcfg-bond0     //需要我们手工创建

DEVICE=bond0

TYPE=Ethernet

ONBOOT=yes

BOOTPROTO=static

IPADDR=10.0.0.10

NETMASK=255.255.255.0

DNS2=4.4.4.4

GATEWAY=10.0.0.2

DNS1=10.0.0.2

[root@lixin network-scripts]#
```

重启network服务。