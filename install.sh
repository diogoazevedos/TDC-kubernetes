#!/bin/bash

#Terraform
(cd terraform; terraform apply)

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

./templates/kubelet.service.sh ${MASTER_PUBLIC_IP}
./templates/kube-proxy.service.sh ${MASTER_PUBLIC_IP}
./templates/kubeconfig.sh ${MASTER_PUBLIC_IP}
./templates/docker.service.sh


for MINION_IP in $(echo $MINION_PUBLIC_IPS | sed "s/,/ /g")
do
  echo "$MINION_IP"
  ssh-keygen -R ${MINION_IP}
  ssh-keyscan -H ${MINION_IP} >> ~/.ssh/known_hosts

  scp -i ~/.ssh/TDC.pem keys/* ubuntu@${MINION_IP}:/tmp
  scp -i ~/.ssh/TDC.pem tmp/kubelet.service ubuntu@${MINION_IP}:/tmp
  scp -i ~/.ssh/TDC.pem tmp/kube-proxy.service ubuntu@${MINION_IP}:/tmp
  scp -i ~/.ssh/TDC.pem tmp/kubeconfig ubuntu@${MINION_IP}:/tmp
  scp -i ~/.ssh/TDC.pem tmp/docker.service ubuntu@${MINION_IP}:/tmp

  ssh -i ~/.ssh/TDC.pem ubuntu@${MINION_IP} 'bash -s' < scripts/minion.sh
done


./templates/kube-dns.yaml.sh ${MASTER_PUBLIC_IP}
scp -i ~/.ssh/TDC.pem tmp/kube-dns.yaml ubuntu@${MASTER_PUBLIC_IP}:/tmp
ssh -i ~/.ssh/TDC.pem ubuntu@${MASTER_PUBLIC_IP} 'bash -s' < scripts/kube-dns.sh
ssh -i ~/.ssh/TDC.pem ubuntu@${MASTER_PUBLIC_IP} 'bash -s' < scripts/routes.sh
scp -i ~/.ssh/TDC.pem ubuntu@${MASTER_PUBLIC_IP}:/tmp/routes tmp/

ROUTE_TABLE_ID=$(cd terraform; terraform output route_table_id)

aws ec2 describe-route-tables --route-table-id "${ROUTE_TABLE_ID}" --filters "Name=route.state,Values=blackhole" --query 'RouteTables[0].Routes[?State == `blackhole`]' | jq -r ".[].DestinationCidrBlock" | while read cidr ; do
  aws ec2 delete-route --route-table-id "${ROUTE_TABLE_ID}" --destination-cidr-block "$cidr"
done

cat tmp/routes | tr " " "\n" |  while read item ; do
  IP=$(echo $item | cut -d ',' -f 1)
  CIDR=$(echo $item | cut -d ',' -f 2)
  NETWORK_INTERFACE=$(aws ec2 describe-instances --filters "Name=private-ip-address,Values=$IP" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
  echo "$NETWORK_INTERFACE - $IP - $CIDR"
  aws ec2 create-route --route-table-id "${ROUTE_TABLE_ID}" --network-interface-id $NETWORK_INTERFACE --destination-cidr-block "$CIDR"
done
