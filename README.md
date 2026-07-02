# gitops-team-Ryuk

Repo GitOps du projet fil rouge — Team Ryuk.  
Ce repo est la **source de vérité** pour le déploiement de la [todo-api-python](https://github.com/adouadi28-arch/todo-api-python) sur Kubernetes.

> **Principe GitOps** : tout ce qui tourne dans le cluster est décrit dans ce repo. Si tu veux changer quelque chose dans le cluster, tu modifies un fichier ici et tu pousses. ArgoCD s'occupe du reste. Personne ne tape de commandes `kubectl apply` manuellement en production.

---

## Architecture globale

```
[Developer]
    │
    │  git push sur todo-api-python
    ▼
[GitHub Actions CI/CD]
    │  5 jobs enchaînés :
    │  lint → test → security → docker → update-gitops
    ▼
[GHCR] ghcr.io/adouadi28-arch/todo-api-python:SHA
    │  Image Docker publiée avec le SHA du commit comme tag
    │  (ex: ghcr.io/.../todo-api-python:abc123def456)
    ▼
[gitops-team-Ryuk]  ← CE REPO
    │  Le job update-gitops met à jour automatiquement
    │  le tag d'image dans deployment.yaml et values.yaml
    ▼
[ArgoCD]
    │  Surveille ce repo toutes les 3 minutes
    │  Détecte le nouveau tag → déclenche un sync
    │  prune: true   → supprime les ressources obsolètes
    │  selfHeal: true → re-synchronise si quelqu'un modifie le cluster à la main
    ▼
[Cluster Kubernetes — Docker Desktop]
    ├── todo-api-dev        → Kustomize, 1 replica,  namespace todo-api-dev
    ├── todo-api-staging    → Kustomize, 3 replicas, namespace todo-api-staging
    ├── todo-api-helm-dev   → Helm chart, 1 replica, namespace todo-api-helm-dev
    ├── todo-api-canary     → Argo Rollouts canary,  namespace todo-api-canary
    ├── todo-api-bluegreen  → Argo Rollouts b/g,     namespace todo-api-bluegreen
    ├── monitoring-iac      → namespace créé et géré par Terraform (IaC)
    └── flux-system         → Tofu Controller + source-controller
```

---

## Structure du repo

```
gitops-team-Ryuk/
│
├── apps/
│   │
│   ├── todo-api/                        # Méthode Kustomize
│   │   ├── base/                        # Manifests K8s bruts, sans surcharge d'env
│   │   │   ├── deployment.yaml          # Deployment de base (image, ports, probes)
│   │   │   ├── service.yaml             # Service ClusterIP port 8000
│   │   │   ├── kustomization.yaml       # Déclare les ressources à inclure
│   │   │   └── secrets/
│   │   │       └── sealed-secret.yaml   # Secret chiffré — peut être commité publiquement
│   │   └── overlays/
│   │       ├── dev/                     # Surcharge pour l'env dev
│   │       │   ├── kustomization.yaml   # Référence la base + applique le patch
│   │       │   └── patch-replicas.yaml  # 1 replica, ressources réduites
│   │       └── staging/                 # Surcharge pour l'env staging
│   │           ├── kustomization.yaml
│   │           └── patch-replicas.yaml  # 3 replicas, ressources production
│   │
│   ├── todo-api-helm/                   # Méthode Helm chart
│   │   ├── Chart.yaml                   # Métadonnées du chart (nom, version)
│   │   ├── values.yaml                  # Valeurs par défaut (image, resources, env)
│   │   ├── values-dev.yaml              # Surcharge dev : 1 replica, resources légères
│   │   ├── values-staging.yaml          # Surcharge staging : 2 replicas
│   │   └── templates/
│   │       ├── deployment.yaml          # Template Deployment avec variables Helm
│   │       └── service.yaml             # Template Service avec variables Helm
│   │
│   ├── todo-api-rollout/                # Déploiements progressifs (Argo Rollouts)
│   │   ├── canary/
│   │   │   ├── rollout.yaml             # Stratégie : 20% → pause → 50% → 30s → 100%
│   │   │   └── service.yaml             # Service qui route vers le canary
│   │   └── bluegreen/
│   │       ├── rollout.yaml             # Stratégie : preview + active, promotion manuelle
│   │       └── services.yaml            # 2 services : active (prod) + preview (nouvelle version)
│   │
│   └── argocd-rbac-cm.yaml             # ConfigMap RBAC ArgoCD (3 rôles définis)
│
├── infrastructure/
│   ├── terraform/
│   │   └── main.tf                      # Crée namespace monitoring-iac + Role + RoleBinding
│   ├── gitrepository.yaml               # Dit au Tofu Controller où est le code Terraform
│   └── terraform.yaml                   # Déclenche l'exécution de Terraform dans le cluster
│
├── application.yaml                     # ArgoCD Application → todo-api-dev (Kustomize)
├── application-staging.yaml             # ArgoCD Application → todo-api-staging (Kustomize)
├── application-helm-dev.yaml            # ArgoCD Application → todo-api-helm-dev (Helm)
├── application-canary.yaml              # ArgoCD Application → canary rollout
└── application-bluegreen.yaml           # ArgoCD Application → blue/green rollout
```

---

## Prérequis

| Outil | Version testée | Rôle dans le projet |
|-------|---------------|---------------------|
| Docker Desktop | ≥ 4.x | Fournit le cluster Kubernetes local |
| kubectl | ≥ 1.28 | CLI pour interagir avec le cluster |
| Helm | ≥ 4.x | Déploiement du chart todo-api-helm |
| ArgoCD CLI | ≥ 2.x | Gestion et monitoring des applications ArgoCD |
| kubectl-argo-rollouts | v1.8.3 | Pilotage des déploiements progressifs |
| Flux CLI | ≥ 2.x | Installation du source-controller |
| kubeseal | ≥ 0.27 | Chiffrement des secrets avant commit |

---

## Lancer le projet depuis zéro

### Étape 1 — Cluster Kubernetes

On utilise Kubernetes intégré à Docker Desktop. Pas besoin de k3d ni minikube.

1. Ouvrir Docker Desktop → **Settings → Kubernetes**
2. Cocher **Enable Kubernetes** → **Apply & Restart**
3. Attendre que l'icône Kubernetes devienne verte

```bash
# Pointer kubectl vers le cluster local
kubectl config use-context docker-desktop

# Vérifier que le cluster répond
kubectl get nodes
# Attendu : docker-desktop   Ready   control-plane   ...
```

### Étape 2 — Installer ArgoCD

ArgoCD est le cœur du système GitOps. C'est lui qui surveille ce repo et déploie dans le cluster.

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attendre que tous les pods soient prêts (peut prendre 2-3 minutes)
kubectl wait --for=condition=available deployment --all -n argocd --timeout=300s

# Récupérer le mot de passe admin généré automatiquement
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Accéder à l'UI ArgoCD :
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Ouvrir https://localhost:8080 — login: admin / mot de passe récupéré ci-dessus
```

### Étape 3 — Installer Argo Rollouts

Argo Rollouts étend Kubernetes avec un nouveau type de ressource `Rollout` qui remplace le `Deployment` standard. Il gère les stratégies de déploiement progressif (canary, blue/green) que les Deployments normaux ne savent pas faire.

```bash
kubectl create namespace argo-rollouts

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Installer le plugin kubectl pour piloter les rollouts en ligne de commande
brew install argoproj/tap/kubectl-argo-rollouts

# Vérifier l'installation
kubectl argo rollouts version
```

### Étape 4 — Installer Sealed Secrets

Sealed Secrets résout le problème des secrets dans Git. Un secret Kubernetes normal est encodé en base64 — ce n'est pas du chiffrement, n'importe qui peut le décoder. Sealed Secrets chiffre vraiment le secret avec la clé publique du cluster. Seul le contrôleur dans le cluster possède la clé privée pour le déchiffrer.

```bash
# Installer le contrôleur dans le cluster
kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

# Installer kubeseal (l'outil de chiffrement côté développeur)
brew install kubeseal

# Vérifier
kubectl get pods -n kube-system | grep sealed-secrets
# Attendu : sealed-secrets-controller-xxx   1/1   Running
```

### Étape 5 — Installer le Tofu Controller (IaC)

Le Tofu Controller (successeur communautaire du Flux TF Controller) permet de gérer l'infrastructure avec Terraform via GitOps. Au lieu de lancer `terraform apply` depuis ton laptop, le contrôleur le fait depuis l'intérieur du cluster, en lisant les fichiers `.tf` directement depuis le repo Git. L'état Terraform est stocké dans un Secret Kubernetes.

```bash
# 1. Installer Flux source-controller (nécessaire pour lire le repo Git)
flux install --components=source-controller --namespace=flux-system

# 2. Installer Tofu Controller v0.16.4
curl -sL https://github.com/flux-iac/tofu-controller/releases/download/v0.16.4/tofu-controller.crds.yaml \
  | kubectl apply --server-side -f -

kubectl apply -f \
  https://github.com/flux-iac/tofu-controller/releases/download/v0.16.4/tofu-controller.rbac.yaml

kubectl apply -f \
  https://github.com/flux-iac/tofu-controller/releases/download/v0.16.4/tofu-controller.deployment.yaml

# 3. Donner les permissions nécessaires au runner Terraform
#    (le runner doit pouvoir créer des namespaces, des roles, etc.)
kubectl create clusterrolebinding tf-runner-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:tf-runner

# Vérifier
kubectl get pods -n flux-system
# Attendu : source-controller-xxx   1/1   Running
#           tofu-controller-xxx     1/1   Running
```

### Étape 6 — Déployer toutes les applications ArgoCD

```bash
# Kustomize dev + staging
kubectl apply -f application.yaml
kubectl apply -f application-staging.yaml

# Helm dev
kubectl apply -f application-helm-dev.yaml

# Déploiements progressifs
kubectl apply -f application-canary.yaml
kubectl apply -f application-bluegreen.yaml

# Infrastructure Terraform
kubectl apply -f infrastructure/gitrepository.yaml
kubectl apply -f infrastructure/terraform.yaml

# RBAC ArgoCD
kubectl apply -f apps/argocd-rbac-cm.yaml
```

### Étape 7 — Vérifier que tout tourne

```bash
# Toutes les apps ArgoCD doivent être Synced + Healthy
kubectl get applications -n argocd

# Les rollouts doivent être Healthy
kubectl argo rollouts get rollout todo-api-canary -n todo-api-canary
kubectl argo rollouts get rollout todo-api-bluegreen -n todo-api-bluegreen

# Terraform doit afficher "No drift"
kubectl get terraform todo-api-infra -n flux-system

# Les namespaces créés par Terraform doivent exister
kubectl get namespace monitoring-iac
kubectl get role,rolebinding -n monitoring-iac
```

---

## Pipeline CI/CD détaillée

Le pipeline est défini dans [.github/workflows/ci.yml](https://github.com/adouadi28-arch/todo-api-python/blob/main/.github/workflows/ci.yml) du repo applicatif.

### Schéma des jobs

```
push sur main
    │
    ├──► lint ──────────────────────────────────────────────┐
    │    ruff check + ruff format --check                   │
    │    Garantit que le code respecte les conventions      │
    │    PEP8 et le style défini dans ruff.toml             │
    │                                                       │
    ├──► test ───────────────────────────────────────────── ┤ tous les 3
    │    pytest --cov --cov-fail-under=70                   │ doivent réussir
    │    12 tests CRUD, coverage XML uploadé en artifact    │
    │                                                       │
    └──► security ──────────────────────────────────────────┘
         bandit  → détecte les patterns dangereux dans le code (SAST)
         pip-audit → vérifie les CVEs dans les dépendances
         gitleaks  → s'assure qu'aucun secret n'est commité par accident
              │
              ▼ (seulement si les 3 jobs précédents réussissent)
           docker
           Login GHCR → docker build → push :latest + :SHA
              │
              ▼
         update-gitops
         Clone gitops-team-Ryuk
         sed → remplace le tag dans deployment.yaml et values.yaml
         git commit + git push → ArgoCD détecte le changement
```

### Pourquoi le tag SHA et pas :latest ?

Utiliser `:latest` serait problématique : ArgoCD ne saurait pas si l'image a changé (le tag est le même). Avec le SHA du commit (`abc123def456...`), chaque build a un tag unique et immuable. ArgoCD voit que le tag dans le manifest a changé et déclenche un redéploiement.

---

## Déploiements progressifs

### Canary

Le canary déploie la nouvelle version sur un pourcentage croissant de pods avant de la pousser à 100%. Si un problème est détecté, on peut rollback instantanément sans que tous les utilisateurs aient été affectés.

Notre stratégie (définie dans `apps/todo-api-rollout/canary/rollout.yaml`) :

```
Étape 1 : 20% du trafic → nouvelle version  |  PAUSE MANUELLE
           1 pod nouvelle version / 4 pods ancienne version
           On valide : les métriques sont bonnes ? pas d'erreurs ?
           → kubectl argo rollouts promote todo-api-canary -n todo-api-canary

Étape 2 : 50% du trafic → nouvelle version  |  PAUSE AUTOMATIQUE 30s
           3 pods nouvelle version / 3 pods ancienne version
           Attente automatique de 30 secondes

Étape 3 : 100% → déploiement terminé
           5 pods nouvelle version / ancienne version supprimée (ScaledDown)
```

```bash
# Surveiller en temps réel
kubectl argo rollouts get rollout todo-api-canary -n todo-api-canary --watch

# Valider et passer à l'étape suivante
kubectl argo rollouts promote todo-api-canary -n todo-api-canary

# Annuler et rollback vers la version stable
kubectl argo rollouts abort todo-api-canary -n todo-api-canary
```

### Blue/Green

Le blue/green maintient deux environnements complets en parallèle :
- **Active** (blue) : la version en production, reçoit tout le trafic
- **Preview** (green) : la nouvelle version, déployée mais invisible des utilisateurs

La bascule est instantanée : le service `active` est redirigé vers le nouveau ReplicaSet d'un coup. Zéro downtime. Rollback aussi instantané.

```bash
# Voir les deux environnements
kubectl argo rollouts get rollout todo-api-bluegreen -n todo-api-bluegreen --watch

# Tester la version preview avant de basculer
kubectl port-forward svc/todo-api-bluegreen-preview -n todo-api-bluegreen 8001:80
# curl http://localhost:8001/health

# Basculer le trafic de active vers preview (promotion)
kubectl argo rollouts promote todo-api-bluegreen -n todo-api-bluegreen

# Rollback vers l'ancienne version
kubectl argo rollouts undo todo-api-bluegreen -n todo-api-bluegreen
```

---

## Sécurité

### Sealed Secrets — principe de fonctionnement

```
[kubeseal]  ←── récupère la clé publique du cluster
    │
    │  chiffre le secret avec cette clé publique
    ▼
[SealedSecret YAML]  ←── peut être commité dans Git (illisible sans la clé privée)
    │
    │  ArgoCD déploie le SealedSecret dans le cluster
    ▼
[Sealed Secrets Controller]  ←── possède la clé privée (stockée dans le cluster)
    │
    │  déchiffre le SealedSecret
    ▼
[Secret Kubernetes normal]  ←── utilisable par les pods via envFrom ou volumes
```

**Créer un nouveau secret chiffré :**

```bash
# Le secret en clair n'est jamais écrit sur disque — on pipe directement dans kubeseal
kubectl create secret generic mon-secret \
  --namespace todo-api-dev \
  --from-literal=MA_CLE="ma-valeur-secrete" \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace kube-system --format yaml \
  > apps/todo-api/base/secrets/mon-sealed-secret.yaml

# Ce fichier est maintenant sûr à commiter publiquement
git add apps/todo-api/base/secrets/mon-sealed-secret.yaml
git commit -S -m "feat: add sealed secret"
git push
```

**Important** : un SealedSecret est lié à un namespace ET à un cluster. Si tu changes de cluster, il faudra re-chiffrer les secrets avec la nouvelle clé publique.

### RBAC ArgoCD

Trois rôles sont définis dans `apps/argocd-rbac-cm.yaml` :

| Rôle | Peut sync | Peut voir les logs | Peut delete | Peut exec dans un pod |
|------|-----------|-------------------|-------------|----------------------|
| `admin` | ✅ | ✅ | ✅ | ✅ |
| `developer` | ✅ | ✅ | ❌ | ❌ |
| `viewer` | ❌ | ❌ | ❌ | ❌ |

Le rôle par défaut (`policy.default: role:viewer`) s'applique à tout utilisateur non explicitement assigné à un rôle. Cela signifie que par défaut, un utilisateur qui se connecte à ArgoCD ne peut que voir les apps, pas les modifier.

### Commits signés GPG

Chaque commit sur ce repo est signé avec une clé GPG (`git commit -S`). La signature prouve que le commit vient bien du développeur dont la clé publique est enregistrée sur GitHub, et que le contenu n'a pas été altéré après signature.

```bash
# Vérifier la signature d'un commit
git log --show-signature -1

# Output attendu :
# gpg: Good signature from "Anis Douadi <anisdouadi5@gmail.com>" [ultimate]
```

---

## Infrastructure as Code (Tofu Controller)

Le fichier `infrastructure/terraform/main.tf` gère via Terraform :
- Le namespace `monitoring-iac` avec les labels `managed-by: terraform`
- Un `Role` Kubernetes `todo-api-reader` avec accès lecture aux pods et services
- Un `RoleBinding` qui attache ce rôle au ServiceAccount `default`

**Drift detection** : toutes les 5 minutes, le Tofu Controller compare l'état du cluster avec ce qui est décrit dans le `.tf`. Si quelqu'un a supprimé le namespace à la main, il le recrée automatiquement. C'est le même principe que ArgoCD pour les apps, appliqué à l'infra.

```bash
# Voir l'état de la réconciliation Terraform
kubectl get terraform todo-api-infra -n flux-system

# Voir le plan généré (lisible par un humain)
kubectl get terraform todo-api-infra -n flux-system \
  -o jsonpath='{.status.plan.renderedPlan}'

# Forcer une réconciliation immédiate
kubectl annotate terraform todo-api-infra -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

---

## Choix techniques

### Pourquoi Kustomize ET Helm dans le même repo ?

Les deux outils répondent à des besoins différents :

**Kustomize** est natif dans `kubectl` (pas d'installation supplémentaire) et fonctionne par **superposition** : on part des manifests bruts et on applique des patches par-dessus. C'est simple et lisible. Parfait pour gérer des différences légères entre environnements (replicas, resources, variables d'env).

**Helm** fonctionne par **templating** : les manifests sont des templates Go avec des variables. C'est plus puissant pour des apps complexes ou qu'on veut distribuer à d'autres équipes. Mais ça ajoute une couche d'abstraction qui peut rendre le debug plus difficile.

On a choisi de montrer les deux car les deux sont courants en production. ArgoCD les supporte nativement tous les deux.

### Pourquoi le canary avec pause manuelle à 20% ?

La pause manuelle simule ce qu'on ferait en production : déployer sur 20% du trafic, surveiller les métriques (taux d'erreur, latence, logs) pendant quelques minutes, puis décider de continuer ou d'annuler. En production, cette décision peut être automatisée via des `AnalysisTemplate` ArgoCD Rollouts qui interrogent Prometheus — nous l'avons laissée manuelle pour la démonstration.

### Pourquoi Sealed Secrets plutôt qu'External Secrets Operator ?

**External Secrets Operator** est plus adapté en contexte cloud : les secrets restent dans AWS Secrets Manager ou HashiCorp Vault, Git ne contient qu'une référence. C'est plus sécurisé (rotation de clés facilitée, audit trail complet) mais ça nécessite un vault externe.

**Sealed Secrets** est plus simple à mettre en place localement : tout est dans le cluster, pas de dépendance externe. Le seul vrai inconvénient est la rotation de clé : si la clé privée du cluster est compromise, tous les SealedSecrets doivent être re-chiffrés.

Pour ce projet local sans infrastructure cloud, Sealed Secrets est le bon compromis.

### Pourquoi stocker l'état Terraform dans Kubernetes (et pas S3) ?

En production, le state Terraform est généralement dans S3 + DynamoDB (pour le locking). Ici, le Tofu Controller stocke le state dans un Secret Kubernetes dans le namespace `flux-system`. C'est cohérent avec l'approche "tout dans le cluster" d'un environnement local. Pour un vrai environnement cloud, on configurerait un backend S3 dans le `main.tf`.

---

## Équipe

Team Ryuk — Promotion DevOps 2026
 