# Helm Charts for GoStint DevOps Automation

https://goethite.github.io/gostint/

This is a proof-of-concept helm chart for the GoStint project.

This is a work in progress and not for production use...

## Requirements
* kubectl
* helm

### Helm Repos
* stable
* incubator

## Deploying
Note: `KUBECONFIG` must be set for your kubernetes environment and helm setup.

### Install etcd-operator on your cluster
see [etc-operator](https://github.com/helm/charts/tree/master/stable/etcd-operator)
```
helm install stable/etcd-operator --name site-op
```

### Install vault-operator on your cluster
see [vault-operator](https://github.com/helm/charts/tree/master/stable/vault-operator)
```
helm install stable/vault-operator --name sec-op
```

### Install GoStint
```
helm install gostint/ --name aut-op
```
This starts etcd, vault, mongodb and gostint services.

Init the vault:
```
init/vault-init.sh aut-op default
```

Unseal the vault:
```
init/vault-unseal.sh aut-op default
```
WARNING: This approach for initialising and unsealing the vault is probably
not suitable for Production use - see the Vault Docs.

Init GoStint:
```
init/gostint-init.sh aut-op default
```

### Upgrade GoStint
```
helm upgrade aut-op gostint/
```
