---
layout:     post 
title:      "TKEStack v1.6.0 global集群中serviceaccount总是默认拥有所有权限"
subtitle:   "Why serviceaccount in tkestack v1.6.0 has full access to all resources by default?"
date:       2021-04-06
author:     "Chris Li"
URL: "/2021/04/06/tkestack-auth-api-issue/"
tags:
    - kubernetes
    - TKEStack
    - code
categories: [ Tech ]
showtoc: false
---

TKEStack v1.6.0已经发布了，没有包含重大更新，但是在使用过程中，我们发现了一个很神奇的现象：global集群中任何serviceaccount都能访问所有的集群资源。这点可以直接使用`kubectl auth can-i`得到验证：

在1.5.0集群中执行：
```bash
$ kubectl auth can-i create pod --as=system:serviceaccount:tke:fake
no
```
而在1.6.0中执行：
```bash
$ kubectl auth can-i create pod --as=system:serviceaccount:tke:fake
yes
```

我们甚至都还没有创建过fake这个serviceaccount。根据现象，首先怀疑是kube-apiserver的authz配置发生了改变，查看kube-apiserver的配置，果然:
```
--authorization-mode=Node,RBAC,Webhook
```
1.5.0中则只有`Node,RBAC`，看来问题就出在Webhook中。关于Webhook的说明，[官方文档](https://kubernetes.io/docs/reference/access-authn-authz/webhook/)给出了解释。继续查看kubernetes的Webhook配置，配置文件为`--authorization-webhook-config-file=/etc/kubernetes/tke-authz-webhook.yaml`，文件内容如下：
```yaml
  tke-authz-webhook.yaml: |
    apiVersion: v1
    kind: Config
    clusters:
      - name: tke
        cluster:
          certificate-authority: /app/certs/ca.crt
          server: http://{vip}:31138/auth/authz
    users:
      - name: admin-cert
        user:
          client-certificate: /app/certs/admin.crt
          client-key: /app/certs/admin.key
    current-context: tke
    contexts:
    - context:
        cluster: tke
        user: admin-cert
      name: tke
```
webhook代理地址为http://{vip}:31138/auth/authz，也即是tke-auth-api的nodeport。

继续查看tke-auth-api中认证相关配置：
/cmd/tke-auth-api/app/app.go
```yaml
cfg, err := config.CreateConfigFromOptions(basename, opts)
```
tke-auth-api/app/config/config.go
```yaml
aggregateAuthz, err := aggregation.NewAuthorizer(authClient, opts.Authorization, opts.Auth, enforcer, opts.Authentication.PrivilegedUsername)
```
/opt/project/tke/pkg/auth/authorization/aggregation/aggregation.go
```yaml
// NewAuthorizer creates a authorizer for subject access review and returns it.
func NewAuthorizer(authClient authinternalclient.AuthInterface, authorizationOpts *options.AuthorizationOptions, authOpts *options.AuthOptions, enforcer *casbin.SyncedEnforcer, privilegedUsername string) (authorizer.Authorizer, error) {
	var (
		authorizers []authorizer.Authorizer
	)

	if len(authorizationOpts.WebhookConfigFile) != 0 {
		webhookAuthorizer, err := webhook.New(authorizationOpts.WebhookConfigFile,
			authorizationOpts.WebhookVersion,
			authorizationOpts.WebhookCacheAuthorizedTTL,
			authorizationOpts.WebhookCacheUnauthorizedTTL, nil)
		if err != nil {
			return nil, err
		}

		authorizers = append(authorizers, webhookAuthorizer)
	}

	if len(authorizationOpts.PolicyFile) != 0 {
		abacAuthorizer, err := abac.NewABACAuthorizer(authorizationOpts.PolicyFile)
		if err != nil {
			return nil, err
		}
		authorizers = append(authorizers, abacAuthorizer)
	}

	authorizers = append(authorizers, local.NewAuthorizer(authClient, enforcer, privilegedUsername))

	return union.New(authorizers...), nil
}

```
可以看到最终的authrizer配置由webhook（如果有）、abac（如果有）和local组成。auth-api的配置文件：
```toml
  tke-auth-api.toml: |
    ........
    [authorization]
    policy_file="/app/conf/abac-policy.json"
```
继续查看abac-policy.json
```yaml
{"apiVersion":"abac.authorization.kubernetes.io/v1beta1","kind":"Policy","spec":{"user":"system:*","namespace":"*", "resource":"*","apiGroup":"*", "group": "*", "nonResourcePath":"*"}}
```
该文件将配置任意`system:*`配置拥有任意`namespace`下的所有资源。

至此，问题原因已经找到了。但问什么TKEStack中如此配置ABAC？这将导致一个明显的漏洞出现。带着问题，我们继续查看github上的修改提交记录：
* [1155](https://github.com/tkestack/tke/pull/1155)
但是没有找到任何相关说明为何要如此修改，我将对此issue进行一个comment，希望作者能有相关解释。
