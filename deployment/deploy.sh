#!/bin/bash
# Azure OpenAI Monitor 一键部署脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查依赖
check_dependencies() {
    print_info "检查依赖..."

    if ! command -v az &> /dev/null; then
        print_error "Azure CLI 未安装。请访问 https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! command -v func &> /dev/null; then
        print_error "Azure Functions Core Tools 未安装。请访问 https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
        exit 1
    fi

    print_info "依赖检查完成"
}

# 登录Azure
login_azure() {
    print_info "登录Azure..."
    az login
    print_info "Azure登录完成"
}

# 设置Azure AD应用
setup_azure_ad_app() {
    print_info "设置Azure AD应用..."

    # 检查是否已存在应用
    APP_NAME="openai-monitor-$(whoami)-$(date +%s)"

    # 创建Azure AD应用
    APP_INFO=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg)
    APP_ID=$(echo $APP_INFO | jq -r '.appId')

    print_info "Azure AD应用已创建，App ID: $APP_ID"

    # 创建服务主体
    SP_INFO=$(az ad sp create --id $APP_ID)

    # 创建客户端密钥
    SECRET_INFO=$(az ad app credential reset --id $APP_ID --years 2)
    CLIENT_SECRET=$(echo $SECRET_INFO | jq -r '.password')

    # 获取租户ID
    TENANT_ID=$(az account show --query tenantId -o tsv)

    # 保存配置信息
    cat > .env << EOF
AZURE_TENANT_ID=$TENANT_ID
AZURE_CLIENT_ID=$APP_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
APP_NAME=$APP_NAME
EOF

    print_info "Azure AD应用配置完成"
    print_warning "请保存以下信息："
    echo "  Tenant ID: $TENANT_ID"
    echo "  Client ID: $APP_ID"
    echo "  Client Secret: $CLIENT_SECRET"

    # 分配权限
    print_info "分配权限..."

    # 等待应用创建完成
    sleep 30

    # 分配Monitor Reader权限（需要订阅级别）
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    az role assignment create --assignee $APP_ID --role "Monitoring Reader" --scope /subscriptions/$SUBSCRIPTION_ID

    print_info "权限分配完成"
}

# 配置环境变量
setup_environment() {
    print_info "配置环境变量..."

    # 读取基础配置
    source .env

    # 收集监控配置
    read -p "请输入Azure订阅ID [当前: $(az account show --query id -o tsv)]: " SUBSCRIPTION_ID
    SUBSCRIPTION_ID=${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}

    read -p "请输入资源组名称: " RESOURCE_GROUP

    read -p "请输入要监控的OpenAI服务名称 (多个用逗号分隔): " OPENAI_SERVICES

    read -p "请输入429错误阈值 (默认10): " THRESHOLD
    THRESHOLD=${THRESHOLD:-10}

    read -p "请输入检查间隔秒数 (默认5): " INTERVAL
    INTERVAL=${INTERVAL:-5}

    read -p "请输入Key禁用时长分钟数 (默认1): " DISABLE_DURATION
    DISABLE_DURATION=${DISABLE_DURATION:-1}

    # 构建服务配置JSON
    SERVICES_JSON="["
    IFS=',' read -ra SERVICES <<< "$OPENAI_SERVICES"
    for i in "${!SERVICES[@]}"; do
        service=$(echo "${SERVICES[$i]}" | xargs)  # 去除空格
        if [ $i -gt 0 ]; then
            SERVICES_JSON="$SERVICES_JSON,"
        fi
        SERVICES_JSON="$SERVICES_JSON{\"name\":\"$service\",\"resource_group\":\"$RESOURCE_GROUP\",\"subscription_id\":\"$SUBSCRIPTION_ID\"}"
    done
    SERVICES_JSON="$SERVICES_JSON]"

    # 更新环境变量文件
    cat >> .env << EOF
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
MONITOR_SERVICES_JSON=$SERVICES_JSON
MONITOR_429_THRESHOLD=$THRESHOLD
MONITOR_CHECK_INTERVAL=$INTERVAL
MONITOR_KEY_DISABLE_DURATION=$DISABLE_DURATION
RESOURCE_GROUP=$RESOURCE_GROUP
EOF

    print_info "环境变量配置完成"
}

# 部署Azure Functions
deploy_functions() {
    print_info "部署Azure Functions..."

    source .env

    # 创建资源组（如果不存在）
    az group create --name $RESOURCE_GROUP --location eastus

    # 生成部署参数
    cat > deployment/parameters.json << EOF
{
    "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "functionAppName": {
            "value": "$APP_NAME"
        },
        "location": {
            "value": "eastus"
        }
    }
}
EOF

    print_info "Azure Functions基础架构部署完成"
}

# 部署代码
deploy_code() {
    print_info "部署函数代码..."

    source .env

    # 发布函数代码
    func azure functionapp publish $APP_NAME

    print_info "代码部署完成"
}

# 配置应用设置
configure_app_settings() {
    print_info "配置应用设置..."

    source .env

    # 读取环境变量并设置
    while IFS='=' read -r key value; do
        if [[ $key == AZURE_* || $key == MONITOR_* || $key == ALERT_* ]]; then
            az functionapp config appsettings set \
                --resource-group $RESOURCE_GROUP \
                --name $APP_NAME \
                --settings "$key=$value"
        fi
    done < .env

    print_info "应用设置配置完成"
}

