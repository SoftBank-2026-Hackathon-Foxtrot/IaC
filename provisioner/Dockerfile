# Provisioner: the HTTP API plus Terraform and this repository's roots and modules.
# Build from the repository root:
#   docker buildx build --platform linux/amd64 -f provisioner/Dockerfile -t <registry>/provisioner:<tag> .
FROM python:3.12-slim
ARG TERRAFORM_VERSION=1.12.2
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip ca-certificates git openssh-client \
 && curl -fsSL -o /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
 && unzip /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip \
 && apt-get purge -y unzip && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 10001 app && useradd -u 10001 -g 10001 -m app
WORKDIR /srv
COPY requirements-onprem.txt requirements-observability.txt ./
RUN pip install --no-cache-dir -r requirements-onprem.txt -r requirements-observability.txt
COPY ansible ansible
COPY environments/aws environments/aws
COPY environments/gcp environments/gcp
COPY modules modules
COPY tools tools
COPY catalog catalog
COPY provisioner provisioner
ENV PYTHONUNBUFFERED=1 TF_PLUGIN_CACHE_DIR=/var/lib/foxtrot-provisioner/plugin-cache TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true
USER 10001:10001
EXPOSE 8070
ENTRYPOINT ["sh", "-c", "mkdir -p \"$TF_PLUGIN_CACHE_DIR\" && exec python -m provisioner \"$@\"", "provisioner"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8070"]
