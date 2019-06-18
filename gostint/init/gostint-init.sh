#!/bin/bash -e

RELEASE=${RELEASE:-aut-op}
NAMESPACE=${NAMESPACE:-default}

SECRET_NAME="$RELEASE-vault-keys"
DB_SECRET_NAME="$RELEASE-mongodb"
DBTOKEN_SECRET_NAME="$RELEASE-gostint-db-auth-token"
GOSTINT_TLS_SECRET_NAME="$RELEASE-gostint-tls"

# Content Execution AppRole (PULL Mode)
GOSTINT_ROLENAME="${GOSTINT_ROLENAME:-gostint-role}"
GOSTINT_ROLE_SECRET_NAME="$RELEASE-gostint-role"

# Deploy.Startup AppRole (PUSH Mode)
GOSTINT_RUN_ROLENAME="${GOSTINT_RUN_ROLENAME:-gostint-run-role}"
GOSTINT_RUN_ROLE_SECRET_NAME="$RELEASE-gostint-run-role"

echo "Getting root key from Kubernetes secret"
ROOT_KEY=$(kubectl get secret -n $NAMESPACE ${SECRET_NAME} -o yaml | grep -e "^[ ]*rootkey:" | awk '{print $2}' | base64 --decode)
# echo "ROOT_KEY: $ROOT_KEY"

echo "Getting root mongodb password from Kubernetes secret"
DB_ROOT_PW=$(kubectl get secret -n $NAMESPACE ${DB_SECRET_NAME} -o yaml | grep -e "^[ ]*mongodb-root-password:" | awk '{print $2}' | base64 --decode)
# echo "DB_ROOT_PW: $DB_ROOT_PW"

DB_HOST=$(kubectl get service $RELEASE-mongodb -o yaml | grep "^[ ]*clusterIP:" | awk '{ print $2;}')

echo "Configuring Vault for GoStint"
FIRST_VAULT_POD=$(kubectl get po -l app=vault,release=$RELEASE -n $NAMESPACE | awk '{if(NR==2)print $1}')
# echo "FIRST_VAULT_POD: $FIRST_VAULT_POD"

GOSTINT_RUN_SECRET_ID=$(uuidgen)

kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh -e <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
#vault status

echo '=== Configuring MongoDB secret engine ========================='
vault secrets enable database || /bin/true
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

echo '=== Enable kv version 2 ==============================='
vault secrets enable -version=2 kv

echo '=== Enable transit plugin ==============================='
vault secrets enable transit || /bin/true

echo '=== Create gostint instance transit keyring =============='
vault write -f transit/keys/$GOSTINT_ROLENAME

echo '=== enable AppRole auth ================================='
vault auth enable approle || /bin/true

echo '=== Create policy to access kv for gostint-role =========='
vault policy write gostint-approle-kv - <<EEOF
path "secret/*" {
  capabilities = ["read"]
}
path "kv/*" {
  capabilities = ["read"]
}
EEOF

echo '=== Create policy to access transit decrypt gostint for gostint-role =========='
vault policy write $GOSTINT_ROLENAME-approle-transit-decrypt-gostint - <<EEOF
path "transit/decrypt/$GOSTINT_ROLENAME" {
  capabilities = ["update"]
}
EEOF

echo '=== Create approle role for gostint ======================'
vault write auth/approle/role/$GOSTINT_ROLENAME \
  secret_id_ttl=24h \
  secret_id_num_uses=1 \
  token_num_uses=10 \
  token_ttl=20m \
  token_max_ttl=30m \
  policies="gostint-approle-kv,$GOSTINT_ROLENAME-approle-transit-decrypt-gostint"

echo '=== Create approle role for gostint-run =================='
vault write auth/approle/role/$GOSTINT_RUN_ROLENAME \
  token_num_uses=2 \
  token_ttl=20m \
  token_max_ttl=30m \
  policies="gostint-mongodb-auth"

echo '=== Add secret-id to gostint-run ========================='
vault write auth/approle/role/$GOSTINT_RUN_ROLENAME/custom-secret-id \
  secret_id=$GOSTINT_RUN_SECRET_ID
EOF

echo '=== Get approle role_id for gostint ======================'
GOSTINT_ROLEID=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
vault read -format=yaml -field=data auth/approle/role/$GOSTINT_ROLENAME/role-id | awk '{print \$2;}'
EOF
)
# echo "GOSTINT_ROLEID: $GOSTINT_ROLEID"

echo '=== Get approle role_id for gostint-run =================='
GOSTINT_RUN_ROLEID=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh <<EOF
export VAULT_SKIP_VERIFY=1
export VAULT_TOKEN=$ROOT_KEY
vault read -format=yaml -field=data auth/approle/role/$GOSTINT_RUN_ROLENAME/role-id | awk '{print \$2;}'
EOF
)
# echo "GOSTINT_ROLEID: $GOSTINT_ROLEID"

