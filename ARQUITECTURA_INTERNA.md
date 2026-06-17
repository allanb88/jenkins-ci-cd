# Arquitectura interna del contenedor Jenkins y su conexión a Minikube

---

## 1. Cómo se construye el contenedor Jenkins

La imagen base es `jenkins/jenkins:lts-jdk17` — Jenkins oficial sin capacidad de correr Docker ni kubectl. El `Dockerfile.jenkins` le añade dos herramientas:

### Docker CLI
Jenkins necesita construir y subir imágenes Docker. Para eso se instala solo el cliente de Docker (`docker-ce-cli`), no el daemon. El daemon real es el del host.

```
Host
└── Docker daemon (/var/run/docker.sock)
      ▲
      │ socket montado
      │
Contenedor Jenkins
└── Docker CLI  ──────────────────► habla con el daemon del host
```

Este patrón se llama **Docker-out-of-Docker (DooD)**: el cliente está dentro del contenedor pero ejecuta los comandos en el Docker del host.

### kubectl
Se descarga el binario directamente de `dl.k8s.io` y se instala en `/usr/local/bin/kubectl`. Con esto el contenedor puede hablar con cualquier cluster de Kubernetes al que tenga acceso.

### Grupo docker
Durante el build se crea el grupo `docker` dentro de la imagen y se añade el usuario `jenkins` a ese grupo:
```dockerfile
RUN groupadd -f docker && usermod -aG docker jenkins
```
Esto es necesario para que Jenkins pueda usar el socket de Docker sin ser root.

---

## 2. El problema del socket de Docker y cómo lo resuelve el entrypoint

El socket `/var/run/docker.sock` del host tiene un GID específico (en este sistema: `969`). Cuando se monta en el contenedor, el grupo `docker` dentro del contenedor tiene GID `999` — no coincide, Jenkins no puede acceder.

El `docker-entrypoint.sh` resuelve esto en runtime, antes de arrancar Jenkins:

```bash
# 1. Leer el GID real del socket en el host
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

# 2. Cambiar el GID del grupo "docker" dentro del contenedor para que coincida
groupmod -g "$DOCKER_GID" docker

# 3. Asegurar que jenkins está en ese grupo
usermod -aG docker jenkins

# 4. Arreglar permisos del kubeconfig
chown -R jenkins:jenkins /var/jenkins_home/.kube

# 5. Bajar de root a jenkins y arrancar Jenkins
exec /usr/sbin/gosu jenkins /usr/local/bin/jenkins.sh
```

El entrypoint corre como `root` (necesita modificar grupos del sistema), y `gosu` hace el switch a `jenkins` antes de arrancar el proceso principal. Jenkins nunca corre como root.

### Por qué SELinux requería configuración extra

En Fedora, SELinux está en modo `Enforcing`. El socket tiene el label `container_var_run_t` y SELinux bloqueaba el acceso desde dentro del contenedor incluso con los GIDs correctos. La solución fue añadir al `docker-compose.yml`:

```yaml
security_opt:
  - label:disable
```

Esto desactiva el etiquetado SELinux para el contenedor Jenkins, permitiendo el acceso al socket montado.

---

## 3. Cómo se conecta Jenkins a Minikube

### El kubeconfig

El archivo `~/.kube/config` del host contiene toda la información para conectarse al cluster:
- La URL del API server: `https://192.168.49.2:8443`
- Las rutas a los certificados TLS de Minikube

Este archivo se monta en el contenedor en:
```
~/.kube  →  /var/jenkins_home/.kube
```

Cuando `kubectl` corre dentro del contenedor, lee `/var/jenkins_home/.kube/config` (definido en la variable de entorno `KUBECONFIG`).

### El problema de los certificados

El kubeconfig referencia los certificados por ruta absoluta del host:
```yaml
certificate-authority: /home/allanb/.minikube/ca.crt
client-certificate: /home/allanb/.minikube/profiles/minikube/client.crt
client-key: /home/allanb/.minikube/profiles/minikube/client.key
```

