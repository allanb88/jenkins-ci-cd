# Jenkins CI/CD Pipeline — Docker Hub + Minikube

Mismo escenario que `prueba-gha` pero usando **Jenkins en un contenedor local** en lugar de GitHub Actions.

---

## Arquitectura

```
GitHub Repo
    │
    │  (webhook o polling)
    ▼
┌─────────────────────────────────────────┐
│  Jenkins Container (puerto 8080)        │
│                                         │
│  Pipeline stages:                       │
│  1. Checkout (GitHub)                   │
│  2. Build Docker image                  │ ◄── /var/run/docker.sock
│  3. Push → Docker Hub                   │     (Docker-out-of-Docker)
│  4. kubectl apply -k .kustomize/        │ ◄── ~/.kube/config montado
│  5. kubectl rollout status              │     (acceso a Minikube local)
└─────────────────────────────────────────┘
```

**Diferencia clave con GHA:**
- GHA usaba un `self-hosted runner` para el deploy a Minikube.
- Jenkins corre en tu máquina local, con el socket de Docker y el kubeconfig montados directamente → no necesita runner externo.

---

## Prerequisitos

- Docker instalado y corriendo
- Minikube corriendo (`minikube status`)
- Cuenta en Docker Hub (`allanbs88`)
- Repo en GitHub (nuevo, para este ejercicio)

---

## Paso 1 — Preparar el kubeconfig para uso desde contenedor

Minikube por defecto usa `127.0.0.1` en el kubeconfig, que no es alcanzable desde dentro de un contenedor Docker. Hay que reemplazarlo por la IP real de Minikube.

```bash
# Ver la IP de Minikube
minikube ip
# Ejemplo: 192.168.49.2

# Verificar qué servidor usa tu kubeconfig actualmente
kubectl config view --minify | grep server
# server: https://127.0.0.1:PORT  ← esto NO funcionará desde el contenedor
```

**Solución — crear un kubeconfig con la IP de Minikube:**

```bash
MINIKUBE_IP=$(minikube ip)

# Exportar el kubeconfig actual y reemplazar 127.0.0.1 por la IP real
kubectl config view --raw \
  | sed "s/127.0.0.1/$MINIKUBE_IP/g" \
  > ~/.kube/config-minikube-jenkins

# Verificar
cat ~/.kube/config-minikube-jenkins | grep server
# Debería mostrar: server: https://192.168.49.2:PORT
```

> Si usas `minikube start --driver=docker`, la IP por defecto suele ser `192.168.49.2`.

---

## Paso 2 — Crear namespace en Minikube

```bash
kubectl create namespace prueba
```

---

## Paso 3 — Build de la imagen de Jenkins personalizada

El `Dockerfile.jenkins` añade Docker CLI y kubectl al Jenkins oficial.

```bash
cd /home/allanb/Documentos/DevOps/devops_pelado/githubactions/jenkins

docker build -f Dockerfile.jenkins -t jenkins-devops:latest .
```

> El build tarda ~3-5 minutos la primera vez (descarga la imagen base + Docker CLI + kubectl).

---

## Paso 4 — Levantar Jenkins con docker-compose

```bash
# Si usaste el kubeconfig modificado, actualiza el volumen en docker-compose.yml:
# Cambia ~/.kube por ~/.kube/config-minikube-jenkins:/var/jenkins_home/.kube/config
# (ver nota al final de este paso)

docker compose up -d

# Verificar que arrancó
docker compose logs -f jenkins
# Ctrl+C para salir del log
```

**Obtener la contraseña inicial de Jenkins:**

```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

> Si el volumen tarda en montarse, espera ~30 segundos y vuelve a intentarlo.

**Nota sobre el kubeconfig:** Si creaste `config-minikube-jenkins`, edita `docker-compose.yml` y cambia la línea del volumen de kube:

```yaml
# Antes:
- ~/.kube:/var/jenkins_home/.kube:rw

