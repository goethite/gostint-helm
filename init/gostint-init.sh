#!/bin/bash

if [ $# -lt 2 ]
  then
    echo "Invalid arguments provided"
    echo "Valid usage: "`basename "$0"`" <release-name> <namespace>"
    exit 1
fi

RELEASE=$1
NAMESPACE=$2

SECRET_NAME="$RELEASE-vault-keys"
DB_SECRET_NAME="$RELEASE-mongodb"
ROLEID_SECRET_NAME="$RELEASE-gostint-roleid"
DBTOKEN_SECRET_NAME="$RELEASE-gostint-db-auth-token"
GOSTINT_TLS_SECRET_NAME="$RELEASE-gostint-tls"

echo "Getting root key from Kubernetes secret"
ROOT_KEY=$(kubectl get secret -n $NAMESPACE ${SECRET_NAME} -o yaml | grep -e "^[ ]*rootkey:" | awk '{print $2}' | base64 --decode)
# echo "ROOT_KEY: $ROOT_KEY"

echo "Getting root mongodb password from Kubernetes secret"
DB_ROOT_PW=$(kubectl get secret -n $NAMESPACE ${DB_SECRET_NAME} -o yaml | grep -e "^[ ]*mongodb-root-password:" | awk '{print $2}' | base64 --decode)
echo "DB_ROOT_PW: $DB_ROOT_PW"

DB_HOST=$(kubectl get service $RELEASE-mongodb -o yaml | grep "^[ ]*clusterIP:" | awk '{ print $2;}')

echo "Configuring Vault for GoStint"
FIRST_VAULT_POD=$(kubectl get po -l app=vault,vault_cluster=$RELEASE-gostint-vault -n $NAMESPACE | awk '{if(NR==2)print $1}')
echo "FIRST_VAULT_POD: $FIRST_VAULT_POD"

kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
#vault login $ROOT_KEY
vault status

echo '=== Configuring MongoDB secret engine ========================='
vault secrets enable database
vault write database/config/gostint-mongodb \
  plugin_name=mongodb-database-plugin \
  allowed_roles="gostint-dbauth-role" \
  connection_url="mongodb://{{username}}:{{password}}@$DB_HOST:27017/admin?ssl=false" \
  username="root" \
  password="${DB_ROOT_PW}"

vault write database/roles/gostint-dbauth-role \
  db_name=gostint-mongodb \
  creation_statements='{ "db": "gostint", "roles": [{ "role": "readWrite" }] }' \
  default_ttl="10m" \
  max_ttl="1h"

vault policy write gostint-mongodb-auth - <<EEOF
path "database/creds/gostint-dbauth-role" {
  capabilities = ["read"]
}
EEOF

echo '=== Enable transit plugin ==============================='
vault secrets enable transit

echo '=== Create gostint instance transit keyring =============='
vault write -f transit/keys/gostint

echo '=== enable AppRole auth ================================='
vault auth enable approle

echo '=== Create policy to access kv for gostint-role =========='
vault policy write gostint-approle-kv - <<EEOF
path "secret/*" {
  capabilities = ["read"]
}
EEOF

echo '=== Create policy to access transit decrypt gostint for gostint-role =========='
vault policy write gostint-approle-transit-decrypt-gostint - <<EEOF
path "transit/decrypt/gostint" {
  capabilities = ["update"]
}
EEOF

echo '=== Create approle role for gostint ======================'
vault write auth/approle/role/gostint-role \
  secret_id_ttl=24h \
  secret_id_num_uses=10000 \
  token_num_uses=10 \
  token_ttl=20m \
  token_max_ttl=30m \
  policies="gostint-approle-kv,gostint-approle-transit-decrypt-gostint"
EOF

echo '=== Get approle role_id for gostint ======================'
GOSTINT_ROLEID=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
vault read -format=yaml -field=data auth/approle/role/gostint-role/role-id | awk '{print \$2;}'
EOF
)
echo "GOSTINT_ROLEID: $GOSTINT_ROLEID"

echo "=== Deleting existing gostint role_id secret ============="
kubectl delete secret -n $NAMESPACE $ROLEID_SECRET_NAME --ignore-not-found=true

echo "=== Creating gostint role_id secret ======================"
kubectl create secret generic $ROLEID_SECRET_NAME -n $NAMESPACE --from-literal=role_id=$GOSTINT_ROLEID
kubectl label secret -n $NAMESPACE \
  $ROLEID_SECRET_NAME \
  app="${RELEASE}-gostint-init"
kubectl label secret -n $NAMESPACE \
  --overwrite \
  $ROLEID_SECRET_NAME \
  app="${RELEASE}-gostint-init"

echo "=== Creating gostint-mongodb-auth token =================="
DB_AUTH_TOKEN=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
vault token create -policy=gostint-mongodb-auth -format=yaml | grep "^[ ]*client_token:" | awk '{print \$2;}'
EOF
)
# vault token create -policy=gostint-mongodb-auth -period=10m -use-limit=2 -format=yaml | grep "^[ ]*client_token:" | awk '{print \$2;}'

# kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
# vault login $ROOT_KEY
# EOF

echo "=== Deleting existing gostint gostint-mongodb-auth secret "
kubectl delete secret -n $NAMESPACE $DBTOKEN_SECRET_NAME --ignore-not-found=true

echo "=== Creating gostint gostint-mongodb-auth secret ========="
kubectl create secret generic $DBTOKEN_SECRET_NAME -n $NAMESPACE --from-literal=token=$DB_AUTH_TOKEN
kubectl label secret -n $NAMESPACE \
  $DBTOKEN_SECRET_NAME \
  app="${RELEASE}-gostint-init"
kubectl label secret -n $NAMESPACE \
  --overwrite \
  $DBTOKEN_SECRET_NAME \
  app="${RELEASE}-gostint-init"

echo "=== Creating gostint self-signed cert ===================="
T_DIR=$(mktemp -d /tmp/gostint.XXXXXXXXX)
echo -e 'GB\n\n\ngostint\n\n${RELEASE}-gostint\n\n' | \
  openssl req  -nodes -new -x509  \
    -keyout $T_DIR/key.pem \
    -out $T_DIR/cert.pem \
    -days 365

echo "=== Deleting existing gostint TLS secret "
kubectl delete secret -n $NAMESPACE $GOSTINT_TLS_SECRET_NAME --ignore-not-found=true
kubectl create secret generic $GOSTINT_TLS_SECRET_NAME -n $NAMESPACE \
  --from-file=$T_DIR/key.pem \
  --from-file=$T_DIR/cert.pem
kubectl label secret -n $NAMESPACE \
  $GOSTINT_TLS_SECRET_NAME \
  app="${RELEASE}-gostint-init"
kubectl label secret -n $NAMESPACE \
  --overwrite \
  $GOSTINT_TLS_SECRET_NAME \
  app="${RELEASE}-gostint-init"
