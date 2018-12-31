#!/bin/bash -xe

gostint/init/vault-preinit.sh

helm install gostint/ --name aut-op

sleep 30
gostint/init/vault-init.sh aut-op default

sleep 15
gostint/init/gostint-init.sh aut-op default

gostint/init/ingress-init.sh aut-op default
