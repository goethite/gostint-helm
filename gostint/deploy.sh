#!/bin/bash -e

export RELEASE=${RELEASE:-aut-op}
export NAMESPACE=${NAMESPACE:-default}
export HELM=${HELM:-helm}

ISINSTALL=0
STATUS=$($HELM list $RELEASE -q)
if [ "$STATUS" = "" ]
then
  # install chart
  gostint/init/vault-preinit.sh
  helm install gostint/ \
    --name $RELEASE \
    --namespace $NAMESPACE
  ISINSTALL=1
else
  helm upgrade $RELEASE gostint/ \
    --namespace $NAMESPACE
fi

gostint/init/vault-init.sh

# pods will auto unseal, see postStart lifecycle hook
# so wait for each pod to be unsealed itself
echo "Waiting for all sealed pods to unseal themselves"
(
  for i in $(seq 1 200)
  do
    PODS=$(
      kubectl get pods \
        -l app=vault,release=$RELEASE \
        -n $NAMESPACE \
        | awk '{if(NR>1)print $1}'
    )
    PODS_SEALED=0
    for POD in $PODS
    do
      SEALED_STATUS=$(
        kubectl exec \
          -n $NAMESPACE $POD \
           -c vault \
          -- sh -c "vault status --tls-skip-verify | awk '/^Sealed/ { print \$2; }'" \
          2>&1
      ) || /bin/true
      if [ "$SEALED_STATUS" != "false" ]
      then
        let PODS_SEALED=$PODS_SEALED+1
      fi
    done
    if [ $PODS_SEALED == 0 ]
    then
      exit 0
    fi
    echo -n "."
    sleep 5
  done
  echo "ERROR: Timed out waiting for Vault PODs to unseal themselves" >&2
  exit 1
) || exit 1
echo "All vault pods are unsealed"

if [ $ISINSTALL == 1 ]
then
  # TODO: make idempotent
  gostint/init/gostint-init.sh || exit 1
  gostint/init/ingress-init.sh || exit 1
fi

echo
echo "****************************************"
echo "*** GoStint PoC Helm Chart Deployed! ***"
echo "****************************************"
