MASTER_PUBLIC_IP=$1

cat > tmp/kube-dns.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.100.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP

---

apiVersion: v1
kind: ReplicationController
metadata:
  name: kube-dns-v20
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    version: v20
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  selector:
    k8s-app: kube-dns
    version: v20
  template:
    metadata:
      labels:
        k8s-app: kube-dns
        version: v20
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: kubedns
        image: gcr.io/google_containers/kubedns-amd64:1.8
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthz-kubedns
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=cluster.local.
        - --dns-port=10053
        - --kube-master-url=http://${MASTER_PUBLIC_IP}:8080
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        lifecycle:
          postStart:
            exec:
              command:
                - "sh"
                - "-c"
                - >
                  printf "nameserver 172.21.0.2\n" > /etc/resolv.conf
      - name: dnsmasq
        image: gcr.io/google_containers/kube-dnsmasq-amd64:1.4
        livenessProbe:
          httpGet:
            path: /healthz-dnsmasq
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --cache-size=1000
        - --no-resolv
        - --server=127.0.0.1#10053
        - --log-facility=-
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
      - name: healthz
        image: gcr.io/google_containers/exechealthz-amd64:1.2
        resources:
          limits:
            memory: 50Mi
          requests:
            cpu: 10m
            memory: 50Mi
        args:
        - --cmd=nslookup kubernetes.default.svc.cluster.local 127.0.0.1 >/dev/null
        - --url=/healthz-dnsmasq
        - --cmd=nslookup kubernetes.default.svc.cluster.local 127.0.0.1:10053 >/dev/null
        - --url=/healthz-kubedns
        - --port=8080
        - --quiet
        ports:
        - containerPort: 8080
          protocol: TCP
      dnsPolicy: Default
EOF
