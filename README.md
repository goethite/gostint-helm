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
Note: `KUBECONFIG` must be set for your kubernetes environment.

```
helm install gostint/
```
### Init the Vault
When everything is up (see `helm status`)
```
init/vault-init.sh release-name namespace
```
e.g.
```
init/vault-init.sh cool-rabbit default
```

### Unseal the Vault
(Note: this approach may not be suitable for production deployments)
```
init/vault-unseal.sh release-name namespace
```

### Init GoStint
```
init/gostint-init.sh release-name namespace
```

## Upgrading
After downloading / cloning latest version:
```
helm upgrade release-name gostint/
```
