#!/bin/bash -e

if [ $# -lt 3 ]
  then
    echo "Invalid arguments provided"
    echo "Valid usage: "`basename "$0"`" <release-name> <namespace> <port>"
    exit 1
fi

RELEASE=$1
NAMESPACE=$2
PORT=$3

echo "Getting root key from Kubernetes secret"
TOKEN=$(kubectl get secret -n $NAMESPACE ${SECRET_NAME} -o yaml | grep -e "^[ ]*rootkey:" | awk '{print $2}' | base64 --decode)

FIRST_VAULT_POD=$(kubectl get po -l app=vault,release=$RELEASE -n $NAMESPACE | awk '{if(NR==2)print $1}')
echo "FIRST_VAULT_POD: $FIRST_VAULT_POD"

kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
vault login $TOKEN
EOF

# Get secretId for the approle
WRAPSECRETID=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF | jq .wrap_info.token -r
vault write -wrap-ttl=144h -f auth/approle/role/gostint-role/secret-id -format=json
EOF
)
echo "WRAPSECRETID: $WRAPSECRETID" >&2

QNAME=$(cat ./0100.json | jq .qname -r)

# encrypt job payload using vault transit secret engine
B64=$(base64 < ./0100.json)
E=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF | jq .data.ciphertext -r
vault write transit/encrypt/gostint plaintext="$B64" -format=json
EOF
)
echo "E: $E"

# Put encrypted payload in a cubbyhole of an ephemeral token
CUBBYTOKEN=$(
kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF | jq .auth.client_token -r
vault token create -policy=default -ttl=60m -use-limit=2 -format=json
EOF
)
echo "CUBBYTOKEN: $CUBBYTOKEN" >&2

kubectl exec -i -n $NAMESPACE $FIRST_VAULT_POD -- sh -x <<EOF
VAULT_TOKEN=$CUBBYTOKEN vault write cubbyhole/job payload="$E" >&2 || exit 1
EOF

# Create new job request with encrypted payload
T_DIR=$(mktemp -d /tmp/gostint.XXXXXXXXX)
jq --arg qname "$QNAME" \
   --arg cubby_token "$CUBBYTOKEN" \
   --arg cubby_path "cubbyhole/job" \
   --arg wrap_secret_id "$WRAPSECRETID" \
   '. | .qname=$qname | .cubby_token=$cubby_token | .cubby_path=$cubby_path | .wrap_secret_id=$wrap_secret_id' \
   <<<'{}' >$T_DIR/0100.json
cat $T_DIR/0100.json

J="$(curl -k -s https://127.0.0.1:${PORT}/v1/api/job --header "X-Auth-Token: $TOKEN" -X POST -d @$T_DIR/0100.json)"
echo "J: $J"

ID=$(echo $J | jq ._id -r)
echo "ID:$ID"

status="queued"
  for i in {1..20}
  do
    sleep 1
    R="$(curl -k -s https://127.0.0.1:${PORT}/v1/api/job/$ID --header "X-Auth-Token: $TOKEN")"
    echo "R:$R" >&2
    status=$(echo $R | jq .status -r)
    if [ "$status" != "queued" -a "$status" != "running" ]
    then
      break
    fi
  done
echo "status after:$status"
