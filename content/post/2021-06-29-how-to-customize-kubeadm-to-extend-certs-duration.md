---
layout:     post 
title:      "定制kubeadm延长集群证书有效期"
date:       2021-06-29
author:     "Chris Li"
tags:
    - kubernetes
    - code
categories: [ Tech ]
showtoc: false
---

使用kubeadm创建集群时，服务证书和kubelet均会在1年过期。本文介绍了一种修改kubeadm来延长各种证书有效期的方式。
<!--more-->

## 0. 默认证书有效期

最近公司的一个产品出了线上问题，由于使用了默认的kubeadm创建集群，集群的CA证书有10年有效期，但其余证书（包括服务证书和kubelet证书）通常只有1年有效期，到期之后需要通过kubeadm升级，或者手动执行kubeadm renew的方式来[续签证书](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)。否则集群将有停止服务的风险。

官方如此设计kubeadm，一是出于安全原因，另外是希望用户能够及时升级。每次使用kubeadm升级时，会自动更新证书有效期。但作为服务提供商，我们不能控制或强制用户升级，直接给100年有效期是最稳妥的做法。

使用`kubeadm certs check-expiration`(1.20以前需要使用`kubeadm alpha certs check-expiration`)查看证书如下：
```bash
[root@localhost kubernetes]# kubeadm certs check-expiration
[check-expiration] Reading configuration from the cluster...
[check-expiration] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'

CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Jun 09, 2022 09:36 UTC   345d                                    no
apiserver                  Jun 09, 2022 09:36 UTC   345d            ca                      no
apiserver-etcd-client      Jun 09, 2022 09:36 UTC   345d            etcd-ca                 no
apiserver-kubelet-client   Jun 09, 2022 09:36 UTC   345d            ca                      no
controller-manager.conf    Jun 09, 2022 09:36 UTC   345d                                    no
etcd-healthcheck-client    Jun 09, 2022 09:36 UTC   345d            etcd-ca                 no
etcd-peer                  Jun 09, 2022 09:36 UTC   345d            etcd-ca                 no
etcd-server                Jun 09, 2022 09:36 UTC   345d            etcd-ca                 no
front-proxy-client         Jun 09, 2022 09:36 UTC   345d            front-proxy-ca          no
scheduler.conf             Jun 09, 2022 09:36 UTC   345d                                    no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Jun 07, 2031 09:36 UTC   9y              no
etcd-ca                 Jun 07, 2031 09:36 UTC   9y              no
front-proxy-ca          Jun 07, 2031 09:36 UTC   9y              no
``` 

可以看到CA证书有效期为10年，服务证书为1年（由于已经创建一段时间，有效期是向下取整的）。

