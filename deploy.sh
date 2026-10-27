#!/usr/bin/env bash
# ==============================================================================
# Script de Deploy e Governança do Cluster MicroK8s (LUPS - UFPel)
# ==============================================================================
# Este script automatiza:
# 1. Aplicação da infraestrutura base (namespaces, certificados e quotas)
# 2. Varredura da pasta apps/ e deploy ordenado de cada aplicação
# 3. Migração segura de segredos e limpeza de deploys legados no namespace default
# ==============================================================================

set -euo pipefail

# Cores para saída no terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Identifica diretórios do repositório
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/base"
APPS_DIR="${SCRIPT_DIR}/apps"

# ------------------------------------------------------------------------------
# 1. Detecção do binário kubectl / microk8s kubectl
# ------------------------------------------------------------------------------
if command -v microk8s &> /dev/null; then
    KUBECTL="microk8s kubectl"
elif command -v kubectl &> /dev/null; then
    KUBECTL="kubectl"
else
    echo -e "${RED}[ERRO] Nem 'microk8s kubectl' nem 'kubectl' foram encontrados no PATH.${NC}"
    exit 1
fi

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

log_header() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"
}

# ------------------------------------------------------------------------------
# 2. Exibição de Ajuda
# ------------------------------------------------------------------------------
show_help() {
    echo -e "${BOLD}Uso:${NC} ./deploy.sh [OPÇÕES] [NOME_DA_APP]

${BOLD}Opções:${NC}
  -a, --all               Aplica a base e todas as aplicações em apps/ (padrão)
  -c, --clean-default     Remove deploys legados do terminalWeb no namespace default
  -b, --base-only         Aplica somente a infraestrutura base (namespaces, quotas, SSL)
  -s, --status            Exibe o status atual dos pods, services e ingresses no cluster
  -h, --help              Exibe esta mensagem de ajuda

${BOLD}Exemplos:${NC}
  ./deploy.sh                      # Aplica a base e todas as apps (ignora templates de exemplo)
  ./deploy.sh terminalWeb          # Aplica a base e somente o terminalWeb
  ./deploy.sh --clean-default      # Limpa o terminal antigo do 'default' e sobe a nova estrutura
  ./deploy.sh --status             # Mostra os pods e ingresses no cluster"
}

# ------------------------------------------------------------------------------
# 3. Limpeza de Recursos Legados do terminalWeb no namespace default
# ------------------------------------------------------------------------------
clean_default_legacy() {
    log_header "Limpando recursos legados do terminalWeb no namespace 'default'"
    
    # Verifica se existem recursos no default antes de tentar deletar
    if $KUBECTL get deployment terminal-web-backend -n default &> /dev/null; then
        log_info "Removendo deployment 'terminal-web-backend' do namespace default..."
        $KUBECTL delete deployment terminal-web-backend -n default --ignore-not-found=true
    fi

    if $KUBECTL get service terminal-web-service -n default &> /dev/null; then
        log_info "Removendo service 'terminal-web-service' do namespace default..."
        $KUBECTL delete service terminal-web-service -n default --ignore-not-found=true
    fi

    if $KUBECTL get ingress terminal-web-ingress -n default &> /dev/null; then
        log_info "Removendo ingress 'terminal-web-ingress' do namespace default..."
        $KUBECTL delete ingress terminal-web-ingress -n default --ignore-not-found=true
    fi

    if $KUBECTL get rolebinding terminal-backend-binding -n default &> /dev/null; then
        log_info "Removendo RBAC legado do namespace default..."
        $KUBECTL delete rolebinding terminal-backend-binding -n default --ignore-not-found=true
        $KUBECTL delete role terminal-pod-manager -n default --ignore-not-found=true
        $KUBECTL delete sa terminal-backend-sa -n default --ignore-not-found=true
    fi

    log_success "Namespace 'default' limpo com sucesso de recursos antigos do terminalWeb."
}