# Después (si tienes config separado):
- ~/.kube/config-minikube-jenkins:/var/jenkins_home/.kube/config:rw
```

---

## Paso 5 — Configurar Jenkins UI

Abre: http://localhost:8080

### 5.1 — Setup inicial
1. Pega la contraseña del paso anterior
2. Selecciona **"Install suggested plugins"** y espera
3. Crea usuario admin (o usa el admin inicial)

### 5.2 — Instalar plugins adicionales
Ve a: **Manage Jenkins → Plugins → Available plugins**

Busca e instala:
- ` ` — permite usar `docker.build()` y `docker.withRegistry()` en Jenkinsfile
- `GitHub` — integración con webhooks de GitHub (ya suele venir instalado)
- `Pipeline` — ya instalado por defecto

Reinicia Jenkins tras instalar.

---

## Paso 6 — Configurar credenciales en Jenkins

Ve a: **Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

### 6.1 — Credenciales Docker Hub

| Campo | Valor |
|-------|-------|
| Kind | Username with password |
| Scope | Global |
| Username | `allanbs88` |
| Password | tu contraseña o token de Docker Hub |
| ID | `dockerhub-credentials` ← **exacto, el Jenkinsfile usa este ID** |
| Description | Docker Hub credentials |

> Para generar un token en Docker Hub: https://hub.docker.com/settings/security → New Access Token

### 6.2 — Credenciales GitHub (opcional, si el repo es privado)

| Campo | Valor |
|-------|-------|
| Kind | Username with password |
| Username | tu usuario de GitHub |
| Password | Personal Access Token de GitHub |
| ID | `github-credentials` |

> Para generar token: GitHub → Settings → Developer settings → Personal access tokens → repo scope

---

## Paso 7 — Crear el repo en GitHub y subir el código

```bash
cd /home/allanb/Documentos/DevOps/devops_pelado/githubactions/jenkins

git init
git add Dockerfile index.html .kustomize/ Jenkinsfile
git commit -m "Initial commit - Jenkins pipeline setup"

# Crear repo en GitHub (con gh CLI o manualmente)
gh repo create prueba-jenkins --public --source=. --push

# O manualmente:
# git remote add origin https://github.com/TU_USUARIO/prueba-jenkins.git
# git push -u origin main
```

---

## Paso 8 — Crear el Pipeline en Jenkins

Ve a: **Dashboard → New Item**

1. Nombre: `prueba-jenkins`
2. Tipo: **Pipeline**
3. Click OK

### Configuración del Pipeline:

**General:**
- Marca ✅ `GitHub project` → URL: `https://github.com/TU_USUARIO/prueba-jenkins`

**Build Triggers** (elige uno):
- Opción A — **Webhook** (recomendado): marca `GitHub hook trigger for GITScm polling`
- Opción B — **Polling**: marca `Poll SCM` → Schedule: `H/5 * * * *` (cada 5 min)

**Pipeline:**
- Definition: `Pipeline script from SCM`
- SCM: `Git`
- Repository URL: `https://github.com/TU_USUARIO/prueba-jenkins.git`
- Credentials: las del paso 6.2 (si repo privado) o ninguna (si público)
- Branch: `*/main`
- Script Path: `Jenkinsfile`

Click **Save**.

---

## Paso 9 — Configurar Webhook en GitHub (para trigger automático)

> Solo necesario si elegiste la Opción A de Webhook.

Para que GitHub llegue a tu Jenkins local, necesitas exponer el puerto 8080. Opciones:

**Opción A — ngrok (más simple para pruebas):**

```bash
# Instalar ngrok si no lo tienes
# https://ngrok.com/download

ngrok http 8080
# Te da una URL pública tipo: https://abc123.ngrok.io
```

En GitHub → Tu repo → Settings → Webhooks → Add webhook:
- Payload URL: `https://abc123.ngrok.io/github-webhook/`
- Content type: `application/json`
- Events: `Just the push event`
- Active: ✅

**Opción B — Polling sin webhook:**
No necesitas configurar nada en GitHub. Jenkins revisa el repo cada 5 minutos y lanza el pipeline si hay cambios.

