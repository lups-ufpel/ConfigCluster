# ConfigCluster - Gerenciamento do Cluster MicroK8s

Este repositório centraliza as configurações de infraestrutura, segurança, rede e manifestos de aplicações hospedadas no cluster **MicroK8s**.

---

## 📁 Estrutura de Diretórios

```text
configCluster/
├── README.md
├── deploy.sh                          # Script de deploy automatizado do cluster
├── base/                              # Recursos globais e de infraestrutura
│   ├── cluster-issuer.yaml            # Cert-Manager (Let's Encrypt SSL)
│   ├── namespaces.yaml                # Criação e isolamento dos namespaces
│   └── quotas/
│       └── guest-apps-quota.yaml      # Quotas aplicadas APENAS nos convidados
└── apps/                              # Manifestos de cada aplicação
    ├── terminalWeb/                   # Aplicação principal terminalWeb
    │   ├── deployment.yaml            # Deployment, Service e Ingress
    │   ├── rbac.yaml                  # Permissões da aplicação no seu namespace
    │   └── network-policy.yaml        # Isolamento de rede dos pods MPI
    ├── anatox/                        # Aplicação Anatox
    │   └── ingress.yaml               # Ingress com subdomínio anatox.clusterlups...
    └── exemplo-nova-app/              # Template pronto para novas aplicações
        └── deployment.yaml
```

---

## 🌐 1. Configuração de Domínios / Links (DNS na TI)

Como a universidade trabalha com entradas individuais de DNS (sem domínio wildcard), o fluxo para cada aplicação é possuir uma entrada de DNS própria solicitada à equipe de redes da UFPel (NTI), apontando sempre para o **mesmo IP do servidor do cluster**:

1. **Estrutura dos domínios:**
   * **Domínio Principal (terminalWeb):** `clusterlups.inf.ufpel.edu.br` -> Aponta para o IP do cluster (hospeda a aplicação principal com suporte a WebSockets e timeouts estendidos).
   * **Subdomínios Individuais (Aplicações Convidadas):** `<app>.clusterlups.inf.ufpel.edu.br` ou `<app>.inf.ufpel.edu.br` -> Apontam para o mesmo IP do cluster.
     * **Exemplo:** `anatox.clusterlups.inf.ufpel.edu.br`.

2. **Como o MicroK8s resolve múltiplos domínios na mesma máquina:**
   * Todas as requisições chegam no mesmo IP e nas mesmas portas HTTP/HTTPS (80/443) do servidor.
   * O **Ingress Controller (NGINX)** lê o cabeçalho HTTP `Host:` da requisição:
     * Se for `clusterlups.inf.ufpel.edu.br` -> Envia para o serviço do `terminalWeb` (`terminal-web-service`).
     * Se for `anatox.clusterlups.inf.ufpel.edu.br` -> Envia para os serviços do Anatox.
   * Não há conflito de portas nem de rotas, mantendo total separação de tráfego.

---

## 🔒 2. Certificados SSL com Let's Encrypt

O `ClusterIssuer` configurado em `base/cluster-issuer.yaml` usa o método `http01`:
* Ao criar uma aplicação com Ingress contendo a annotation `cert-manager.io/cluster-issuer: "letsencrypt-prod"`, o Cert-Manager resolve o desafio HTTP-01 e gera um certificado TLS gratuito e válido individualmente para aquele domínio/subdomínio.
* O processo de emissão e renovação é 100% automático.

---

## 📦 3. Execução e Deploy no MicroK8s

### Passo 3.1: Habilitar os Addons necessários (se ainda não fez)
```bash
microk8s enable dns
microk8s enable ingress
microk8s enable cert-manager
microk8s enable registry
```

### ⚡ Opção A: Deploy Automático com `deploy.sh` (Recomendado)
O repositório inclui o script [`deploy.sh`](file:///home/pedro/ConfigCluster/deploy.sh), que aplica a base e varre a pasta `apps/` de forma ordenada (ignorando pastas de templates como `exemplo-*`):

```bash
# Aplica a infraestrutura base e todas as aplicações em apps/:
./deploy.sh

# Ou aplica a base e apenas uma aplicação específica:
./deploy.sh terminalWeb

# Verifica o status consolidado de pods, namespaces e ingresses:
./deploy.sh --status
```

---

### 🛠️ Opção B: Passo a Passo Manual
Caso prefira executar cada manifesto individualmente:

#### Passo 3.2: Aplicar as configurações base do cluster
```bash
# Cria os namespaces isolados (terminal-web, anatox, app-exemplo, etc.):
microk8s kubectl apply -f base/namespaces.yaml

# Aplica o emissor global de certificados SSL (Let's Encrypt):
microk8s kubectl apply -f base/cluster-issuer.yaml

# Aplica quotas e limit ranges para as aplicações convidadas:
# (IMPORTANTE: o namespace 'terminal-web' NÃO possui ResourceQuota para permitir
# elasticidade irrestrita e Cloud Bursting no modelo BRYOC)
microk8s kubectl apply -f base/quotas/guest-apps-quota.yaml
```

### Passo 3.3: Criar os Secrets da Aplicação (terminalWeb)
Os segredos devem ser criados dentro do namespace da aplicação (`terminal-web`):
```bash
microk8s kubectl create secret generic terminal-web-secrets \
  --namespace terminal-web \
  --from-env-file=/caminho/para/.env
```

### Passo 3.4: Aplicar a aplicação terminalWeb
```bash
microk8s kubectl apply -f apps/terminalWeb/rbac.yaml
microk8s kubectl apply -f apps/terminalWeb/network-policy.yaml
microk8s kubectl apply -f apps/terminalWeb/deployment.yaml
```

---

## ➕ 4. Como Adicionar uma Nova Aplicação no Cluster

Quando outra pessoa ou equipe de pesquisa for hospedar uma aplicação ("convidada"):

1. **Garantir o namespace dedicado:**
   * Adicione o namespace em `base/namespaces.yaml` e aplique, ou crie manualmente:
     ```bash
     microk8s kubectl create namespace nome-da-app
     ```
2. **Definir quotas de recursos para o convidado:**
   * No arquivo `base/quotas/guest-apps-quota.yaml`, adicione as regras de `ResourceQuota` e `LimitRange` para o namespace `nome-da-app`. Isso evita que a aplicação monopolize a máquina ou afete o Cloud Bursting do `terminalWeb`.
   * Aplique a alteração:
     ```bash
     microk8s kubectl apply -f base/quotas/guest-apps-quota.yaml
     ```
3. **Solicitar o subdomínio à equipe de redes da UFPel:**
   * Exemplo: `nome-da-app.clusterlups.inf.ufpel.edu.br` apontando para o IP do servidor MicroK8s.
4. **Copiar o modelo pronto:**
   * Copie a pasta `apps/exemplo-nova-app/` para `apps/nome-da-app/`.
5. **Ajustar as configurações em `deployment.yaml`:**
   * O campo `namespace: nome-da-app`
   * A imagem do container (`image: ...`) e portas
   * O subdomínio no Ingress (`host: nome-da-app.clusterlups.inf.ufpel.edu.br`) e o `secretName: nome-da-app-tls`
6. **Aplicar no cluster:**
   ```bash
   microk8s kubectl apply -f apps/nome-da-app/deployment.yaml
   ```
Pronto! Em instantes a aplicação estará no ar com HTTPS configurado automaticamente.
