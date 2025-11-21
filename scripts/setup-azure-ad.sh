#!/bin/bash
# Azure AD 应用设置脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否已登录Azure
check_azure_login() {
    if ! az account show > /dev/null 2>&1; then
        print_error "请先登录Azure: az login"
        exit 1
    fi
}

# 创建Azure AD应用
create_ad_app() {
    APP_NAME=${1:-"openai-monitor-$(whoami)-$(date +%s)"}

    print_info "创建Azure AD应用: $APP_NAME"

    # 创建应用
    APP_INFO=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg)
    APP_ID=$(echo $APP_INFO | jq -r '.appId')

    print_info "应用ID: $APP_ID"

    # 创建服务主体
    print_info "创建服务主体..."
    az ad sp create --id $APP_ID > /dev/null

    # 创建客户端密钥
    print_info "创建客户端密钥..."
    SECRET_INFO=$(az ad app credential reset --id $APP_ID --years 2)
    CLIENT_SECRET=$(echo $SECRET_INFO | jq -r '.password')

    # 获取租户ID
    TENANT_ID=$(az account show --query tenantId -o tsv)

    # 输出配置信息
    print_info "=== 配置信息 ==="
    echo "应用名称: $APP_NAME"
    echo "应用ID: $APP_ID"
    echo "客户端密钥: $CLIENT_SECRET"
    echo "租户ID: $TENANT_ID"

    # 保存到文件
    cat > azure-ad-config.txt << EOF
Azure AD Application Configuration
================================
Application Name: $APP_NAME
Application ID (Client ID): $APP_ID
Client Secret: $CLIENT_SECRET
Tenant ID: $TENANT_ID

Environment Variables:
AZURE_TENANT_ID=$TENANT_ID
AZURE_CLIENT_ID=$APP_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
EOF

    print_info "配置已保存到: azure-ad-config.txt"
}

# 分配权限
assign_permissions() {
    APP_ID=$1
    SCOPE=${2:-$(az account show --query id -o tsv)}

    print_info "分配权限..."

    # Monitoring Reader 权限
    print_info "分配 Monitoring Reader 权限..."
    az role assignment create --assignee $APP_ID --role "Monitoring Reader" --scope $SCOPE

    # Cognitive Services Contributor 权限（如果指定了资源组）
    if [ "$SCOPE" != "$(az account show --query id -o tsv)" ]; then
        print_info "分配 Cognitive Services Contributor 权限..."
        az role assignment create --assignee $APP_ID --role "Cognitive Services Contributor" --scope $SCOPE
    fi

    print_info "权限分配完成"
}

# 验证配置
verify_configuration() {
    APP_ID=$1

    print_info "验证配置..."

    # 检查应用是否存在
    APP_EXISTS=$(az ad app show --id $APP_ID --query id -o tsv 2>/dev/null || echo "")
    if [ -z "$APP_EXISTS" ]; then
        print_error "应用不存在: $APP_ID"
        return 1
    fi

    # 检查服务主体是否存在
    SP_EXISTS=$(az ad sp show --id $APP_ID --query id -o tsv 2>/dev/null || echo "")
    if [ -z "$SP_EXISTS" ]; then
        print_error "服务主体不存在: $APP_ID"
        return 1
    fi

    print_info "配置验证成功"
    return 0
}

# 主函数
main() {
    echo "=== Azure AD 应用设置脚本 ==="
    echo

    check_azure_login

    if [ $# -eq 0 ]; then
        echo "用法:"
        echo "  $0 create <app-name>     # 创建新的Azure AD应用"
        echo "  $0 assign <app-id> <scope>  # 分配权限"
        echo "  $0 verify <app-id>       # 验证配置"
        echo
        exit 1
    fi

    COMMAND=$1

    case $COMMAND in
        create)
            APP_NAME=${2:-""}
            create_ad_app "$APP_NAME"

            # 自动分配权限
            SUBSCRIPTION_ID=$(az account show --query id -o tsv)
            assign_permissions "$APP_ID" "$SUBSCRIPTION_ID"

            # 自动验证
            sleep 5  # 等待权限生效
            verify_configuration "$APP_ID"
            ;;

        assign)
            APP_ID=$2
            SCOPE=${3:-$(az account show --query id -o tsv)}

            if [ -z "$APP_ID" ]; then
                print_error "请提供应用ID"
                exit 1
            fi

            assign_permissions "$APP_ID" "$SCOPE"
            ;;

        verify)
            APP_ID=$2

            if [ -z "$APP_ID" ]; then
                print_error "请提供应用ID"
                exit 1
            fi

            verify_configuration "$APP_ID"
            ;;

        *)
            print_error "未知命令: $COMMAND"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"