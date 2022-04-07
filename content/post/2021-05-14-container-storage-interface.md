---
layout:     post 
title:      "Kubernet CSI Volume 插件设计文档(译)"
date:       2021-05-14
author:     "Chris Li"
tags:
    - kubernetes
    - code
categories: [ Tech ]
showtoc: false
---

本文是对[CSI Volume Plugins in Kubernetes Design Doc](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/container-storage-interface.md)的翻译
<!--more-->

_**状态**_ 挂起

_**版本:**_ Alpha

_**作者：**_ Saad Ali ([@saad-ali](https://github.com/saad-ali), [saadali@google.com](mailto:saadali@google.com))

_本文草稿[在此](https://docs.google.com/document/d/10GDyPWbFE5tQunKMlTXbcWysUttMFhBFJRX8ntaS_4Y/edit?usp=sharing)._

术语
--

术语

定义

容器存储接口（Container Storage Interface, CSI）

一个尝试建立行业标准接口的规范，容器编排系统（CO）可以使用该接口将任意存储系统暴露于其容器化工作负载中

树内（in-tree）

代码位于Kubernetes核心代码库中

树外（out-of-tree）

代码位于Kubernetes核心代码库外。

CSI 卷插件（CSI Volume Plugin）

一种新的、树内的卷插件，作为一种适配器，允许在Kubernetes中使用其余树外的第三方CSI卷驱动。

CSI卷驱动（CSI Volume Driver）

一个树外的卷插件兼容实现，可以在Kubernetes中通过CSI卷插件来使用。

背景和动机
-----

当前的Kubernetes卷插件为“树内”，表明他们将和Kubernetes核心二进制一起链接、编译、构建和发布。添加一种新的存储系统到Kubernetes中（一种卷插件）需要将代码检入Kubernetes核心代码库中。许多原因导致这样做并不理想：

1.  卷插件开发依赖Kubernetes发行版并与其紧耦合。
2.  Kubernetes开发者/社区负责所有卷插件的测试和维护，而不仅仅是一个稳定的插件API。
3.  卷插件中的缺陷可能使Kubernetes组件崩溃，而不仅仅是插件本身。
4.  卷插件对Kubernetes组件（kubelet 和 kube-controller-manager）具有完全权限.
5.  插件开发者将被迫开源插件代码，而不能选择仅仅发布一个二进制。

现有的[Flex Volume](/contributors/devel/sig-storage/flexvolume.md)插件尝试通过暴露一个基于可执行文件的挂载/卸载/附加/分离（mount/unmount/attach/detach） API来解决这个问题。虽然他允许第三方存储厂商编写树外的驱动，但仍然要求有访问node和master节点机器的root文件系统的权限，以部署第三方驱动文件。

而且，这并没有解决树内卷插件的另一个痛点：依赖。卷驱动往往有很多外部需求：例如依赖挂载和文件系统工具。这些插件假设底层宿主机上的依赖已经存在，但这通常并非事实。而且安装他们也需要直接访问机器。目前已经有一些希望解决树内卷插件问题的努力正在进行中，例如https://github.com/kubernetes/community/pull/589。但是，使卷插件完全容器化将使得依赖管理更加容易。

虽然Kubernetes一直在处理这些问题，泛存储社区也一直在探讨如何使他们的存储系统在不同容器编排系统（CO）中可用的碎片化story。存储厂商只能选择为不同的容器编排系统提供多个卷驱动，或者选择不支持某些容器编排系统。

容器存储接口（Container Storage Interface，CSI）是来自不同容器编排系统社区成员之间合作的规范，这些成员包括Kubernetes、Mesos、Cloud Foundry和Docker。该接口的目标是为CO建立一种标准化机制，以将任意存储系统暴露于其容器化工作负载中。

存储供应商采用该接口的主要动机是希望以尽可能少的工作使他们的系统对更多的用户可用。CO使用该接口的主要动机是投资一种机制，使他们的用户可以使用更多的存储系统。此外，对于Kubernetes而言，采用CSI将带来将卷插件移出树内并支持卷插件容器化的额外好处。

### 链接

*   [容器存储接口（Container Storage Interface，CSI）规范](https://github.com/container-storage-interface/spec/blob/master/spec.md)

目的
--

本文的目的是记录在Kubernetes中启用CSI兼容插件（CSI卷驱动程序）的所有需求。

目标
--

*   定义Kubernetes API，以便与任意第三方CSI卷驱动程序进行交互。
*   定义一种机制，Kubernetes master和node组件将通过该机制与任意的第三方CSI卷驱动程序安全地进行通信。
*   定义一种机制，Kubernetes master和node组件将通过该机制发现并注册在Kubernetes上部署的任意第三方CSI卷驱动程序。
*   为兼容Kubernetes的第三方CSI卷驱动程序的打包要求提供建议。
*   为部署在Kubernetes集群上与之兼容的第三方CSI卷驱动程序的部署过程提供建议。

非目标
---

*   替换 \[Flex卷插件\]
    *   Flex卷插件将作为一种基于可执行文件机制，可以创建“树外”卷插件的存在。
    *   由于存在Flex驱动程序并依赖Flex接口，因此它将继续被稳定的API支持。
    *   CSI卷插件将于Flex卷插件共存。

设计概述
----

为了支持CSI兼容卷插件，Kubernetes中将引入一个新的树内 CSI卷插件。这个新的卷插件将成为Kubernetes用户（应用程序开发人员和集群管理员）与外部CSI卷驱动程序进行交互的机制。

新的树内CSI卷插件的`SetUp`/`TearDown`调用将通过节点计算机上的unix域套接字直接调用`NodePublishVolume`和`NodeUnpublishVolume` CSI RPC。

`制备`/`删除`和`附加`/`分离`操作必须由某些外部组件处理，该组件代表CSI卷驱动程序监听Kubernetes API，并恰当的调用CSI RPC。

为了简化集成，Kubernetes团队将提供一个容器，该容器可捕获所有Kubernetes特定的逻辑，并充当第三方容器化CSI卷驱动程序和Kubernetes之间的适配器（每个CSI驱动程序部署都具有其自己的适配器实例）。

设计细节
----

### 第三方CSI插件驱动

Kubernetes将尽量减少CSI卷驱动的打包和部署的说明。在Kubernetes中启用任意一个外部CSI兼容存储驱动的需求是使用上文提及的“通信通道”。

本文推荐了一种用于在Kubernetes上部署任意容器化CSI驱动程序的标准机制。存储提供商可以使用它来简化在Kubernetes上容器化部署CSI兼容卷驱动程序（请参阅下面的“在Kubernetes上部署CSI驱动程序的推荐机制”部分）。但是，此机制仅作为推荐，而不是严格的必选项。

### 通信通道

#### Kubelet到CSI驱动的通信

Kubelet（负责挂载和卸载）将通过一个Unix域套接字与一个运行在相同主机上的“CSI卷驱动”进行通信。

CSI卷驱动应该在主机节点下列路径中创建一个套接字：`/var/lib/kubelet/plugins/[SanitizedCSIDriverName]/csi.sock`。在alpha版本中，kubelet将假设这是与CSI卷驱动进行交谈Unix域套接字。在beta实现中，我们可以考虑使用[设备插件Unix域套接字](/contributors/design-proposals/resource-management/device-plugin.md#unix-socket)机制来向kubelet注册Unix域套接字。这个机制将被扩展以同时独立支持CSI卷插件和设备插件。

“Sanitized CSIDriverName”是不包含危险字符的CSI驱动程序名称，并可以用作annotation名称。可以遵循与[volume plugins](https://git.k8s.io/utils/strings/escape.go#L28)相同的模式。太长或太丑陋的驱动程序名称都可以被拒绝，这种情况下本文档中描述的所有组件都将报告错误，并且不会与此CSI驱动程序通信。确切的命名方法属于实施细节（在最坏的情况下为SHA）。

在初始化外部“CSI卷驱动程序”时，kubelet必须调用CSI方法`NodeGetInfo`以获取从Kubernetes节点名称到CSI驱动程序NodeID以及相关的`accessible_topology`的映射。它必须：

*   使用来自accessible\_topology的拓扑键（topology keys）和NodeID为节点创建/更新CSINodeInfo对象实例。
    
    *   这将使发出`ControllerPublishVolume`调用的组件能够使用`CSINodeInfo`作为从集群节点ID到存储节点ID的映射。
    *   这将使发出`CreateVolume`的组件能够重建`accessible_topology`并提供可从特定节点访问的卷。
    *   每个驱动程序必须完全覆盖其先前版本的NodeID和拓扑键（如果存在）。
    *   如果`NodeGetInfo`调用失败，则kubelet必须删除该驱动程序的所有以前的NodeID和拓扑键。
    *   实施kubelet插件注销机制后，请在注销驱动程序时删除NodeID和拓扑键。
*   使用CSI驱动程序的NodeID更新Node API对象的`csi.volume.kubernetes.io/nodeid` annotation。Annotation的值是一个JSON Blob，其中包含每个CSI驱动程序的键/值对。例如：
    
        csi.volume.kubernetes.io/nodeid: "{ \"driver1\": \"name1\", \"driver2\": \"name2\" }
        
    
    _该annotation已弃用，并将根据弃用政策（弃用后1年）将其删除。TODO：标注启用的date._
    
    *   如果`NodeGetInfo`调用失败，则kubelet必须删除该驱动程序的所有以前的NodeID。
    *   实施kubelet插件注销机制后，请在注销驱动程序时删除NodeID和拓扑键。
*   以`accessible_topology`作为标签创建/更新Node API对象。 标签格式没有硬性限制，但是对于推荐设置使用的格式，请参考[节点对象中的拓扑表示](#topology-representation-in-node-objects)。
    

为了简化容器化部署外部CSI卷驱动程序，Kubernetes团队将提供一个辅助工具“ Kubernetes CSI Helper”容器，该容器可以管理Unix域套接字注册和NodeId初始化。下面的“在Kubernetes上部署CSI驱动程序的建议机制”部分对此进行了详细说明。

名为`CSINodeInfo`的新API对象将定义如下：

    // CSINodeInfo包含有关节点上安装的所有CSI驱动程序的状态的信息
    type CSINodeInfo struct {
        metav1.TypeMeta
        // ObjectMeta.Name 必须是一个节点名
        metav1.ObjectMeta
    
        // 在节点上运行的CSI驱动程序及其属性的列表。
        CSIDrivers []CSIDriverInfo
    }
    
    // 有关节点上安装的一个CSI驱动程序的信息。
    type CSIDriverInfo struct {
        // CSI驱动名称
        Name string
    
        // 从驱动程序的角度来看的节点ID。
        NodeID string
    
        // 驱动程序在节点上报告的拓扑键。
        TopologyKeys []string
    }
    

选择使用一个新对象类型CSINodeInfo而不是Node.Status字段，是因为Node已经足够大了，再增加其大小将带来问题。`CSINodeInfo`是由TODO（jsafrane）在集群启动时安装的CRD，并在`kubernetes/kubernetes/pkg/apis/storage-csi/v1alpha1/types.go`中定义，因此会自动生成k8s.io/client-go和k8s.io/ api。如果未安装CRD，则`CSINodeInfo`所有用户都会容忍，并对任何需要他们的事物进行指数退避重试并恰当的报告错误。尤其是kubelet，在缺少CRD的情况下也能够履行其通常的职责。

每个节点必须有零个或一个`CSINodeInfo`实例。这通过`CSINodeInfo.Name == Node.Name`进行保证。TODO：如何对此进行验证？每个`CSINodeInfo`被对应的节点“拥有”以进行垃圾收集。

#### Master到CSI驱动的通信

由于CSI卷驱动程序代码被认为是不受信任的，因此它可能不被允许在master上运行。因此，Kube控制器管理器（负责创建，删除，附加和分离）不能通过Unix域套接字与“CSI卷驱动”容器进行通信，而需要通过Kubernetes API来完成通信过程。

更具体地说，某些外部组件必须代表外部CSI卷驱动程序监听Kubernetes API并对其触发适当的操作。这解决了发现和保护kube-controller-manager与CSI卷驱动器之间的通道的问题。

为了在Kubernetes上轻松部署外部容器化CSI卷驱动程序同时使其不感知Kubernetes，Kubernetes将提供一个辅助工具“Kubernetes to CSI”代理容器，该容器将监听Kubernetes API并触发“CSI卷驱动程序”容器进行适当的操作“ 。下面的“在Kubernetes上部署CSI驱动程序的建议机制”部分对此进行了详细说明。

代表外部CSI卷驱动程序监听Kubernetes API的外部组件必须处理制备、删除、附件和分离操作。

##### 制备和删除

制备和删除操作使用了[现有的provisioner机制](https://github.com/kubernetes-incubator/external-storage/tree/master/docs)，在这个过程中，代表外部CSI卷驱动程序监听Kubernetes API的外部组件表现得像一个provisioner。

简而言之，为了动态地制备新的CSI卷，集群管理员将创建一个`StorageClass`，其provisioner与作为CSI卷驱动处理制备请求的外部provisioner的名称相对应。

为了制备新的CSI卷，终端用户将引用该`StorageClass`创建一个`PersistentVolumeClaim`对象。外部provisioner将对PVC的创建做出反应，并针对CSI卷驱动程序发出`CreateVolume`调用以制备该卷。`CreateVolume`名称将自动生成，就像其他动态预配置的卷一样。`CreateVolume`的容量将取自`PersistentVolumeClaim`对象。`CreateVolume`参数将从`StorageClass`参数传递（对Kubernetes不透明）。

如果`PersistentVolumeClaim`具有`volume.alpha.kubernetes.io/selected-node` annotation（仅当在`StorageClass`中启用了延迟卷绑定时才添加），provisioner将从相应的`CSINodeInfo`实例中获取相关的拓扑键，并从Node标签获取拓扑值，然后使用它们在 `CreateVolume()`请求中生成首选拓扑。如果未设置annotation，则不会指定首选拓扑（除非PVC遵循StatefulSet命名格式，这将在本节后面讨论）。`StorageClass`中的的`AllowedTopologies`将作为必须拓扑传递。如果未指定`AllowedTopologies`，provisioner将在整个集群中传递一组聚合的拓扑值作为必需的拓扑。

为了执行此拓扑聚合，外部provisioner将缓存所有现有的Node对象。为了防止受损的节点影响制备过程，它将选择单个节点作为键的真实来源，而不是依赖节点对象存储在`CSINodeInfo`中的键。对于晚绑定的PVC，将使用选择的节点；否则将选择一个随机节点。然后，provisioner将遍历所有包含来自驱动程序的节点ID的缓存节点，并使用这些键聚合标签。请注意，如果整个集群中的拓扑键不同，则仅考虑与所选节点的拓扑键匹配的节点子集进行配置。

为了生成首选拓扑，外部provisioner将在 `CreateVolume()` 调用中为首选拓扑生成N个段，其中N是必需拓扑的大小。包含多个段则可以支持跨多个拓扑段可用的卷。所选节点中的拓扑段将始终是首选拓扑中的第一个。所有其他段都是对其余必要拓扑的一些重新排序，以便在给定必要拓扑（或其任意任意重新排序）和选定节点的情况下，可以保证首选拓扑的集合始终相同。

如果设置了即时卷绑定模式，并且PVC遵循StatefulSet命名格式，则provisioner将根据PVC名称从必需拓扑中选择一个段作为首选拓扑中的第一段，以确保StatefulSet的卷在拓扑上均匀分布。该逻辑类似于GCE Persistent Disk provisioner中的名称哈希逻辑。优选拓扑中的其他段以与上述相同的方式排序。此功能将在建议的部署方法的一部分中提供的外部provisioner中进行标记。

一旦操作成功完成，外部provisioner就会使用 `CreateVolume` 响应中返回的信息创建一个`PersistentVolume`对象来表示该卷。返回的卷的拓扑将转换为`PersistentVolume`的`NodeAffinity`字段。然后，`PersistentVolume`对象将绑定到`PersistentVolumeClaim`并可供使用。

拓扑键/值对的格式由用户定义，并且必须在以下位置匹配：

*   `Node`拓扑标签
*   `PersistentVolume`的`NodeAffinity`字段
*   `StorageClass`的`AllowedTopologies`字段 当`StorageClass`启用了延迟卷绑定时，调度程序将通过以下方式使用`Node`的拓扑信息：
    1.  在动态制备期间，调度程序通过将每个`Node`的拓扑与`StorageClass`中的`AllowedTopologies`进行比较，为provisioner选择一个候选节点。
    2.  在卷绑定和Pod调度期间，调度程序通过比较`Node`拓扑与`PersistentVolume`中的`VolumeNodeAffinity`来为Pod选择一个候选节点。

您可以在[拓扑感知的卷调度设计文档](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/volume-topology-scheduling.md)中找到更详细的描述。有关建议的部署方法使用的格式，请参见\[节点对象中的拓扑表示\]\](#topology-representation-in-node-objects)。

要删除CSI卷，终端用户需要删除相应的`PersistentVolumeClaim`对象。外部provisioner将对PVC的删除做出反应，并根据其回收策略，对CSI卷驱动程序命令发出`DeleteVolume`调用以删除该卷。然后它将删除 `PersistentVolume`对象。

##### 附加和分离

附加/分离操作也必须由外部组件（“attacher”）处理。attacher代表外部CSI卷驱动程序监听Kubernetes API中的新`VolumeAttachment`对象（定义如下），并触发对CSI卷驱动程序的适当调用以附加该卷。attacher必须监听 `VolumeAttachment`对象，并将其标记为已附加，即使底层CSI驱动程序不支持`ControllerPublishVolume`调用，因为Kubernetes并不知道细节。

更具体地说，外部“attacher”必须代表外部CSI卷驱动程序监听Kubernetes API，以处理附加/分离请求。

一旦满足以下条件，external-attacher应针对CSI卷驱动程序调用`ControllerPublishVolume`以将卷附加到指定的节点：

1.  Kubernetes 附加/分离控制器创建了一个新的`VolumeAttachment` Kubernetes API对象。
2.  该对象的`VolumeAttachment.Spec.Attacher`值与外部attacher对应。
3.  `VolumeAttachment.Status.Attached`还未设置为true。
4.  *   存在名称与`VolumeAttachment.Spec.NodeName`匹配的Kubernetes Node API对象，并且该对象包含`csi.volume.kubernetes.io/nodeid`annotation。该annotation包含一个JSON Blob，他是一个键/值对列表，其中的键之一与CSI卷驱动程序名称相对应，并且值是该驱动程序的NodeID。这个NodeId映射可以在`ControllerPublishVolume`调用中取出并使用。
    *   或者，存在名称与 `VolumeAttachment.Spec.NodeName`匹配的`CSINodeInfo` API对象，并且该对象包含用于CSI卷驱动程序的`CSIDriverInfo`。`CSIDriverInfo`包含用于`ControllerPublishVolume`调用的NodeID。
5.  未设置 `VolumeAttachment.Metadata.DeletionTimestamp`。

在开始`ControllerPublishVolume`操作之前，external-attacher应将以下finalizers添加到以下Kubernetes API对象中：

*   添加到`VolumeAttachment` 上，以便在删除对象时，external-attacher有机会首先分离该卷。一旦将卷从节点上完全分离，外部attacher将删除此finalizer。
    
*   附加`VolumeAttachment`引用的`PersistentVolume`，因此在该卷被附加时无法删除PV。外部attacher需要来自PV的信息来执行分离操作。一旦所有引用PV的`VolumeAttachment`对象都被删除，即卷从所有节点分离，则attacher将删除finalizer。
    

如果操作成功完成，则external-attacher将：

1.  将`VolumeAttachment.Status.Attached`字段设置为true表示已附加该卷。
2.  使用返回的`PublishVolumeInfo`的内容更新`VolumeAttachment.Status.AttachmentMetadata`字段。
3.  清除`VolumeAttachment.Status.AttachError`字段。

如果操作失败，external-attacher将会：

1.  确保`VolumeAttachment.Status.Attached`字段仍为false，以指示未附加卷。
2.  设置详细说明错误的`VolumeAttachment.Status.AttachError`字段。
3.  针对与`VolumeAttachment`对象相关联的Kubernetes API创建一个事件，以通知用户出了什么问题。

external-attacher可以实施自己的错误恢复策略，并在上面指定的附加条件有效的情况下重试。强烈建议external-attacher对重试执行指数退避策略。

分离操作将通过删除`VolumeAttachment` Kubernetes API对象来触发。由于external-attacher将为`VolumeAttachment` Kubernetes API对象添加一个finalizer，因此在删除该对象之前将等待来自external-attacher的确认。

一旦满足以下所有条件，则external-attacher应针对CSI卷驱动程序调用`ControllerUnpublishVolume`，以将卷与指定节点分离：

1.  将`VolumeAttachment` Kubernetes API对象标记为删除：`VolumeAttachment.metadata.deletionTimestamp`字段的值已设置。

如果操作成功完成，则external-attacher将：

1.  从`VolumeAttachment`对象上的finalizer列表中删除其finalizer，以允许继续进行删除操作。

如果操作失败，external-attacher将会：

1.  确保 `VolumeAttachment.Status.Attached`字段保持为true，以指示尚未分离卷。
2.  设置`VolumeAttachment.Status.DetachError`字段以详细说明错误。
3.  针对与`VolumeAttachment`对象相关联的Kubernetes API创建一个事件，以通知用户出了什么问题。

名为`VolumeAttachment` 的新API对象定义如下：

    // VolumeAttachment用于捕获从特定节点附加或分离特定卷的意图
    //
    // VolumeAttachment对象是non-namespaced的。
    type VolumeAttachment struct {
    	metav1.TypeMeta `json:",inline"`
    
    	// 标准object metadata.
    	// 更多信息：https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    	// +optional
    	metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`
    
    	// 所需的附加/分离卷行为的规格。
    	// 由Kubernetes系统填充。
    	Spec VolumeAttachmentSpec `json:"spec" protobuf:"bytes,2,opt,name=spec"`
    
    	// VolumeAttachment请求的状态。
    	// 由完成附加或分离操作的实体（即external-attacher）填充。
    	// +optional
    	Status VolumeAttachmentStatus `json:"status,omitempty" protobuf:"bytes,3,opt,name=status"`
    }
    
    // VolumeAttachment请求的规格。
    type VolumeAttachmentSpec struct {
    	// Attacher 指明必须处理此请求的卷驱动器的名称。	// 这是GetPluginName()返回的名称，必须是
    	// 与StorageClass.Provisioner相同。
    	Attacher string `json:"attacher" protobuf:"bytes,1,opt,name=attacher"`
    
    	// AttachedVolumeSource代表需要附加的卷。
    	VolumeSource AttachedVolumeSource `json:"volumeSource" protobuf:"bytes,2,opt,name=volumeSource"`
    
    	// 卷需要附加到的Kubernetes节点名称。
    	NodeName string `json:"nodeName" protobuf:"bytes,3,opt,name=nodeName"`
    }
    
    // VolumeAttachmentSource表示需要被附加的卷。
    // 目前只有PersistentVolumes可以通过外部附加器附加，
    // 未来我们还可以允许附加pod内联卷。
    // 仅能设置一个成员
    type AttachedVolumeSource struct {
    	// 要附加的持久卷名称
    	// +optional
    	PersistentVolumeName *string `json:"persistentVolumeName,omitempty" protobuf:"bytes,1,opt,name=persistentVolumeName"`
    
    	//  *VolumeSource的占位符，以容纳Pod中的内联卷。
    }
    
    // VolumeAttachment请求的状态。
    type VolumeAttachmentStatus struct {
    	// 表明卷被成功附加。
    	// 这个字段只能被完成附加动作的实体设置，也即外部附加器。
    	Attached bool `json:"attached" protobuf:"varint,1,opt,name=attached"`
    
    	// 成功执行附加后，该字段将填充附加操作返回的所有信息，这些信息必须传递到后续的WaitForAttach或Mount调用中。
    	// 这个字段只能被完成附加动作的实体设置，也即外部附加器。
    	// +optional
    	AttachmentMetadata map[string]string `json:"attachmentMetadata,omitempty" protobuf:"bytes,2,rep,name=attachmentMetadata"`
    
    	// The most recent error encountered during attach operation, if any.
    	// 这个字段只能被完成附加动作的实体设置，也即外部附加器。
    	// +optional
        AttachError *VolumeError `json:"attachError,omitempty" protobuf:"bytes,3,opt,name=attachError,casttype=VolumeError"`
    
    	// 分离操作期间遇到的最新错误（如果有）。
    	//  这个字段只能被完成分离动作的实体设置，也即外部附加器。
    	// +optional
    	DetachError *VolumeError `json:"detachError,omitempty" protobuf:"bytes,4,opt,name=detachError,casttype=VolumeError"`
    }
    
    // 捕获在卷操作期间遇到的错误。
    type VolumeError struct {
    	// 遇到错误的时间。
    	// +optional
    	Time metav1.Time `json:"time,omitempty" protobuf:"bytes,1,opt,name=time"`
    
    	// 详细描述在附加或分离操作期间遇到的错误的字符串。
    	// 该字符串可能已被记录，因此它不应包含敏感信息。
    	// +optional
    	Message string `json:"message,omitempty" protobuf:"bytes,2,opt,name=message"`
    }
    
    

### Kubernetes 树内 CSI卷插件

新的树内Kubernetes CSI卷插件将包含Kubernetes与任意树外第三方CSI兼容卷驱动程序进行通信所需的所有逻辑。

现有的Kubernetes卷组件（附加/分离控制器、PVC/PV控制器、Kubelet卷管理器） 将向对待现有的树内卷插件一样处理这个CSI卷插件的生命周期操作（包括触发卷的创建/删除、附加/分离以及挂载/卸载）。

#### 拟议的API

新的`CSIPersistentVolumeSource`对象将被添加到Kubernetes API。它将是现有`PersistentVolumeSource`对象的一部分，因此只能通过PersistentVolume使用。Pod不允许在没有`PersistentVolumeClaim`的情况下直接引用CSI卷。

    type CSIPersistentVolumeSource struct {
      // Driver是用于该卷的驱动程序的名称。
      // 必须。
      Driver string `json:"driver" protobuf:"bytes,1,opt,name=driver"`
    
      // VolumeHandle是CSI卷返回的唯一卷名
      // 插件的CreateVolume，后续所有调用中的卷都将引用。
      VolumeHandle string `json:"volumeHandle" protobuf:"bytes,2,opt,name=volumeHandle"`
    
      // 可选： 传递给ControllerPublishVolumeRequest的值。
      // 
    默认为false（读/写）。
      // +optional
      ReadOnly bool `json:"readOnly,omitempty" protobuf:"varint,5,opt,name=readOnly"`
    }
    

#### 内部接口

树内 CSI卷插件将实现以下内部Kubernetes卷接口：

1.  `VolumePlugin`
    *   从特定路径挂载/卸载一个卷
2.  `AttachableVolumePlugin`
    *   从给定节点附加/分离一个卷。

值得注意的是，`ProvisionableVolumePlugin`和`DeletableVolumePlugin`没有实现，这是因为CSI卷的制备和删除是由外部设置程序处理的。

#### 挂载和卸载

树内卷插件的SetUp和TearDown方法将通过Unix域套接字触发`NodePublishVolume`和`NodeUnpublishVolume` CSI调用。Kubernetes将生成一个唯一的target\_path（每个卷每个容器唯一），并通过`NodePublishVolume`传递给CSI插件以挂载该卷。成功完成`NodeUnpublishVolume`调用后（一旦卷卸载已被验证），Kubernetes将删除该目录。

Kubernetes卷子系统目前不支持块（仅文件），因此对于Alpha版本，Kubernetes CSI卷插件将仅支持文件。

#### 附加和分离

作为master上kube-controller-manager二进制文件的一部分运行的附加/分离控制器，决定何时必须从特定节点附加或分离CSI卷。

当控制器决定附加CSI卷时，它将调用树内CSI卷插件的attach方法。树内CSI卷插件的attach方法将执行以下操作：

1.  创建一个新的`VolumeAttachment`对象（在“通信通道”部分中定义）以附加该卷。
    *   `VolumeAttachment`对象的名称为`pv-<SHA256(PVName+NodeName)>`.
        *   设置`pv-`前缀是为了将来启用内联卷时能设置其他的前缀格式。
        *   SHA256散列是为了减少PVName和NodeName字符串的长度，他们都可以是允许的最大名称长度（SHA256的十六进制表示形式为64个字符）。
        *   `PVName`是附加的`PersistentVolume`的`PV.name`。
        *   `NodeName`是卷应附加到的节点的`Node.name`。
    *   如果已经存在具有相应名称的`VolumeAttachment`对象，则树内卷插件将按照下面的定义简单地开始对其进行轮询。该对象未被修改；只有外部代理才能更改状态字段；外部连接器负责其自己的重试和错误处理逻辑。
2.  轮询`VolumeAttachment`对象，等待以下条件之一：
    *   `VolumeAttachment.Status.Attached`字段变为`true`。
        *   操作成功完成。
    *   `VolumeAttachment.Status.AttachError`字段中设置了错误。
        *   该操作以特定的错误终止。
    *   操作超时。
        *   该操作因超时错误而终止。
    *   设置了`VolumeAttachment.DeletionTimestamp`。
        *   一个错误终止了该操作，这个错误指示分离操作正在进行中。
        *   不能信任`VolumeAttachment.Status.Attached`值。在创建对象的新实例之前，连接/分离控制器必须等到外部连接器删除了该对象。

当控制器决定分离CSI卷时，它将调用树内CSI卷插件的分离方法。树内CSI卷插件的分离方法将执行以下操作：

1.  删除相应的`VolumeAttachment`对象（在“通信通道”部分中定义），以指示应分离该卷。
2.  轮询`VolumeAttachment`对象，等待以下条件之一：
    *   `VolumeAttachment.Status.Attached`字段变为false。
        *   操作成功完成。
    *   在`VolumeAttachment.Status.DetachError`字段中设置的错误。
        *   该操作以特定的错误终止。
    *   对象不再存在。
        *   操作成功完成。
    *   操作超时。
        *   该操作因超时错误而终止。

### 在Kubernetes上部署CSI驱动程序的推荐机制

尽管Kubernetes并未规定CSI卷驱动程序的打包方式，但它提供以下建议以简化在Kubernetes上容器化CSI卷驱动程序的部署。

![推荐的CSI部署方式图](https://raw.githubusercontent.com/kubernetes/community/master/contributors/design-proposals/storage/container-storage-interface_diagram1.png)

要部署容器化的第三方CSI卷驱动程序，建议存储供应商：

*   创建一个`CSI卷驱动程序`容器，该容器实现卷插件的行为并通过CSI规范（包括Controller，Node和Identity服务）中定义的unix域套接字公开gRPC接口。
    
*   将`CSI卷驱动程序`容器与Kubernetes团队将提供的帮助程序容器（external-attacher, external-provisioner, node-driver-registrar, cluster-driver-registrar, external-resizer, external-snapshotter, livenessprobe）捆绑在一起，帮助器容器将协助`CSI卷驱动器`容器与Kubernetes系统进行交互。更具体地说，创建以下Kubernetes对象：
    
    *   一个具有以下内容的`StatefulSet`或`Deployment`（取决于用户的需求;请参阅[集群级部署](#cluster-level-deployment)） 以便与Kubernetes控制器的通信：
        
    *   下列容器
        
        *   由存储供应商创建的“CSI卷驱动程序”容器。
        *   Kubernetes团队提供的容器（所有容器都是可选的）：
            *   `cluster-driver-registrar`（有关何时需要容器的信息，请参见`cluster-driver-registrar`存储库中的README文件）
            *   `external-provisioner`（制备/删除操作所需）
            *   `external-attacher`（进行附加/分离操作所必需。如果您想跳过附加步骤，除了省略该容器外，还必须在Kubernetes中启用CSISkipAttach功能）
            *   `external-resizer`（调整大小操作所需）
            *   `external-snapshotter`（卷级快照操作所需）
            *   `livenessprobe`
    *   以下卷：
        
        *   一个`emptyDir`卷
            *   由所有容器挂载（包括“ CSI卷驱动程序”）。
            *   “CSI卷驱动程序”容器应在此目录中创建其Unix域套接字，以启用与Kubernetes帮助器容器的通信。
    *   一个`DaemonSet`（以便与kubelet的每个实例进行通信）包含：
        
        *   下列容器
            *   由存储供应商创建的“CSI卷驱动程序”容器。
            *   Kubernetes团队提供的容器：
                *   `node-driver-registrar`\-负责向kubelet注册unix域套接字。
                *   `livenessprobe` （可选）
        *   以下卷：
            *   `hostpath`卷
                *   暴露主机上的`/var/lib/kubelet/plugins_registry`。
                *   仅在`node-driver-registrar`容器的`/registration`目录挂载
                *   `node-driver-registrar`将使用此unix域套接字向kubelet注册CSI驱动程序的unix域套接字。
            *   `hostpath`卷
                *   暴露主机的`/var/lib/kubelet/`目录。
                *   仅在 “CSI volume driver”的`/var/lib/kubelet/`目录挂载
                *   确保启用了[双向挂载传播](https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation) ，以便将此容器内的所有挂载设置传播回主机。
            *   `hostpath`卷
                *   使用`hostPath.type ="DirectoryOrCreate"`暴露主机上的`/var/lib/kubelet/plugins/[SanitizedCSIDriverName]/`。
                *   在`CSI卷驱动器`容器内的CSI gRPC套接字创建路径上安装。
                *   这是Kubelet与`CSI卷驱动程序`容器（gRPC over UDS）之间进行通信的主要方式。
*   让集群管理员部署上述`StatefulSet`和`DaemonSet`以在其Kubernetes集群中添加对存储系统的支持。
    

或者，可以通过将所有组件（包括`external-provisioner`和 `external-attacher` ）放在同一pod（DaemonSet）中来简化部署。但是，这样做会消耗更多资源，并且需要在`external-provisioner`和 `external-attacher` 组件中使用领导者选举协议 (参考https://git.k8s.io/contrib/election) 。

Kubernetes提供的容器在[GitHub kubernetes-csi组织](https://github.com/kubernetes-csi)中维护。

#### 集群级部署

集群级部署中的容器可以采用以下配置之一进行部署：

1.  具有单个副本的StatefulSet。适合具有单个专用节点的集群来运行集群级别的容器。StatefulSet保证一次运行的Pod实例不超过1个。缺点是，如果节点无响应，则副本将永远不会被删除和重新创建。
2.  多副本部署并启用领导者选举（如果容器支持）。对管理员而言这样做的好处是在主副本出现故障时能够更快的恢复，但要占用更多的资源（尤其是内存）。
3.  单个副本部署并启用领导者选举（如果容器支持）。以上两个选项之间的折衷。如果检测到副本失败，则几乎可以立即调度一个新副本。

请注意，某些群集级别的容器，例如 `external-provisioner`、`external-attacher`、`external-resizer`和 `external-snapshotter`，可能需要存储后端的凭据，因此管理员可以选择在不运行用户容器的专用“基础结构”节点（例如主节点）上运行它们。

#### 节点对象中的拓扑表示

拓扑信息将使用标签表示。

要求：

*   必须遵守[标签格式](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/#syntax-and-character-set)。
*   必须在同一节点上支持不同的驱动程序。
*   每个键/值对的格式必须与`PersistentVolume`和`StorageClass`对象中的格式匹配，如[制备和删除](#%E5%88%B6%E5%A4%87-and-deleting)部分中所述。

拟议： `"com.example.topology/rack": "rack1"` 驱动程序已知的拓扑键列表在CSINodeInfo对象中分别存放。

理由：

*   与替代方法相比，不需要奇怪的分隔符。更干净的格式。
*   相同的拓扑键可用于不同的组件（不同的存储插件，网络插件等）
*   一旦将NodeRestriction移至较新的模型（相关上下文请参见[这里](https://github.com/kubernetes/community/pull/911)），对于新驱动程序中引入的每个新标签前缀，集群管理员必须配置NodeRestrictions以允许驱动程序更新带有前缀的标签。默认情况的集群安装可以为预安装的驱动程序包含某些前缀。与替代方法相比，这种方法不那么方便，后者可以默认使用“csi.kubernetes.io”前缀编辑所有CSI驱动程序，但是集群管理员仍然经常将这些前缀列入白名单（例如’cloud.google.com ‘）

注意事项：

*   驱动程序删除/升级/降级后，过时的标签将保持不变。驱动程序很难确定CSI之外的其他组件是否依赖此标签。
*   在驱动程序安装/升级/降级期间，由于部署依赖于最新的节点信息，因此必须在部署节点之前先停止控制器部署，并且必须在部署控制器之前先部署节点。一个可能的问题是，如果在键保持不变的情况下仅拓扑值发生更改，并且如果未指定AllowedTopologies，则必需的拓扑将同时包含新的和旧的拓扑值，并且对CSI驱动程序的CreateVolume() 调用可能失败。鉴于CSI驱动程序应向后兼容，因此当在控制器更新之前进行节点滚动升级时，这将带来更多问题。如果更改了拓扑建就不存在问题，因为必要的和首选的拓扑生成可以适当地对其进行处理。
*   在驱动程序安装/升级/降级期间，如果正在运行某个版本的控制器（旧版本或新版本），并且节点部署正在进行滚动升级，并且新版本的CSI驱动程序报告了不同的拓扑信息，则节点中的节点集群可能具有不同版本的拓扑信息。但是，这并不构成问题。如果指定了AllowedTopologies，则与AllowedTopologies中的拓扑信息版本匹配的节点子集将用作置备候选者。如果未指定AllowedTopologies，则单个节点将被用作键的真值源
*   CSINodeInfo中的拓扑键必须反映节点上当前安装的驱动程序中的拓扑键。如果未安装驱动程序，则集合必须为空。但是，由于kubelet（写者）与外部provisioner（读者）之间可能存在竞争，provisioner必须妥善处理CSINodeInfo不是最新的情况。在当前设计中，provisioner将错误地在无法访问的节点上制备卷。

替代方案：

1.  `"csi.kubernetes.io/topology.example.com_rack": "rack1"`

#### PersistentVolume对象中的拓扑表示

存在多种将单个拓扑表示为NodeAffinity的方法。例如，假设`CreateVolumeResponse`包含以下可访问的拓扑：

    - zone: "a"
      rack: "1"
    - zone: "b"
      rack: "1"
    - zone: "b"
      rack: "2"
    

至少有3种方法可以在NodeAffinity中表示（为简单起见，不包括`nodeAffinity`、`required`、和 `nodeSelectorTerms`）：

形式1-`values`恰好包含1个元素。

    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "a"
      - key: rack
        operator: In
        values:
        - "1"
    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "b"
      - key: rack
        operator: In
        values:
        - "1"
    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "b"
      - key: rack
        operator: In
        values:
        - "2"
    

形式2-使用`rack`简化。

    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "a"
        - "b"
      - key: rack
        operator: In
        values:
        - "1"
    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "b"
      - key: rack
        operator: In
        values:
        - "2"
    

形式3-使用`zone`简化。

    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "a"
      - key: rack
        operator: In
        values:
        - "1"
    - matchExpressions:
      - key: zone
        operator: In
        values:
        - "b"
      - key: rack
        operator: In
        values:
        - "1"
        - "2"
    

provisioner将始终选择形式1，即所有 `values`最多具有1个元素。将来的版本中可能选择有效且更简单的形式以简化逻辑，例如形式2和形式3。

#### 升级和降级注意事项

卸载驱动程序后，存储在节点标签中的拓扑信息将保持不变。推荐的标签格式允许多个源（例如CSI，网络资源等）共享相同的标签键，因此准确确定标签是否仍在使用并非易事。

为了使用推荐的驱动程序部署机制升级驱动程序，建议用户在部署DaemonSet（节点组件）之前停止StatefulSet（控制器组件），并在StatefulSet之前部署DaemonSet。可能可以进行一些设计改进以消除此约束，但这将在以后的迭代中进行评估。

### 示例演练

#### 制备卷

1.  集群管理员创建一个指向CSI驱动程序的external-provisioner的`StorageClass`，并指定该驱动程序所需的参数。
2.  用户参考新的`StorageClass`创建一个`PersistentVolumeClaim`。
3.  持久卷控制器意识到需要动态配置，并在PVC上标注了`volume.beta.kubernetes.io/storage-provisioner` annotation。
4.  external-provisioner CSI驱动程序会看到带有`volume.beta.kubernetes.io/storage-provisioner`注释的`PersistentVolumeClaim`，从而开始动态卷制备：
    1.  它反向引用`StorageClass`以收集用于配置的不透明参数。
    2.  它使用来自`StorageClas`s和`PersistentVolumeClaim`对象的参数对CSI驱动程序容器调用`CreateVolume`。
5.  一旦成功创建了卷，external-provisioner 就会创建一个`PersistentVolume`对象来表示新创建的卷，并将其绑定到`PersistentVolumeClaim`。

#### 删除卷

1.  用户删除绑定​​到CSI卷的`PersistentVolumeClaim`对象。
2.  CSI驱动程序的external-provisioner看到`PersistentVolumeClaim`被删除并触发了保留策略：
3.  如果保留策略是`delete`
    1.  external-provisioner通过对CSI卷插件容器发出`DeleteVolume`调用来触发卷删除。 2. 一旦成功删除该卷，external-provisioner就会删除相应的`PersistentVolume`对象。
4.  如果保留策略是`retain`
    1.  external-provisioner不会删除`PersistentVolume`对象。

#### 附加卷

1.  Kubernetes附加/分离控制器作为主节点上的`kube-controller-manager`二进制文件的一部分运行，发现引用CSI卷插件的Pod已调度到一个节点，因此它调用树内CSI卷插件的attach方法。
2.  树内卷插件在kubernetes API中创建了一个新的`VolumeAttachment`对象，并等待其状态变更为“completed”或“error”。
3.  external-attacher看到`VolumeAttachment`对象，并针对CSI卷驱动程序容器触发一个 `ControllerPublish`调用来实现它（这意味着external-attacher容器通过底层UNIX域套接字向CSI驱动程序容器发出gRPC调用）。
4.  成功完成`ControllerPublish` 调用后，external-attacher将更新`VolumeAttachment` 对象的状态，以指示该卷已成功附加。
5.  树内卷插件在Kubernetes API中监听`VolumeAttachment`‘对象的状态，看到将`Attached`字段设置为true指示已连接卷之后，它会更新附加/分离控制器的内部状态以指示卷已经附加。

#### 分离卷

1.  Kubernetes附加/分离控制器作为主节点上的`kube-controller-manager`二进制文件的一部分运行，它看到引用附加的CSI卷插件的Pod已终止或删除，因此它调用树中CSI卷插件的分离方法。
2.  树内卷插件将删除相应的`VolumeAttachment`对象。
3.  external-attacher看到在`VolumeAttachment`对象上设置的`deletionTimestamp`后，会针对CSI卷驱动器容器触发`ControllerUnpublish`以将其分离。
4.  成功完成对`ControllerUnpublish`的调用后，外部连接器将从`VolumeAttachment`对象中删除终结器，以指示分离操作成功完成，从而允许删除`VolumeAttachment`对象。
5.  树内卷插件等待`VolumeAttachment`对象，观察他是否被删除，并且假设卷已经成功分离，这是他将会更新附加/分离控制器的内部状态以指示卷已经分离。

#### 挂载卷

1.  kubelet的卷管理器组件会注意到已将一个新的卷（已引用CSI卷）调度到该节点，因此它将调用树内CSI卷插件的`WaitForAttach`方法。
2.  树内卷插件的`WaitForAttach`方法监监听kubernetes API中`VolumeAttachment`对象的`Attached`字段直到他变为`true`，然后成功返回。
3.  然后，Kubelet调用树内CSI卷插件的`MountDevice`方法，该方法无操作，之后立即返回。
4.  最后，kubelet调用树内CSI卷插件的挂载（设置）方法，该方法使树内卷插件通过已注册的unix域套接字向本地CSI驱动程序发出`NodePublishVolume`调用。
5.  成功完成`NodePublishVolume`调用后，指定的路径将被挂载到pod容器中。

#### 卸载卷

1.  kubelet的卷管理器组件会注意到引用已挂载的CSI卷的pod已被已删除或终止，因此它将调用树中CSI卷插件的`UnmountDevice`方法（该方法是无操作的）并立即返回。
2.  然后kubelet调用树内CSI卷插件的卸载（teardown）方法，这将导致树内卷插件通过已注册的unix域套接字向本地CSI驱动程序发出`NodeUnpublishVolume`调用。如果此调用由于任何原因失败，则kubelet会定期重试该调用。
3.  成功完成`NodeUnpublishVolume`调用后，将从pod容器中卸载指定的路径。

### CSI凭据

CSI允许在CreateVolume/DeleteVolume，ControllerPublishVolume/ControllerUnpublishVolume，NodeStageVolume/NodeUnstageVolume和NodePublishVolume/NodeUnpublishVolume操作中指定凭据。

Kubernetes将使集群管理员和在集群上部署工作负载的用户能够通过引用Kubernetes secret对象来指定这些凭据。Kubernetes（核心组件或辅助容器）将获取secret并将其传递给CSI卷插件。

如果一个secret对象包含多个值，所有值都会被传递。

#### CSI凭证secret编码

CSI接受以上指定的所有操作的凭据，作为字符串到字符串的映射（例如，`map<string, string> controller_create_credentials`）。

但是Kubernetes将secret定义为字符串到字节数组的映射（例如，`Data map[string][]byte`）。它还允许通过快捷字段`StringData`以字符串形式指定文本secret数据，该字段是字符串到字符串的映射。

因此，在将secret数据传递给CSI之前，Kubernetes（核心组件或辅助容器）会将secret数据从字节转换为字符串（Kubernetes未指定字符编码，但是Kubernetes在内部使用golang将字符串从字符串转换为字节，反之亦然）反之亦然（假设使用UTF-8字符集）。

尽管CSI仅接受字符串数据，但是插件可以在其文档中指示特定secret包含二进制数据，并指定要使用的二进制文本编码（base64，quoted-printable等）来编码二进制数据并允许它以字符串形式传递。创建secret并确保其内容符合插件期望的内容并以插件期望的格式进行编码是实体（集群管理员，用户等）的责任。

#### CreateVolume/DeleteVolume凭证

CSI CreateVolume/DeleteVolume调用负责创建和删除卷。 这些调用由CSI external-provisioner执行。 这些调用的凭据将在Kubernetes的`StorageClass`对象中指定。

    kind: StorageClass
    apiVersion: storage.k8s.io/v1
    metadata:
      name: fast-storage
    provisioner: com.example.team.csi-driver
    parameters:
      type: pd-ssd
      csiProvisionerSecretName: mysecret
      csiProvisionerSecretNamespace: mynamespaace
    

CSI external-provisioner将保存参数键`csiProvisionerSecretName`和`csiProvisionerSecretNamespace`。如果指定，则CSI Provisioner将在Kubernetes命名空间`csiProvisionerSecretNamespace`中获取secret `csiProvisionerSecretName`并将其传递给：

1.  CSI `CreateVolumeRequest`中通过`controller_create_credentials`字段。
2.  TCSI `DeleteVolumeRequest`中通过`controller_delete_credentials`字段。

有关如何将secret映射到CSI凭证的详细信息，请参见上面的“CSI凭证secret编码”部分。

这基于假设：由于`StorageClass`是一个non-namespaced的字段，因此只有受信任的用户（例如集群管理员）才能创建`StorageClass`，从而指定要获取的secret。

唯一需要访问此机密的Kubernetes组件是CSI external-provisioner，它将获取此secret。可以将external-provisioner的权限限制为指定的（特定于external-provisioner的）名称空间，以防止损坏的的供应商获得对其他secret的访问权限。

#### ControllerPublishVolume/ControllerUnpublishVolume凭证

CSI ControllerPublishVolume/ControllerUnpublishVolume调用负责附加和分离卷。 这些调用由CSI external-attacher执行。 这些调用的凭据将在Kubernetes的`CSIPersistentVolumeSource`对象中指定。

    type CSIPersistentVolumeSource struct {
    
      // ControllerPublishSecretRef is a reference to the secret object containing
      // sensitive information to pass to the CSI driver to complete the CSI
      // ControllerPublishVolume and ControllerUnpublishVolume calls.
      // This secret will be fetched by the external-attacher.
      // This field is optional, and  may be empty if no secret is required. If the
      // secret object contains more than one secret, all secrets are passed.
      // ControllerPublishSecretRef是对包含敏感信息的secret对象的引用，该敏感信息将传递给CSI驱
      // 动程序以完成CSI ControllerPublishVolume和ControllerUnpublishVolume调用。
      // 这个secret将由external-attacher获取。
      // 该字段可选，如果不需要任何secret，则可以为空。如果secret对象包含多个秘密信息，则将传递所有秘密。
      // +optional
      ControllerPublishSecretRef *SecretReference
    }
    

如果指定，则CSI外部附加程序将获取`ControllerPublishSecretRef`引用的Kubernetes secret并将其传递给：

1.  在CSI `ControllerPublishVolume`中通过`controller_publish_credentials`字段传递。
2.  再CSI `ControllerUnpublishVolume`中通过`controller_unpublish_credentials`字段传递。

有关如何将secret映射到CSI凭证的详细信息，请参见上面的“CSI凭证secret编码”部分。

这基于假设：由于`PersistentVolume`是一个non-namespaced的字段，因此只有受信任的用户（例如集群管理员）才能创建`CSIPersistentVolumeSource`，从而指定要获取的secret。

The only Kubernetes component that needs access to this secret is the CSI external-attacher, which would fetch this secret. The permissions for the external-attacher may be limited to the specified (external-attacher specific) namespace to prevent a compromised attacher from gaining access to other secrets.

#### NodeStageVolume/NodeUnstageVolume Credentials

The CSI NodeStageVolume/NodeUnstageVolume calls are responsible for mounting (setup) and unmounting (teardown) volumes. 这些调用由Kubernetes节点代理（kubelet）执行。 这些调用的凭据将在Kubernetes的`CSIPersistentVolumeSource`对象中指定。

    type CSIPersistentVolumeSource struct {
    
      // NodeStageSecretRef is a reference to the secret object containing sensitive
      // information to pass to the CSI driver to complete the CSI NodeStageVolume
      // and NodeStageVolume and NodeUnstageVolume calls.
      // This secret will be fetched by the kubelet.
      // This field is optional, and  may be empty if no secret is required. If the
      // NodeStageSecretRef是对包含敏感信息的secret对象的引用，该敏感信息将传递给CSI驱动程序以完成CSI 	   // NodeStageVolume、NodeStageVolume和NodeUnstageVolume调用。这个secret将由kubelet获取。
      // 该字段可选，如果不需要任何secret，则可以为空。如果secret对象包含多个秘密信息，则将传递所有秘密。
      // +optional
      NodeStageSecretRef *SecretReference
    }
    

If specified, the kubelet will fetch the Kubernetes secret referenced by `NodeStageSecretRef` and pass it to:

1.  The CSI `NodeStageVolume` in the `node_stage_credentials` field.
2.  The CSI `NodeUnstageVolume` in the `node_unstage_credentials` field.

有关如何将secret映射到CSI凭证的详细信息，请参见上面的“CSI凭证secret编码”部分。

这基于假设：由于`PersistentVolume`是一个non-namespaced的字段，因此只有受信任的用户（例如集群管理员）才能创建`CSIPersistentVolumeSource`，从而指定要获取的secret。

需要访问此secret的唯一Kubernetes组件是kubelet，它将获取此secret。可以将kubelet的权限限制为指定的（特定于kubelet的）名称空间，以防止损坏的附加程序获得对其他secret的访问权限。

必须更新Kubernetes API服务器的节点授权者，以允许kubelet访问`CSIPersistentVolumeSource.NodeStageSecretRef`引用的secret。

#### NodePublishVolume/NodeUnpublishVolume凭证

CSI NodePublishVolume/NodeUnpublishVolume调用负责挂载（设置）和卸载（拆卸）卷。 这些调用由Kubernetes节点代理（kubelet）执行。 这些调用的凭据将在Kubernetes的`CSIPersistentVolumeSource`对象中指定。

    type CSIPersistentVolumeSource struct {
    
      // NodePublishSecretRef is a reference to the secret object containing
      // sensitive information to pass to the CSI driver to complete the CSI
      // NodePublishVolume and NodeUnpublishVolume calls.
      // This secret will be fetched by the kubelet.
      // This field is optional, and  may be empty if no secret is required. If the
      // secret object contains more than one secret, all secrets are passed.
      // NodePublishSecretRef是对包含敏感信息的secret对象的引用，该敏感信息将传递给CSI驱动程序以完成CSI   // NodePublishVolume和NodeUnpublishVolume调用。这个secret将由kubelet获取。
      // 该字段可选，如果不需要任何secret，则可以为空。如果secret对象包含多个秘密信息，则将传递所有秘密。
      // +optional
      NodePublishSecretRef *SecretReference
    }
    

如果指定，则kubelet将获取由`NodePublishSecretRef`引用的Kubernetes secret，并将其传递给：

1.  CSI `NodePublishVolume`中的`node_publish_credentials`字段。
2.  CSI `NodeUnpublishVolume`中的`node_unpublish_credentials`字段。

有关如何将secret映射到CSI凭证的详细信息，请参见上面的“CSI凭证secret编码”部分。

这基于假设：由于`PersistentVolume`是一个non-namespaced的字段，因此只有受信任的用户（例如集群管理员）才能创建`CSIPersistentVolumeSource`，从而指定要获取的secret。

需要访问此secret的唯一Kubernetes组件是kubelet，它将获取此secret。可以将kubelet的权限限制为指定的（特定于kubelet的）名称空间，以防止损坏的附加程序获得对其他secret的访问权限。

必须更新Kubernetes API服务器的节点授权者，以允许kubelet访问`CSIPersistentVolumeSource.NodePublishSecretRef`引用的secret。

考虑的替代方案
-------

### 扩展PersistentVolume对象

除了创建新的`VolumeAttachment`对象外，我们考虑的另一种选择是扩展现有的`PersistentVolume`对象。

`PersistentVolumeSpec`将扩展为包括：

*   将卷附加到的节点列表（最初为空）。

`PersistentVolumeStatus`将扩展为包括：

*   卷已成功附加到的节点列表。

我们没有用这种方法，因为由对象的创建/删除触发的附加/分离更容易管理（对于外部附加器和Kubernetes）并且更健壮（无需担心的极端情况）。