# 验证部署
verify_deployment() {
    print_info "验证部署..."

    source .env

    # 获取函数应用URL
    FUNCTION_URL=$(az functionapp function list --resource-group $RESOURCE_GROUP --name $APP_NAME --query [0].invokeUrlTemplate -o tsv 2>/dev/null || echo "")

    if [ ! -z "$FUNCTION_URL" ]; then
        HEALTH_URL="${FUNCTION_URL/azure_openai_monitor/health_check}"

        print_info "函数应用URL: $FUNCTION_URL"
        print_info "健康检查URL: $HEALTH_URL"

        # 运行连接测试
        az webapp config appsettings set \
            --resource-group $RESOURCE_GROUP \
            --name $APP_NAME \
            --settings "RUN_CONNECTION_TEST=true"

        print_info "验证完成"
        print_warning "请等待1-2分钟后检查函数执行日志"
    else
        print_warning "无法获取函数应用URL，请手动验证部署"
    fi
}

# 生成复制脚本
generate_scale_script() {
    print_info "生成扩展部署脚本..."

    source .env

    mkdir -p scripts

    cat > scripts/scale-deployment.sh << 'EOSCRIPT'
#!/bin/bash
# 扩展部署脚本 - 用于在新环境中复制部署

set -e

# 配置新环境信息
NEW_RESOURCE_GROUP="$1"
NEW_OPENAI_SERVICES="$2"
NEW_APP_NAME="openai-monitor-$(whoami)-$(date +%s)"

if [ -z "$NEW_RESOURCE_GROUP" ] || [ -z "$NEW_OPENAI_SERVICES" ]; then
    echo "用法: $0 <资源组名称> <OpenAI服务名称(逗号分隔)>"
    exit 1
fi

echo "在资源组 $NEW_RESOURCE_GROUP 中部署监控服务..."
echo "监控服务: $NEW_OPENAI_SERVICES"

# 使用现有Azure AD应用配置
AZURE_TENANT_ID="REPLACE_TENANT_ID"
AZURE_CLIENT_ID="REPLACE_CLIENT_ID"
AZURE_CLIENT_SECRET="REPLACE_CLIENT_SECRET"
AZURE_SUBSCRIPTION_ID="REPLACE_SUBSCRIPTION_ID"

# 构建服务配置
SERVICES_JSON="["
IFS=',' read -ra SERVICES <<< "$NEW_OPENAI_SERVICES"
for i in "${!SERVICES[@]}"; do
    service=$(echo "${SERVICES[$i]}" | xargs)
    if [ $i -gt 0 ]; then
        SERVICES_JSON="$SERVICES_JSON,"
    fi
    SERVICES_JSON="$SERVICES_JSON{\"name\":\"$service\",\"resource_group\":\"$NEW_RESOURCE_GROUP\",\"subscription_id\":\"$AZURE_SUBSCRIPTION_ID\"}"
done
SERVICES_JSON="$SERVICES_JSON]"

# 创建资源组
az group create --name $NEW_RESOURCE_GROUP --location eastus

# 创建Function App
az functionapp create \
    --resource-group $NEW_RESOURCE_GROUP \
    --consumption-plan-location eastus \
    --runtime python \
    --runtime-version 3.9 \
    --functions-version 4 \
    --name $NEW_APP_NAME \
    --storage-account $NEW_APP_NAME"storage"

# 配置应用设置
az functionapp config appsettings set \
    --resource-group $NEW_RESOURCE_GROUP \
    --name $NEW_APP_NAME \
    --settings \
    "AZURE_TENANT_ID=$AZURE_TENANT_ID" \
    "AZURE_CLIENT_ID=$AZURE_CLIENT_ID" \
    "AZURE_CLIENT_SECRET=$AZURE_CLIENT_SECRET" \
    "AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID" \
    "MONITOR_SERVICES_JSON=$SERVICES_JSON" \
    "MONITOR_429_THRESHOLD=10" \
    "MONITOR_CHECK_INTERVAL=5" \
    "MONITOR_KEY_DISABLE_DURATION=1"

# 部署代码
func azure functionapp publish $NEW_APP_NAME

echo "扩展部署完成！"
echo "函数应用名称: $NEW_APP_NAME"
echo "资源组: $NEW_RESOURCE_GROUP"
EOSCRIPT

    # 替换占位符
    sed -i "s/REPLACE_TENANT_ID/$AZURE_TENANT_ID/g" scripts/scale-deployment.sh
    sed -i "s/REPLACE_CLIENT_ID/$AZURE_CLIENT_ID/g" scripts/scale-deployment.sh
    sed -i "s/REPLACE_CLIENT_SECRET/$AZURE_CLIENT_SECRET/g" scripts/scale-deployment.sh
    sed -i "s/REPLACE_SUBSCRIPTION_ID/$AZURE_SUBSCRIPTION_ID/g" scripts/scale-deployment.sh

    chmod +x scripts/scale-deployment.sh

    print_info "扩展部署脚本已生成: scripts/scale-deployment.sh"
}

# 主函数
main() {
    echo "=== Azure OpenAI 监控服务部署脚本 ==="
    echo

    # 检查是否是首次部署
    if [ -f ".env" ]; then
        print_warning "检测到现有配置文件"
        read -p "是否继续使用现有配置？(y/N): " USE_EXISTING
        if [[ $USE_EXISTING != "y" && $USE_EXISTING != "Y" ]]; then
            rm .env
        fi
    fi

    if [ ! -f ".env" ]; then
        check_dependencies
        login_azure
        setup_azure_ad_app
        setup_environment
        deploy_functions
        configure_app_settings
        deploy_code
        verify_deployment
        generate_scale_script

        echo
        print_info "=== 部署完成 ==="
        print_info "配置文件: .env"
        print_info "扩展部署脚本: scripts/scale-deployment.sh"
        echo
        print_warning "请保存 .env 文件，包含重要的认证信息"
        print_warning "建议查看 Azure Functions 日志确认监控正常运行"

    else
        print_info "使用现有配置部署..."
        deploy_code
        verify_deployment
    fi
}

# 执行主函数
main "$@"