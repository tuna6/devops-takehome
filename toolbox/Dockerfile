FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV K3D_VERSION=v5.9.0
ENV KUBECTL_VERSION=v1.36.2
ENV HELM_VERSION=v4.2.2
ENV TERRAFORM_VERSION=1.15.6
ENV K6_VERSION=v1.8.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl wget tar unzip && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/k3d https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64 && \
    chmod +x /usr/local/bin/k3d

RUN curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl

RUN curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz && \
    tar -C /tmp -xzf /tmp/helm.tar.gz && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -f /tmp/helm.tar.gz

RUN curl -fsSL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    unzip /tmp/terraform.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/terraform && \
    rm -f /tmp/terraform.zip

RUN curl -fsSL -o /tmp/k6.tar.gz https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz && \
    tar -C /tmp -xzf /tmp/k6.tar.gz && \
    mv /tmp/k6-${K6_VERSION}-linux-amd64/k6 /usr/local/bin/k6 && \
    chmod +x /usr/local/bin/k6 && \
    rm -rf /tmp/*

RUN mkdir -p /workspace
WORKDIR /workspace
CMD ["tail", "-f", "/dev/null"]
