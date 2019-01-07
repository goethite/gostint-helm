#!/bin/bash -e
# From https://github.com/ReadyTalk/vault-helm-chart/blob/master/init/vault-init.sh

RELEASE=${RELEASE:-aut-op}
NAMESPACE=${NAMESPACE:-default}
CHART_NAME="gostint"
COMPONENT="${RELEASE}-vault"
ADD_SECRET=${1-"true"}

SECRET_NAME="$RELEASE-vault-keys"

LABELS=$(kubectl get secret -l release=$RELEASE -n $NAMESPACE --show-labels | sed -n 2p | awk '{print $5}' | sed 's/\,/ /g' | grep "app=vault") || /bin/true

# Wait for a vault pod
echo "Waiting for vault a pod..."
FIRST_VAULT_POD=""
for i in $(seq 1 200)
do
  FIRST_VAULT_POD=$(kubectl get pod -l app=vault,release=$RELEASE -n $NAMESPACE | awk '{if(NR==2)print $1}')
  if [ "$FIRST_VAULT_POD" != "" ]
  then
    break
  fi
  sleep 5
done
if [ "$FIRST_VAULT_POD" == "" ]
then
  echo "ERROR: Timed out waiting for a vault POD to appear" >&2
  exit 1
fi

# Wait for vault container to start instead of sleeping ->
echo "Waiting for vault container to start in pod..."
for i in $(seq 1 200)
do
  kubectl exec -n $NAMESPACE $FIRST_VAULT_POD -c vault /bin/true 2>/dev/null && break
  sleep 5
done

# wait for vault api to become available
echo "Waiting for vault api..."
kubectl exec -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh -c '
for i in $(seq 1 200)
do
   nc -z -w3 127.0.0.1 8200 && \
    { sleep 15; exit 0; } || sleep 5
done
echo "Timed out waiting for vault api to become available" >&2
exit 1
'

echo "Checking if vault already initialised"
if
  kubectl exec -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh -c '
wget -O- https://127.0.0.1:8200/v1/sys/health --no-check-certificate 2>&1 | grep "501 Not Implemented"
' 2>/dev/null
then
  :
else
  echo "Vault already initialised"
  exit 0
fi

# echo "FIRST_VAULT_POD: $FIRST_VAULT_POD"
INIT_MESSAGE=$(kubectl exec -n $NAMESPACE $FIRST_VAULT_POD -c vault -- sh -c "vault operator init --tls-skip-verify" 2>&1)

KEYS=""
if [[ ${INIT_MESSAGE} != *"Error initializing Vault"* && "${ADD_SECRET}" == "true"  ]]; then
  echo
  echo
  echo "Deleting existing Vault key secret"
  kubectl delete secret -n $NAMESPACE $SECRET_NAME --ignore-not-found=true
  echo "Creating Vault key secret: $SECRET_NAME"
  KEYS=$(echo "$INIT_MESSAGE" | grep "Unseal Key" | awk '{print $4}')
  ROOTKEY=$(echo "$INIT_MESSAGE" | grep "Initial Root Token" | awk '{print $4}')
  CREATE_SECRET_COMMAND="kubectl create secret generic $SECRET_NAME -n $NAMESPACE "
  COUNT=1
  for i in $KEYS;
  do
    CREATE_SECRET_COMMAND="$CREATE_SECRET_COMMAND --from-literal=key$COUNT=$i"
    COUNT=$((COUNT+1))
  done
  CREATE_SECRET_COMMAND="$CREATE_SECRET_COMMAND --from-literal=rootkey=$ROOTKEY"
  $(echo $CREATE_SECRET_COMMAND)
  kubectl label secret -n $NAMESPACE \
    $SECRET_NAME \
    $LABELS app="${RELEASE}-vault-init"
  kubectl label secret -n $NAMESPACE \
    --overwrite \
    $SECRET_NAME \
    app="${RELEASE}-vault-init"

  sleep 30 # pods may restart port 8200 after init
fi