echo "=== Deleting existing gostint role_id secret ============="
kubectl delete secret -n $NAMESPACE $GOSTINT_ROLE_SECRET_NAME --ignore-not-found=true

echo "=== Deleting existing gostint-run role_id secret ============="
kubectl delete secret -n $NAMESPACE $GOSTINT_RUN_ROLE_SECRET_NAME --ignore-not-found=true

echo "=== Creating gostint role_id secret ======================"
kubectl create secret generic $GOSTINT_ROLE_SECRET_NAME -n $NAMESPACE \
  --from-literal=role_id=$GOSTINT_ROLEID \
  --from-literal=role_name=$GOSTINT_ROLENAME

kubectl label secret -n $NAMESPACE \
  $GOSTINT_ROLE_SECRET_NAME \
  app="${RELEASE}-gostint-init"

kubectl label secret -n $NAMESPACE \
  --overwrite \
  $GOSTINT_ROLE_SECRET_NAME \
  app="${RELEASE}-gostint-init"

echo "=== Creating gostint-run role_id secret ======================"
kubectl create secret generic $GOSTINT_RUN_ROLE_SECRET_NAME -n $NAMESPACE \
  --from-literal=role_name=$GOSTINT_RUN_ROLENAME \
  --from-literal=role_id=$GOSTINT_RUN_ROLEID \
  --from-literal=secret_id=$GOSTINT_RUN_SECRET_ID

kubectl label secret -n $NAMESPACE \
  $GOSTINT_RUN_ROLE_SECRET_NAME \
  app="${RELEASE}-gostint-init"

kubectl label secret -n $NAMESPACE \
  --overwrite \
  $GOSTINT_RUN_ROLE_SECRET_NAME \
  app="${RELEASE}-gostint-init"

# echo "=== Creating gostint-mongodb-auth token =================="
# DB_AUTH_TOKEN=$(
# kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh <<EOF
# export VAULT_SKIP_VERIFY=1
# export VAULT_TOKEN=$ROOT_KEY
# vault token create -policy=gostint-mongodb-auth -format=yaml | grep "^[ ]*client_token:" | awk '{print \$2;}'
# EOF
# )

# echo "=== Deleting existing gostint gostint-mongodb-auth secret "
# kubectl delete secret -n $NAMESPACE $DBTOKEN_SECRET_NAME --ignore-not-found=true

# echo "=== Creating gostint gostint-mongodb-auth secret ========="
# kubectl create secret generic $DBTOKEN_SECRET_NAME -n $NAMESPACE --from-literal=token=$DB_AUTH_TOKEN
# kubectl label secret -n $NAMESPACE \
#   $DBTOKEN_SECRET_NAME \
#   app="${RELEASE}-gostint-init"
# kubectl label secret -n $NAMESPACE \
#   --overwrite \
#   $DBTOKEN_SECRET_NAME \
#   app="${RELEASE}-gostint-init"

echo "=== Creating gostint self-signed cert ===================="
T_DIR=$(mktemp -d /tmp/gostint.XXXXXXXXX)
openssl req  -nodes -new -x509  \
  -subj "/C=GB/ST=Lancs/L=Cloud/O=GoStint/CN=${RELEASE}-gostint" \
  -keyout $T_DIR/key.pem \
  -out $T_DIR/cert.pem \
  -days 365 \
  -reqexts SAN \
  -extensions SAN \
  -config <(cat /etc/ssl/openssl.cnf \
    <(printf "\n[SAN]\nsubjectAltName=DNS:snigostint.default.pod,DNS:*.default.pod"))
openssl x509 -in $T_DIR/cert.pem -text -noout

echo "=== Deleting existing gostint TLS secret "
kubectl delete secret -n $NAMESPACE $GOSTINT_TLS_SECRET_NAME --ignore-not-found=true
kubectl create secret generic $GOSTINT_TLS_SECRET_NAME -n $NAMESPACE \
  --from-file=$T_DIR/key.pem \
  --from-file=$T_DIR/cert.pem

echo "=== Deleting existing gostint TLS secret for ingress"
# Note: the Cert's SAN wildcards allow this to be used in the SNI ingress
# controller for both raffia and vault - it's purpose there is only to tell the
# ingress it is https by matching the SNI Host name with the SAN wildcard.
kubectl delete secret -n $NAMESPACE snigostint --ignore-not-found=true
kubectl create secret tls snigostint -n $NAMESPACE \
  --key=$T_DIR/key.pem \
  --cert=$T_DIR/cert.pem

kubectl label secret -n $NAMESPACE \
  $GOSTINT_TLS_SECRET_NAME \
  app="${RELEASE}-gostint-init"

kubectl label secret -n $NAMESPACE \
  --overwrite \
  $GOSTINT_TLS_SECRET_NAME \
  app="${RELEASE}-gostint-init"
