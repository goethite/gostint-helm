#!/bin/bash -xe

if [ $# -lt 2 ]
  then
    echo "Invalid arguments provided"
    echo "Valid usage: "`basename "$0"`" <release-name> <namespace>"
    exit 1
fi

RELEASE=$1
NAMESPACE=$2
INGRESS_TLS_SECRET_NAME="$RELEASE-ingress-tls"

echo "=== Creating ingress self-signed cert ===================="
T_DIR=$(mktemp -d /tmp/gostint.XXXXXXXXX)
echo -e 'GB\n\n\ngostint\n\n${RELEASE}-gostint-ingress\n\n' | \
  openssl req  -nodes -new -x509  \
    -keyout $T_DIR/tls.key \
    -out $T_DIR/tls.crt \
    -days 365

echo "=== Deleting existing ingress TLS secret "
kubectl delete secret -n $NAMESPACE $INGRESS_TLS_SECRET_NAME --ignore-not-found=true
kubectl create secret generic $INGRESS_TLS_SECRET_NAME -n $NAMESPACE \
  --from-file=$T_DIR/tls.key \
  --from-file=$T_DIR/tls.crt

kubectl label secret -n $NAMESPACE \
  $INGRESS_TLS_SECRET_NAME \
  app="${RELEASE}-ingress-init"

kubectl label secret -n $NAMESPACE \
  --overwrite \
  $INGRESS_TLS_SECRET_NAME \
  app="${RELEASE}-ingress-init"
