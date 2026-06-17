pipeline {
    agent any

    environment {
        DOCKER_IMAGE    = "allanbs88/prueba-jenkins"
        DOCKER_TAG      = "${GIT_COMMIT}"
        K8S_NAMESPACE   = "prueba"
        K8S_DEPLOYMENT  = "prueba-jenkins"
        KUBECONFIG      = "/var/jenkins_home/.kube/config"
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                echo "Commit: ${GIT_COMMIT}"
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    dockerImage = docker.build("${DOCKER_IMAGE}:${DOCKER_TAG}")
                }
            }
        }

        stage('Push to Docker Hub') {
            steps {
                script {
                    docker.withRegistry('https://registry-1.docker.io/v2/', 'dockerhub-credentials') {
                        dockerImage.push("${DOCKER_TAG}")
                        dockerImage.push("latest")
                    }
                }
            }
        }

        stage('Deploy to Minikube') {
            steps {
                sh """
                    kubectl apply -k .kustomize/ -n ${K8S_NAMESPACE}
                    kubectl set image deployment/${K8S_DEPLOYMENT} \
                        ${K8S_DEPLOYMENT}=${DOCKER_IMAGE}:${DOCKER_TAG} \
                        -n ${K8S_NAMESPACE}
                """
            }
        }

        stage('Verify Deployment') {
            steps {
                sh "kubectl rollout status deployment/${K8S_DEPLOYMENT} -n ${K8S_NAMESPACE} --timeout=120s"
            }
        }
    }

    post {
        success {
            echo "Pipeline completed. Image: ${DOCKER_IMAGE}:${DOCKER_TAG}"
        }
        failure {
            echo "Pipeline failed at stage: ${currentBuild.result}"
        }
    }
}
