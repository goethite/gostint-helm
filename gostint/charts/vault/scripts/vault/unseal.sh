#!/bin/bash -x

(
sleep 10

# wait for vault api to become available
echo "Waiting for vault api..."
(
  for i in $(seq 1 200)
  do
    nc -z -w3 127.0.0.1 8200 && \
    { sleep 5; exit 0; } || sleep 5
  done
  echo "Timed out waiting for vault api to become available" >&2
  exit 1
) || exit 1

KUBE_TOKEN=`cat /var/run/secrets/kubernetes.io/serviceaccount/token`
# wait for vault to be initialised and get unseal keys
for i in $(seq 1 200)
do
  SEC=`curl -sSk -H "Authorization: Bearer $KUBE_TOKEN" https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/namespaces/default/secrets/aut-op-vault-keys`
  echo "$SEC" | jq
  STATUS=`jq .status -r <<< "$SEC"`
  if [ "$STATUS" == "Failure" ]
  then
    echo "ERROR: Get for vault keys secret failed, has vault-init.sh run/failed?" >&2
  else
    break
  fi
  sleep 5
done

KEY1=`echo $SEC | jq -r .data.key1 | base64 -d`
KEY2=`echo $SEC | jq -r .data.key2 | base64 -d`
KEY3=`echo $SEC | jq -r .data.key3 | base64 -d`

if [ "$KEY1" == "" -o "$KEY2" == "" -o "$KEY3" == ""]
then
  echo "ERROR: Failed to get quorum of unseal keys" >&2
  exit 1
fi

for i in $(seq 1 3)
do
  eval vault operator unseal --tls-skip-verify \$KEY$i || exit 1
done
) </dev/null >/tmp/unseal.log 2>&1 &
disown
disown -a

exit 0
