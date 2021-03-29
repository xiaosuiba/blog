---
layout:     post 
title:      "Kubernetes sample-apiserver 代码阅读"
subtitle:   ""
date:       2021-03-26
author:     "Chris Li"
URL: "/2021/03/26/kubernetes-sample-apiserver/"
tags:
    - kubernetes
    - code
categories: [ Tech ]
---

# 启动过程

main.go:
```golang
func main() {
	logs.InitLogs()
	defer logs.FlushLogs()

	stopCh := genericapiserver.SetupSignalHandler()
	options := server.NewWardleServerOptions(os.Stdout, os.Stderr)
	cmd := server.NewCommandStartWardleServer(options, stopCh)
	cmd.Flags().AddGoFlagSet(flag.CommandLine)
	if err := cmd.Execute(); err != nil {
		klog.Fatal(err)
	}
}
```

options 调用 `server.NewWardleServerOption` 构建了一个 `WardleServerOptions` 配置对象
```golang
type WardleServerOptions struct {
	RecommendedOptions *genericoptions.RecommendedOptions

	SharedInformerFactory informers.SharedInformerFactory
	StdOut                io.Writer
	StdErr                io.Writer
}
```
`RecommendedOptions` 的解释为：
> // RecommendedOptions contains the recommended options for running an API server.
> 
> // If you add something to this list, it should be in a logical grouping.
> 
> // Each of them can be nil to leave the feature unconfigured on ApplyTo.

`server.NewCommandStartWardleServer` 中构建了一个 cobra.Command，代码很简短：
```golang
func NewCommandStartWardleServer(defaults *WardleServerOptions, stopCh <-chan struct{}) *cobra.Command {
	o := *defaults
	cmd := &cobra.Command{
		Short: "Launch a wardle API server",
		Long:  "Launch a wardle API server",
		RunE: func(c *cobra.Command, args []string) error {
			if err := o.Complete(); err != nil {
				return err
			}
			if err := o.Validate(args); err != nil {
				return err
			}
			if err := o.RunWardleServer(stopCh); err != nil {
				return err
			}
			return nil
		},
	}

	flags := cmd.Flags()
	o.RecommendedOptions.AddFlags(flags)
	utilfeature.DefaultMutableFeatureGate.AddFlag(flags)

	return cmd
}
```
可以看到主要工作包括两部分，一个是使用flag填充o.RecommendedOption，这部分在调用时即完成；第而部分是配置cmd的启动RunE，主要有三个步骤：
* o.Complete(): 完成一些额外配置，如admission plugins
* o.Validate(args)：对配置进行校验，这里直接使用了默认校验（sample-apiserver没有额外的配置项）
* o.RunWardleServer(stopCh)：启动服务

下面重点看下o.RunWardleServer，这是启动服务的核心部分：
```golang
// RunWardleServer starts a new WardleServer given WardleServerOptions
func (o WardleServerOptions) RunWardleServer(stopCh <-chan struct{}) error {
  //从RecommendedOption产生最终config
	config, err := o.Config()
	if err != nil {
		return err
	}

  //对config进行补完并使用配置产生server
	server, err := config.Complete().New()
	if err != nil {
		return err
	}

	server.GenericAPIServer.AddPostStartHookOrDie("start-sample-server-informers", func(context genericapiserver.PostStartHookContext) error {
		config.GenericConfig.SharedInformerFactory.Start(context.StopCh)
		o.SharedInformerFactory.Start(context.StopCh)
		return nil
	})

  //启动服务
	return server.GenericAPIServer.PrepareRun().Run(stopCh)
}
```

o.Config()：
```golang
// Config returns config for the api server given WardleServerOptions
func (o *WardleServerOptions) Config() (*apiserver.Config, error) {
  ……
	if err := o.RecommendedOptions.ApplyTo(serverConfig); err != nil {
		return nil, err
	}

	config := &apiserver.Config{
		GenericConfig: serverConfig,
		ExtraConfig:   apiserver.ExtraConfig{},
	}
	return config, nil
}
```
从这里可以发现通常的apiserver.Config构建方式是通过RecommendedOptions与cobra.command协作构建出RecommendedOptions，然后使用RecommendedOptions.ApplyTo方法将配置填充到apiserver.Config中，用于启动最终的apiserver。

`server, err := config.Complete().New()`产生了最终的WardleServer：
```golang
func (c completedConfig) New() (*WardleServer, error) {
	genericServer, err := c.GenericConfig.New("sample-apiserver", genericapiserver.NewEmptyDelegate())
	if err != nil {
		return nil, err
	}

	s := &WardleServer{
		GenericAPIServer: genericServer,
	}

	apiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(wardle.GroupName, Scheme, metav1.ParameterCodec, Codecs)

	v1alpha1storage := map[string]rest.Storage{}
	v1alpha1storage["flunders"] = wardleregistry.RESTInPeace(flunderstorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
	v1alpha1storage["fischers"] = wardleregistry.RESTInPeace(fischerstorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
	apiGroupInfo.VersionedResourcesStorageMap["v1alpha1"] = v1alpha1storage

	v1beta1storage := map[string]rest.Storage{}
	v1beta1storage["flunders"] = wardleregistry.RESTInPeace(flunderstorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
	apiGroupInfo.VersionedResourcesStorageMap["v1beta1"] = v1beta1storage

	if err := s.GenericAPIServer.InstallAPIGroup(&apiGroupInfo); err != nil {
		return nil, err
	}

	return s, nil
}
```
New做了两个重要工作：
* 使用配置构建了genericServer
* 为apiGroup配置了restStorage
  
