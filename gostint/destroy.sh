#!/bin/bash

echo "*** IMPORTANT*** THIS IS DISTRUCTIVE, It WILL DELETE the GoSting deployment"
echo -n "Remove and cleanup gostint helm chart (This will remove everything, including persistent data) - y/n? "
read ans
if [ "$ans" != "y" ]
then
  echo "Aborted..." >&2
  exit 1
fi

# Delete the helm chart. Note: although this leaves the MongoDB PVCs in place
# (see below for how to delete them), there is no persistence for the etcd
# backend for the Vault, so it's data will be lost - it is expected you would
# backup / restore this data.
helm delete aut-op
helm delete aut-op --purge

# Delete secrets (only do this if intending to delete the PVCs below)
kubectl delete secret \
  aut-op-gostint-db-auth-token \
  aut-op-gostint-roleid \
  aut-op-gostint-tls \
  aut-op-ingress-tls \
  aut-op-mongodb \
  aut-op-vault-keys \
  aut-op-vault-server-tls \
  aut-op-vault-client-tls

# Delete persistent volume claims
kubectl delete pvc \
  datadir-aut-op-mongodb-primary-0 \
  datadir-aut-op-mongodb-secondary-0 \
  datadir-aut-op-consul-0 \
  datadir-aut-op-consul-1 \
  datadir-aut-op-consul-2

exit 0
