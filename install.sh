#!/bin/bash

#Terraform
#(cd terraform; terraform apply)

#ETCD
ETCD_PUBLIC_IP=$(cd terraform; terraform output etcd_public_ip)

echo "Waiting for etcd server to reply on port 22"
until [ $(nc -z $ETCD_PUBLIC_IP 22; echo "$?") == 0 ]; do
    printf '.'
    sleep 1
done;
printf '\n'

ssh-keygen -R ${ETCD_PUBLIC_IP}
ssh-keyscan -H ${ETCD_PUBLIC_IP} >> ~/.ssh/known_hosts
ssh -i ~/.ssh/TDC.pem ubuntu@${ETCD_PUBLIC_IP} 'bash -s' < scripts/docker.sh
ssh -i ~/.ssh/TDC.pem ubuntu@${ETCD_PUBLIC_IP} 'bash -s' < scripts/etcd.sh


#MASTER
MASTER_PUBLIC_IP=$(cd terraform; terraform output master_public_ip)
ssh-keygen -R ${MASTER_PUBLIC_IP}
ssh-keyscan -H ${MASTER_PUBLIC_IP} >> ~/.ssh/known_hosts

./scripts/certificates.sh ${MASTER_PUBLIC_IP}
scp -i ~/.ssh/TDC.pem keys/* ubuntu@${MASTER_PUBLIC_IP}:/tmp
scp -i ~/.ssh/TDC.pem files/master/* ubuntu@${MASTER_PUBLIC_IP}:/tmp

mkdir -p tmp
./templates/kube-apiserver.service.sh ${ETCD_PUBLIC_IP} ${MASTER_PUBLIC_IP}
scp -i ~/.ssh/TDC.pem tmp/kube-apiserver.service ubuntu@${MASTER_PUBLIC_IP}:/tmp

./templates/kube-controller-manager.service.sh ${MASTER_PUBLIC_IP}
scp -i ~/.ssh/TDC.pem tmp/kube-controller-manager.service ubuntu@${MASTER_PUBLIC_IP}:/tmp

./templates/kube-scheduler.service.sh ${MASTER_PUBLIC_IP}
scp -i ~/.ssh/TDC.pem tmp/kube-scheduler.service ubuntu@${MASTER_PUBLIC_IP}:/tmp


ssh -i ~/.ssh/TDC.pem ubuntu@${MASTER_PUBLIC_IP} 'bash -s' < scripts/master.sh

#MINIONS
MINION_PUBLIC_IPS=$(cd terraform; terraform output minion_public_ips)


for MINION_IP in $(echo $MINION_PUBLIC_IPS | sed "s/,/ /g")
do
    ssh-keygen -R ${MINION_IP}
    ssh-keyscan -H ${MINION_IP} >> ~/.ssh/known_hosts

    scp -i ~/.ssh/TDC.pem keys/* ubuntu@${MINION_IP}:/tmp
    echo "$MINION_IP"
done