我们挑选flunderstorage.NewREST来看看如何构建一个默认的RESTStorage:
```golang
// NewREST returns a RESTStorage object that will work against API services.
func NewREST(scheme *runtime.Scheme, optsGetter generic.RESTOptionsGetter) (*registry.REST, error) {
	strategy := NewStrategy(scheme)

	store := &genericregistry.Store{
		NewFunc:                  func() runtime.Object { return &wardle.Flunder{} },
		NewListFunc:              func() runtime.Object { return &wardle.FlunderList{} },
		PredicateFunc:            MatchFlunder,
		DefaultQualifiedResource: wardle.Resource("flunders"),

		CreateStrategy: strategy,
		UpdateStrategy: strategy,
		DeleteStrategy: strategy,

		// TODO: define table converter that exposes more than name/creation timestamp
		TableConvertor: rest.NewDefaultTableConvertor(wardle.Resource("flunders")),
	}
	options := &generic.StoreOptions{RESTOptions: optsGetter, AttrFunc: GetAttrs}
	if err := store.CompleteWithOptions(options); err != nil {
		return nil, err
	}
	return &registry.REST{store}, nil
}
```
这里直接使用genericregistry.Store构建了RESTStorage，按照RESTStorage->RegistryStore->Storage.Interface的流程，我们再深入一下genericregistry.Store，可以看到，在函数中我们并没有配置任何的Storage.Interface（genericregistry.Store中的Storage属性），在store.CompleteWithOptions(options)中：
```golang
if e.Storage.Storage == nil {
		e.Storage.Codec = opts.StorageConfig.Codec
		var err error
		e.Storage.Storage, e.DestroyFunc, err = opts.Decorator(
			opts.StorageConfig,
			prefix,
			keyFunc,
			e.NewFunc,
			e.NewListFunc,
			attrFunc,
			options.TriggerFunc,
			options.Indexers,
		)
```
当Storage为nil时，使用Decorator模式构建了一个e.Storage.Storage。

此外，在apiserver.go中还使用init函数，完成了schema的注册工作：
```golang
func init() {
	install.Install(Scheme)

	// we need to add the options to empty v1
	// TODO fix the server code to avoid this
	metav1.AddToGroupVersion(Scheme, schema.GroupVersion{Version: "v1"})

	// TODO: keep the generic API server from wanting this
	unversioned := schema.GroupVersion{Group: "", Version: "v1"}
	Scheme.AddUnversionedTypes(unversioned,
		&metav1.Status{},
		&metav1.APIVersions{},
		&metav1.APIGroupList{},
		&metav1.APIGroup{},
		&metav1.APIResourceList{},
	)
}
```
到此为止，apiserver的配置已经完成，接下来我们看看服务的启动:
`server.GenericAPIServer.PrepareRun().Run(stopCh)`
```golang
// PrepareRun does post API installation setup steps. It calls recursively the same function of the delegates.
func (s *GenericAPIServer)  PrepareRun() preparedGenericAPIServer {
	s.delegationTarget.PrepareRun()

	if s.openAPIConfig != nil {
		s.OpenAPIVersionedService, s.StaticOpenAPISpec = routes.OpenAPI{
			Config: s.openAPIConfig,
		}.Install(s.Handler.GoRestfulContainer, s.Handler.NonGoRestfulMux)
	}

	s.installHealthz()
	s.installLivez()
	err := s.addReadyzShutdownCheck(s.readinessStopCh)
	if err != nil {
		klog.Errorf("Failed to install readyz shutdown check %s", err)
	}
	s.installReadyz()

	// Register audit backend preShutdownHook.
	if s.AuditBackend != nil {
		err := s.AddPreShutdownHook("audit-backend", func() error {
			s.AuditBackend.Shutdown()
			return nil
		})
		if err != nil {
			klog.Errorf("Failed to add pre-shutdown hook for audit-backend %s", err)
		}
	}

	return preparedGenericAPIServer{s}
}
```
可以看到主要工作就是配置openAPI handler，安装Healthz、Livez、Readyz端点，接下来运行Run：
```golang
// Run spawns the secure http server. It only returns if stopCh is closed
// or the secure port cannot be listened on initially.
func (s preparedGenericAPIServer) Run(stopCh <-chan struct{}) error {
...............
	// close socket after delayed stopCh
	stoppedCh, err := s.NonBlockingRun(delayedStopCh)
...............
}

func (s preparedGenericAPIServer) NonBlockingRun(stopCh <-chan struct{}) (<-chan struct{}, error) {
................
	// Use an internal stop channel to allow cleanup of the listeners on error.
	internalStopCh := make(chan struct{})
	var stoppedCh <-chan struct{}
	if s.SecureServingInfo != nil && s.Handler != nil {
		var err error
		stoppedCh, err = s.SecureServingInfo.Serve(s.Handler, s.ShutdownTimeout, internalStopCh)
		if err != nil {
			close(internalStopCh)
			close(auditStopCh)
			return nil, err
		}
	}
................
}
```
至此，APIServer启动完成。
