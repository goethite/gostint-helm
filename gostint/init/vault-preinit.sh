#!/bin/bash
#
# Prereqs:
#   cfssl, cfssljson - from https://pkg.cfssl.org/

NAMESPACE=${1:-default}
RELEASE=${1:-aut-op}

RUNPATH=$(dirname $0)
export PATH=$RUNPATH:$PATH  # resolve cfssl

SECS=$(kubectl get secrets -n $NAMESPACE vault-client-tls vault-server-tls -o yaml 2>/dev/null | grep "name:" | wc -l) || exit 1
echo "Found $SECS TLS Secrets"

if [ $SECS != 2 ]
then
  KUBE_NS=$NAMESPACE \
    SERVER_SECRET=${RELEASE}-vault-server-tls \
    CLIENT_SECRET=${RELEASE}-vault-client-tls \
    $RUNPATH/tls-gen.sh
else
  echo "Vault TLS secrets already present - delete and rerun to regenerate, if needed"
fi