# ------------------------------------------------------------------------------
# 4. Migração / Validação de Secrets do terminalWeb
# ------------------------------------------------------------------------------
check_terminal_secrets() {
    local target_ns="terminal-web"
    local secret_name="terminal-web-secrets"

    if $KUBECTL get secret "$secret_name" -n "$target_ns" &> /dev/null; then
        log_success "Secret '$secret_name' já existe no namespace '$target_ns'."
    else
        # Se não existe no terminal-web, verifica se podemos migrar do default
        if $KUBECTL get secret "$secret_name" -n default &> /dev/null; then
            log_info "Secret '$secret_name' encontrado no namespace 'default'. Migrando para '$target_ns'..."
            $KUBECTL get secret "$secret_name" -n default -o yaml \
                | sed "s/namespace: default/namespace: $target_ns/" \
                | $KUBECTL apply -f -
            log_success "Secret migrado com sucesso para '$target_ns'!"
        else
            log_warn "Secret '$secret_name' NÃO foi encontrado em '$target_ns' nem em 'default'."
            log_warn "Crie o secret manualmente com: $KUBECTL create secret generic $secret_name -n $target_ns --from-env-file=/caminho/.env"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 5. Aplicação da Infraestrutura Base
# ------------------------------------------------------------------------------
apply_base() {
    log_header "Aplicando Infraestrutura Base do Cluster"

    # 1. Namespaces
    if [ -f "${BASE_DIR}/namespaces.yaml" ]; then
        log_info "Criando / atualizando namespaces..."
        $KUBECTL apply -f "${BASE_DIR}/namespaces.yaml"
    fi

    # 2. ClusterIssuer (SSL Let's Encrypt)
    if [ -f "${BASE_DIR}/cluster-issuer.yaml" ]; then
        log_info "Configurando ClusterIssuer (Let's Encrypt SSL)..."
        $KUBECTL apply -f "${BASE_DIR}/cluster-issuer.yaml"
    fi

    # 3. Quotas de Convidados (Guest Apps Quota)
    if [ -d "${BASE_DIR}/quotas" ]; then
        log_info "Aplicando ResourceQuotas e LimitRanges para aplicações convidadas..."
        $KUBECTL apply -f "${BASE_DIR}/quotas/"
    fi

    log_success "Infraestrutura base aplicada com sucesso."
}

# ------------------------------------------------------------------------------
# 6. Deploy de uma Aplicação Específica
# ------------------------------------------------------------------------------
deploy_single_app() {
    local app_path="$1"
    local app_name="$(basename "$app_path")"

    # Ignora templates de exemplo ou pastas marcadas com .skip
    if [[ "$app_name" =~ ^exemplo- ]] || [ -f "${app_path}/.skip" ]; then
        log_info "Pulando template de exemplo ou pasta ignorada: ${app_name}"
        return 0
    fi

    log_header "Implantando aplicação: ${app_name}"

    # Verificação especial para o terminalWeb
    if [ "$app_name" == "terminalWeb" ]; then
        check_terminal_secrets
    fi

    # Aplicação ordenada de manifests para evitar dependências não satisfeitas:
    # 1. RBAC (ServiceAccount, Role, RoleBinding)
    if [ -f "${app_path}/rbac.yaml" ]; then
        log_info "Aplicando RBAC (${app_name})..."
        $KUBECTL apply -f "${app_path}/rbac.yaml"
    fi

    # 2. Network Policies
    if [ -f "${app_path}/network-policy.yaml" ]; then
        log_info "Aplicando NetworkPolicy (${app_name})..."
        $KUBECTL apply -f "${app_path}/network-policy.yaml"
    fi

    # 3. Deployments / Services / Ingresses principais
    if [ -f "${app_path}/deployment.yaml" ]; then
        log_info "Aplicando Deployment, Service e Ingress (${app_name})..."
        $KUBECTL apply -f "${app_path}/deployment.yaml"
    fi

    # 4. Ingress isolado (caso haja, ex: anatox)
    if [ -f "${app_path}/ingress.yaml" ]; then
        log_info "Aplicando Ingress (${app_name})..."
        $KUBECTL apply -f "${app_path}/ingress.yaml"
    fi

    # 5. Outros arquivos YAML na pasta que não foram aplicados acima
    for extra_file in "${app_path}"/*.yaml "${app_path}"/*.yml; do
        [ -e "$extra_file" ] || continue
        local fname="$(basename "$extra_file")"
        if [[ ! "$fname" =~ ^(rbac|network-policy|deployment|ingress)\.ya?ml$ ]]; then
            log_info "Aplicando manifesto complementar: ${fname}..."
            $KUBECTL apply -f "$extra_file"
        fi
    done

    log_success "Aplicação '${app_name}' implantada com sucesso."
}

# ------------------------------------------------------------------------------
# 7. Varredura e Deploy da Pasta apps/
# ------------------------------------------------------------------------------
deploy_all_apps() {
    log_header "Varrendo diretório de aplicações (${APPS_DIR})"

    if [ ! -d "$APPS_DIR" ]; then
        log_warn "Diretório apps/ não encontrado em ${APPS_DIR}."
        return 0
    fi

    for app_dir in "${APPS_DIR}"/*; do
        if [ -d "$app_dir" ]; then
            deploy_single_app "$app_dir"
        fi
    done
}

# ------------------------------------------------------------------------------
# 8. Exibição de Status do Cluster
# ------------------------------------------------------------------------------
show_cluster_status() {
    log_header "Status Atual do Cluster MicroK8s"
    
    echo -e "\n${BOLD}--- Namespaces Ativos ---${NC}"
    $KUBECTL get namespaces

    echo -e "\n${BOLD}--- Ingresses (Roteamento e SSL) ---${NC}"
    $KUBECTL get ingress -A

    echo -e "\n${BOLD}--- Pods nas Aplicações Gerenciadas ---${NC}"
    $KUBECTL get pods -n terminal-web --ignore-not-found=true
    $KUBECTL get pods -n anatox --ignore-not-found=true
    $KUBECTL get pods -n default --ignore-not-found=true
}

# ------------------------------------------------------------------------------
# 9. Ponto de Entrada Principal (Main)
# ------------------------------------------------------------------------------
main() {
    local target_app=""
    local do_clean_default=false
    local base_only=false

    # Parsing de argumentos
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--status)
                show_cluster_status
                exit 0
                ;;
            -c|--clean-default)
                do_clean_default=true
                shift
                ;;
            -b|--base-only)
                base_only=true
                shift
                ;;
            -a|--all)
                shift
                ;;
            *)
                target_app="$1"
                shift
                ;;
        esac
    done

    echo -e "${CYAN}${BOLD}Iniciando automação do cluster com: ${KUBECTL}${NC}"

    # Executa limpeza no default se solicitado
    if [ "$do_clean_default" = true ]; then
        clean_default_legacy
    fi

    # Sempre garante a infraestrutura base
    apply_base

    if [ "$base_only" = true ]; then
        exit 0
    fi

    # Deploy de aplicação específica ou de todas
    if [ -n "$target_app" ]; then
        local specific_app_path="${APPS_DIR}/${target_app}"
        if [ -d "$specific_app_path" ]; then
            deploy_single_app "$specific_app_path"
        else
            log_error "Aplicação '${target_app}' não encontrada em ${APPS_DIR}/"
            exit 1
        fi
    else
        deploy_all_apps
    fi

    log_header "Processo de Deploy Concluído"
    log_info "Para acompanhar o status dos pods, execute: $KUBECTL get pods -n terminal-web"
}

main "$@"