`fanux`同学已经总结了一篇修改kubeadm延长证书的文章：[kubeadm定制化开发，延长证书](https://blog.csdn.net/github_35614077/article/details/98748768)，但按这篇文章修改之后，我发现几个问题：

1.  修改之后的kubeadm仅延长了CA证书，对服务证书并没有作用
2.  没有考虑使用bootstrap方式的kubelet client证书有效期

经过一番探索，在fanux基础上我们成功的实现了全集群的证书有效期延长，具体步骤如下：

1.  修改CA有效期，这是`fanux`文章中提到过的
2.  修改服务证书有效期
3.  配置kube-controller-manager，为kubelet颁发99年有效期证书

## 1. 修改CA有效期

修改`vendor/k8s.io/client-go/util/cert/cert.go`
```golang
diff --git a/staging/src/k8s.io/client-go/util/cert/cert.go b/staging/src/k8s.io/client-go/util/cert/cert.go
index 3da1441..37f5823 100644
--- a/staging/src/k8s.io/client-go/util/cert/cert.go
+++ b/staging/src/k8s.io/client-go/util/cert/cert.go
@@ -36,6 +36,7 @@ import (
 )
 
 const duration365d = time.Hour * 24 * 365
+const longYear = 100
 
 // Config contains the basic fields required for creating a certificate
 type Config struct {
@@ -63,7 +64,7 @@ func NewSelfSignedCACert(cfg Config, key crypto.Signer) (*x509.Certificate, erro
                        Organization: cfg.Organization,
                },
                NotBefore:             now.UTC(),
-               NotAfter:              now.Add(duration365d * 10).UTC(),
+               NotAfter:              now.Add(duration365d * longYear).UTC(),
                KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
                BasicConstraintsValid: true,
                IsCA:                  true,
@@ -93,7 +94,7 @@ func GenerateSelfSignedCertKey(host string, alternateIPs []net.IP, alternateDNS
 // Certs/keys not existing in that directory are created.
 func GenerateSelfSignedCertKeyWithFixtures(host string, alternateIPs []net.IP, alternateDNS []string, fixtureDirectory string) ([]byte, []byte, error) {
        validFrom := time.Now().Add(-time.Hour) // valid an hour earlier to avoid flakes due to clock skew
-       maxAge := time.Hour * 24 * 365          // one year self-signed certs
+       maxAge := duration365d * longYear       // one year self-signed certs
 
        baseName := fmt.Sprintf("%s_%s_%s", host, strings.Join(ipsToStrings(alternateIPs), "-"), strings.Join(alternateDNS, "-"))
        certFixturePath := filepath.Join(fixtureDirectory, baseName+".crt")
@@ -107,7 +108,7 @@ func GenerateSelfSignedCertKeyWithFixtures(host string, alternateIPs []net.IP, a
                        }
                        return nil, nil, fmt.Errorf("cert %s can be read, but key %s cannot: %v", certFixturePath, keyFixturePath, err)
                }
-               maxAge = 100 * time.Hour * 24 * 365 // 100 years fixtures
+               maxAge = duration365d * longYear // 100 years fixtures
        }
 
        caKey, err := rsa.GenerateKey(cryptorand.Reader, 2048)
``` 

## 2. 修改服务证书有效期

修改`cmd/kubeadm/app/util/pkiutil/pki_helpers.go`中使用的变量`kubeadmconstants.CertificateValidity`
```golang
    	certTmpl := x509.Certificate{
    		Subject: pkix.Name{
    			CommonName:   cfg.CommonName,
    			Organization: cfg.Organization,
    		},
    		DNSNames:     cfg.AltNames.DNSNames,
    		IPAddresses:  cfg.AltNames.IPs,
    		SerialNumber: serial,
    		NotBefore:    caCert.NotBefore,
    		NotAfter:     time.Now().Add(kubeadmconstants.CertificateValidity).UTC(),
    		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
    		ExtKeyUsage:  cfg.Usages,
    	}
```

该变量定义在`cmd/kubeadm/app/constants/constants.go`
```golang
    diff --git a/cmd/kubeadm/app/constants/constants.go b/cmd/kubeadm/app/constants/constants.go
    index 2e3f4c9..768cf70 100644
    --- a/cmd/kubeadm/app/constants/constants.go
    +++ b/cmd/kubeadm/app/constants/constants.go
    @@ -46,7 +46,7 @@ const (
            TempDirForKubeadm = "tmp"
     
            // CertificateValidity defines the validity for all the signed certificates generated by kubeadm
    -       CertificateValidity = time.Hour * 24 * 365
    +       CertificateValidity = time.Hour * 24 * 365 * 100
     
            // CACertAndKeyBaseName defines certificate authority base name
            CACertAndKeyBaseName = "ca"
```  

## 3. 修改kube-controller-manager –cluster-signing-duration

kube-controller-manager的`--cluster-signing-duration`参数控制每次给kubelet颁发证书的有效期，默认值为`8760h0m0s`，也即1年。
```
–cluster-signing-duration duration Default: 8760h0m0s The length of duration signed certificates will be given.
```

可以在使用kubeadm初始化时配置kube-controllermanager参数，或初始化之后修改manifests的方式，修改`--cluster-signing-duration`值为`876000h`。

## 4. 验证

最后验证一下，通过`make all WHAT=cmd/kubeadm GOFLAGS=-v`编译kubeadm。 使用新的kubeadm初始化或重新生成集群证书（执行`kubeadm certs renew all`不能更新CA）进行证书更新。 再次查看证书：
```bash
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Jun 05, 2121 09:18 UTC   99y                                     no
apiserver                  Jun 05, 2121 09:32 UTC   99y             ca                      no
apiserver-etcd-client      Jun 05, 2121 09:32 UTC   99y             etcd-ca                 no
apiserver-kubelet-client   Jun 05, 2121 09:32 UTC   99y             ca                      no
controller-manager.conf    Jun 05, 2121 09:18 UTC   99y                                     no
etcd-healthcheck-client    Jun 05, 2121 09:32 UTC   99y             etcd-ca                 no
etcd-peer                  Jun 05, 2121 09:32 UTC   99y             etcd-ca                 no
etcd-server                Jun 05, 2121 09:32 UTC   99y             etcd-ca                 no
front-proxy-client         Jun 05, 2121 09:32 UTC   99y             front-proxy-ca          no
scheduler.conf             Jun 05, 2121 09:18 UTC   99y                                     no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Jun 05, 2121 09:32 UTC   99y             no
etcd-ca                 Jun 05, 2121 09:32 UTC   99y             no
front-proxy-ca          Jun 05, 2121 09:32 UTC   99y             no
```  

100年证书稳如老狗！！