Esas rutas no existen dentro del contenedor. La solución fue montar el directorio `.minikube` en la misma ruta:
```
/home/allanb/.minikube  →  /home/allanb/.minikube  (read-only)
```

Así `kubectl` dentro del contenedor encuentra los certificados exactamente donde el kubeconfig dice que están.

### El problema de red

Minikube con driver `docker` corre como un contenedor dentro de una red Docker propia llamada `minikube` (`192.168.49.0/24`). El contenedor Jenkins estaba en la red `default` de Docker Compose y no tenía ruta a `192.168.49.2`.

La solución fue conectar Jenkins a ambas redes en `docker-compose.yml`:
```yaml
networks:
  - default    # red normal de Docker Compose
  - minikube   # red de Minikube (externa, ya existente)
```

Con esto, Jenkins puede hacer TCP a `192.168.49.2:8443` donde escucha el API server de Kubernetes.

---

## 4. Flujo completo del stage "Deploy to Minikube"

```
Jenkinsfile ejecuta:
kubectl apply -k .kustomize/ -n prueba
kubectl set image deployment/prueba-jenkins ...

    │
    ▼
kubectl (dentro del contenedor Jenkins)
    │  lee  /var/jenkins_home/.kube/config
    │  lee  /home/allanb/.minikube/ca.crt          (TLS: verifica el servidor)
    │  lee  /home/allanb/.minikube/profiles/minikube/client.crt  (TLS: se autentica)
    │  lee  /home/allanb/.minikube/profiles/minikube/client.key
    │
    │  conexión TCP por red "minikube"
    ▼
API Server de Minikube — https://192.168.49.2:8443
    │
    ▼
Kubernetes aplica los manifiestos de .kustomize/
(Deployment, Service) en el namespace "prueba"
```

---

## 5. Mapa completo de volúmenes y redes

```
docker-compose.yml monta:

Volúmenes:
  jenkins_home (Docker volume)  →  /var/jenkins_home       persistencia de Jenkins
  /var/run/docker.sock          →  /var/run/docker.sock    acceso al daemon Docker del host
  /home/allanb/.kube            →  /var/jenkins_home/.kube kubeconfig
  /home/allanb/.minikube        →  /home/allanb/.minikube  certificados TLS de Minikube

Redes:
  default (bridge)   →  acceso a internet, Docker Hub
  minikube (bridge)  →  acceso a 192.168.49.2 (API server de Minikube)

Security:
  label:disable      →  desactiva restricciones SELinux para el contenedor
```

---

## 6. Resumen visual completo

```
┌─────────────────────────────────────────────────────────────┐
│  HOST (Fedora)                                              │
│                                                             │
│  /var/run/docker.sock (GID 969)                             │
│  /home/allanb/.kube/config                                  │
│  /home/allanb/.minikube/  (certs TLS)                       │
│                                                             │
│  ┌─────────────────────────────┐   ┌─────────────────────┐  │
│  │  Contenedor Jenkins         │   │  Contenedor Minikube │  │
│  │  (red default + minikube)   │   │  192.168.49.2        │  │
│  │                             │   │  puerto 8443         │  │
│  │  entrypoint (root):         │   │                      │  │
│  │  - ajusta GID docker        │   │  API Server K8s      │  │
│  │  - gosu → jenkins           │   │                      │  │
│  │                             │   │  Namespace: prueba   │  │
│  │  Jenkins pipeline:          │   │  - Deployment        │  │
│  │  1. git clone               │   │  - Service           │  │
│  │  2. docker build ──────────►│──►│  Docker daemon       │  │
│  │  3. docker push → Hub       │   │  (imagen en DockerHub│  │
│  │  4. kubectl apply ─────────►│──►│  API Server K8s      │  │
│  │  5. kubectl rollout status  │   │                      │  │
│  └─────────────────────────────┘   └─────────────────────┘  │
│                                                             │
│  Docker Hub (internet)  ◄── push imagen en paso 3          │
└─────────────────────────────────────────────────────────────┘
```