---

## Paso 10 — Primer run manual

Antes de hacer push, prueba que todo funciona:

**Dashboard → prueba-jenkins → Build Now**

Sigue el log en tiempo real con: **Build #1 → Console Output**

Verás algo así:
```
[Pipeline] stage: Checkout
Cloning repository https://github.com/...
[Pipeline] stage: Build Docker Image
Building image: allanbs88/prueba-jenkins:abc1234
[Pipeline] stage: Push to Docker Hub
Pushing allanbs88/prueba-jenkins:abc1234
[Pipeline] stage: Deploy to Minikube
deployment.apps/prueba-jenkins configured
[Pipeline] stage: Verify Deployment
deployment "prueba-jenkins" successfully rolled out
```

---

## Paso 11 — Verificar el deploy en Minikube

```bash
# Ver los pods
kubectl get pods -n prueba

# Ver el servicio
kubectl get svc -n prueba

# Acceder a la app (Minikube expone LoadBalancer con tunnel)
minikube service prueba-jenkins -n prueba
```

---

## Paso 12 — Probar el pipeline completo (trigger automático)

```bash
cd /home/allanb/Documentos/DevOps/devops_pelado/githubactions/jenkins

# Hacer un cambio en index.html
echo "Hola desde Jenkins pipeline v2" > index.html

git add index.html
git commit -m "Update index.html - trigger jenkins pipeline"
git push
```

Si el webhook está configurado, Jenkins lanzará el pipeline automáticamente en segundos.
Si usas polling, esperará hasta el próximo ciclo (máx 5 min).

---

## Estructura de archivos del proyecto

```
jenkins/
├── Dockerfile              ← imagen de la app (nginx + index.html)
├── Dockerfile.jenkins      ← imagen de Jenkins con Docker CLI + kubectl
├── docker-entrypoint.sh    ← fix de permisos de docker socket en runtime
├── docker-compose.yml      ← levantar Jenkins localmente
├── Jenkinsfile             ← definición del pipeline CI/CD
├── index.html              ← contenido de la app web
└── .kustomize/
    ├── deployment.yaml     ← Kubernetes Deployment
    ├── kustomization.yaml  ← Kustomize config
    └── service.yaml        ← Kubernetes Service (LoadBalancer)
```

---

## Comparativa GitHub Actions vs Jenkins

| Aspecto | GitHub Actions | Jenkins |
|---------|---------------|---------|
| Infraestructura CI | GitHub cloud (gratis) | Contenedor local (tú lo mantienes) |
| Deploy a Minikube | Self-hosted runner en tu máquina | Jenkins tiene acceso directo (mismo host) |
| Trigger | Push automático via GitHub | Webhook o polling |
| Credenciales | GitHub Secrets | Jenkins Credentials |
| Pipeline definido en | `.github/workflows/*.yml` | `Jenkinsfile` (Groovy DSL) |
| Docker build | `docker/build-push-action` | `docker.build()` + `docker.withRegistry()` |

---

## Troubleshooting

### "permission denied while trying to connect to the Docker daemon socket"
```bash
# Verificar que el socket está montado y los permisos son correctos
docker exec jenkins ls -la /var/run/docker.sock
docker exec jenkins docker version
```

### "Unable to connect to the server" (kubectl no conecta a Minikube)
```bash
# Verificar desde el contenedor
docker exec jenkins kubectl config view
docker exec jenkins kubectl get nodes
# Si falla, el problema es el server IP — repetir Paso 1
```

### Webhook no llega a Jenkins local
- Verifica que ngrok está corriendo y la URL es correcta
- La URL del webhook debe terminar en `/github-webhook/` (con barra final)
- En Jenkins: Manage Jenkins → System Log → busca errores de GitHub webhook

### El pipeline no encuentra las credenciales de Docker Hub
- Ve a Credentials y verifica que el ID sea exactamente `dockerhub-credentials`
- El Jenkinsfile usa ese ID en `docker.withRegistry(..., 'dockerhub-credentials')`
