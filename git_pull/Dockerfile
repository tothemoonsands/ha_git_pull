ARG BUILD_FROM
FROM $BUILD_FROM

# Setup base
RUN apk add --no-cache jq curl git openssh-client python3 py3-yaml

# Copy data
COPY data/run.sh data/git-reconcile.sh data/automation-equivalent.py /

CMD [ "/run.sh" ]
