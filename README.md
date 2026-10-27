# ConfigCluster - Gerenciamento do Cluster MicroK8s

Este repositório centraliza as configurações de infraestrutura, segurança, rede e manifestos de aplicações hospedadas no cluster **MicroK8s**.

---

## 📁 Estrutura de Diretórios

```text
configCluster/
├── README.md
├── base/                              # Recursos globais e de infraestrutura
│   ├── cluster-issuer.yaml            # Cert-Manager (Let's Encrypt SSL)
│   ├── namespaces.yaml                # Criação e isolamento dos namespaces
│   └── quotas/
│       └── webterminal-quota.yaml     # Limites de recursos para evitar sobrecarga
└── apps/                              # Manifestos de cada aplicação
    ├── webterminal/                   # Aplicação WebTerminal
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

Como a universidade não libera domínio coringa (*.dominio), o fluxo para novas aplicações é solicitar entradas individuais de DNS apontando sempre para o **mesmo IP do servidor do cluster**:

1. **Ao solicitar um novo link para a TI (ex: NTI / Redes):**
   * **Novo subdomínio direto:** `<Nome>.inf.ufpel.edu.br` -> Apontando para o IP do Cluster.
        * **Exemplo:** `anatox.inf.ufpel.edu.br`; `clusterlups.inf.ufpel.edu.br`
        

2. **Como o MicroK8s resolve múltiplos domínios na mesma máquina:**
   * Todas as requisições (seja para `clusterlups.inf.ufpel.edu.br` ou para `anatox.inf.ufpel.edu.br`) chegam no mesmo IP e na mesma porta 80/443 do servidor.
   * O **Ingress Controller (NGINX)** lê o cabeçalho HTTP `Host:` da requisição:
     * Se for `clusterlups.inf.ufpel.edu.br` -> Envia para o `terminal-web-service`.
     * Se for `anatox.inf.ufpel.edu.br` -> Envia para os serviços do Anatox.
   * Não há conflito de portas nem de rotas, mesmo estando todos na mesma máquina.

---

## 🔒 2. Certificados SSL com Let's Encrypt

O `ClusterIssuer` configurado em `base/cluster-issuer.yaml` usa o método `http01`:
* Ao criar uma nova aplicação com Ingress contendo a annotation `cert-manager.io/cluster-issuer: "letsencrypt-prod"`, o Cert-Manager gera um certificado TLS gratuito e válido especificamente para aquele subdomínio.
* O processo é 100% automático.

---

## 📦 3. Passo a Passo de Execução no MicroK8s

Execute estes comandos no servidor do cluster MicroK8s:

### Passo 3.1: Habilitar os Addons necessários (se ainda não fez)
```bash
microk8s enable dns
microk8s enable ingress
microk8s enable cert-manager
microk8s enable registry
```

### Passo 3.2: Aplicar as configurações base do cluster
```bash
# Cria os namespaces isolados:
microk8s kubectl apply -f base/namespaces.yaml

# Aplica o emissor de certificados SSL:
microk8s kubectl apply -f base/cluster-issuer.yaml

# (Opcional, mas recomendado) Aplica quotas de recursos:
microk8s kubectl apply -f base/quotas/terminalWeb-quota.yaml
```

### Passo 3.3: Criar os Secrets da Aplicação (ex: terminalWeb)
Os segredos devem ser criados dentro do namespace da aplicação:
```bash
microk8s kubectl create secret generic terminal-web-secrets \
  --namespace terminalWeb \
  --from-env-file=/caminho/para/.env
```

### Passo 3.4: Aplicar a aplicação webTerminal
```bash
microk8s kubectl apply -f apps/terminalWeb/rbac.yaml
microk8s kubectl apply -f apps/terminalWeb/network-policy.yaml
microk8s kubectl apply -f apps/terminalWeb/deployment.yaml
```

---

## ➕ 4. Como Adicionar uma Nova Aplicação no Cluster

Quando outra pessoa ou equipe quiser hospedar uma aplicação:

1. **Criar um novo namespace** (se ainda não existir):
   ```bash
   microk8s kubectl create namespace nome-da-app
   ```
2. **Copiar o modelo** de `apps/exemplo-nova-app/deployment.yaml`.
3. **Ajustar apenas 3 coisas** no arquivo:
   * O campo `namespace: nome-da-app`
   * A imagem do container (`image: ...`) e a porta do container
   * O subdomínio no Ingress (`host: <meunome>.inf.ufpel.edu.br`)
4. **Aplicar no cluster:**
   ```bash
   microk8s kubectl apply -f apps/sua-app/deployment.yaml
   ```
Pronto! Em instantes a aplicação estará no ar com HTTPS configurado automaticamente.
