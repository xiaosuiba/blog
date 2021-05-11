---
layout:     post 
title:      "Why rest.Storage interface contains only one method"
description:   ""
date:       2021-03-29
author:     "Chris Li"
tags:
    - kubernetes
    - code
categories: [ Tech ]
showtoc: false
---
rest.Storage interface contains only one method. This page show how could it utilize golang reflection to do the job.
<!--more-->

# Why rest.Storage interface have only one method

While reading Kubernetes source code, I found one question really bothered me for several days. The common interface of rest storage is defined in `/vendor/k8s.io/apiserver/pkg/registry/rest/rest.go`:
```golang
type Storage interface {
	// New returns an empty object that can be used with Create and Update after request data has been put into it.
	// This object must be a pointer type for use with Codec.DecodeInto([]byte, runtime.Object)
	New() runtime.Object
}
```
You can see there's only one method `New` defined here. So how could the other actions, like `Get` or `List` etc., be completed?

After several day's search on the internet, I finally found the some code in `/vendor/k8s.io/apiserver/pkg/endpoints/installer.go`:
```golang
func (a *APIInstaller) registerResourceHandlers(path string, storage rest.Storage, ws *restful.WebService) (*metav1.APIResource, *storageversion.ResourceInfo, error) {
.....
	// what verbs are supported by the storage, used to know what verbs we support per path
	creater, isCreater := storage.(rest.Creater)
	namedCreater, isNamedCreater := storage.(rest.NamedCreater)
	lister, isLister := storage.(rest.Lister)
	getter, isGetter := storage.(rest.Getter)
	getterWithOptions, isGetterWithOptions := storage.(rest.GetterWithOptions)
	gracefulDeleter, isGracefulDeleter := storage.(rest.GracefulDeleter)
	collectionDeleter, isCollectionDeleter := storage.(rest.CollectionDeleter)
	updater, isUpdater := storage.(rest.Updater)
	patcher, isPatcher := storage.(rest.Patcher)
	watcher, isWatcher := storage.(rest.Watcher)
	connecter, isConnecter := storage.(rest.Connecter)
	storageMeta, isMetadata := storage.(rest.StorageMetadata)
	storageVersionProvider, isStorageVersionProvider := storage.(rest.StorageVersionProvider)
```
see here, `registerResourceHandlers` utilizes golang type conversion to check the storage's abilities. So the `New` method is only a sign of rest.storage interface. The real abilities could be defined in resource storage struct as needed. The methods defined in each specific resource storage type represents its ability in the same time. 