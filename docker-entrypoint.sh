#!/bin/bash
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "999")
groupmod -g "$DOCKER_GID" docker 2>/dev/null || groupadd -g "$DOCKER_GID" docker
usermod -aG docker jenkins 2>/dev/null || true

if [ -d /var/jenkins_home/.kube ]; then
    chown -R jenkins:jenkins /var/jenkins_home/.kube 2>/dev/null || true
fi

exec /usr/sbin/gosu jenkins /usr/local/bin/jenkins.sh "$@"
