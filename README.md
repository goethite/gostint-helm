# Helm Charts for GoStint DevOps Automation

https://goethite.github.io/gostint/

This is a proof-of-concept helm chart for the GoStint project.

This is a work in progress and __not for production use...__

The goal is to provide a pre-packaged demo environment for GoStint, with
Hashicorp Vault etc all preconfigured.

The PoC GoStint UI is enabled by default in the helm chart and can be accessed
by pointing your browser at https://your-k8s-ingess/gostint.
The `values.yaml` setting `ui.vaultExternalAddr` must be set to the ingress
url of the Vault, e.g. https://your-k8s-ingress/vault (see also comments
below regarding the Ingress Controller).

## IMPORTANT Upgrading from v1 -> v2
The upgrade of the helm chart from v1.* to v2.* is a breaking change due to
MongoDB now being deployed as a StatefulSet.

## Requirements
* kubectl
* helm

### Helm Repos
* stable
* incubator

## Deploying
Note: `KUBECONFIG` must be set for your kubernetes environment and helm setup.

### Install nginx-ingress controller
see [nginx-ingress](https://github.com/helm/charts/tree/master/stable/nginx-ingress)
```bash
helm install stable/nginx-ingress --name ingress-op --set controller.extraArgs.v=2
or
helm upgrade ingress-op stable/nginx-ingress --set controller.extraArgs.v=2
```

### Install GoStint
Deploy the chart:
```bash
gostint/deploy.sh
```
This starts consul, vault, mongodb and gostint services.

### Ingress Controller
The helm chart also deploys an Ingress Controller on port 443 to allow a single
api to provide access to both the Vault and GoStint APIs using path based routing,
e.g.:

Service | Ingress URL
------- | -----------
vault   | https://url/vault
gostint | https://url/gostint

So an execution of `gostint-client` could look like:
```bash
gostint-client \
  -url=https://your-ingress-fqdn/gostint \
  -vault-url=https://your-ingress-fqdn/vault \
  -vault-roleid=@.client_role_id \
  -vault-secretid=@.client_secret_id \
  -image=goethite/gostint-kubectl \
  -env-vars='["RUNCMD=/usr/local/bin/helm"]' \
  -run='["status", "aut-op"]' \
  -secret-refs='["KUBECONFIG_BASE64@secret/k8s_cluster_1.kubeconfig_base64"]' \
  -image-pull-policy=Always \
  -debug
```

Init Ingress:
```bash
gostint/init/ingress-init.sh aut-op default
```

IMPORTANT: The above path based ingress for vault breaks end-to-end TLS
encryption and could present a security risk (for gostint-client authenticating,
but not for the actual submission of the job).  SSL Passthrough with SNI
server based routing may be a better option.

### Upgrade GoStint
Simply rerun `deploy.sh`:
```bash
gostint/deploy.sh
```

### Delete GoStint (and all related data, including Vault/Consul)
```bash
gostint/destroy.sh
```

## Notes

### Microk8s
I had an issue with internet access from the PODs under microk8s.  It seems the
docker iptables rules where dropping the packets by default.
see my [gist](https://gist.github.com/gbevan/8a0a786cfc2728cd2998f868b0ff5b72)
for a solution.

See also [gist to allow priviledged container for microk8s](https://gist.github.com/antonfisher/d4cb83ff204b196058d79f513fd135a6).

### Get Vault Pod HA Roles
```bash
kubectl -n default get pods \
  | awk '/^aut-op-vault/ { print $1; }' \
  | xargs -i@ kubectl -n default -c vault exec -i @ \
    -- bash -c "echo -n '@ '; VAULT_SKIP_VERIFY=1 vault status | awk '/^HA Mode/ { printf \$3; }'; echo"
```
