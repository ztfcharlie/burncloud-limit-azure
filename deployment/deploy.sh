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

# 验证资源组
validate_resource_group() {
    print_info "验证资源组..."

    # 检查资源组是否存在
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        RG_INFO=$(az group show --name "$RESOURCE_GROUP" --query "{name:name, location:location}" -o tsv)
        RESOURCE_GROUP_LOCATION=$(echo $RG_INFO | cut -f2)
        print_info "✅ 资源组 '$RESOURCE_GROUP' 已存在于位置: $RESOURCE_GROUP_LOCATION"
        return 0
    else
        print_error "❌ 资源组 '$RESOURCE_GROUP' 不存在！"
        print_info "请先创建资源组："
        echo "az group create --name $RESOURCE_GROUP --location <your-location>"
        echo ""
        print_info "常用位置选项："
        echo "  - eastus (美国东部)"
        echo "  - westus2 (美国西部2)"
        echo "  - centralus (美国中部)"
        echo "  - westeurope (西欧)"
        echo "  - japaneast (日本东部)"
        echo ""

        while true; do
            read -p "资源组创建完成后按回车继续验证，或输入 'q' 退出: " user_input
            if [[ $user_input == "q" || $user_input == "Q" ]]; then
                print_error "部署已取消"
                exit 1
            fi

            # 重新验证
            if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
                RESOURCE_GROUP_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
                print_info "✅ 资源组验证成功！位置: $RESOURCE_GROUP_LOCATION"
                return 0
            else
                print_warning "⚠️ 资源组仍未找到，请确保已正确创建"
            fi
        done
    fi
}

# 验证OpenAI服务
validate_openai_services() {
    print_info "验证OpenAI服务..."

    IFS=',' read -ra SERVICES <<< "$OPENAI_SERVICES"
    VALID_SERVICES=()
    INVALID_SERVICES=()

    for service in "${SERVICES[@]}"; do
        service=$(echo "$service" | xargs)  # 去除空格
        if az cognitiveservices account show --name "$service" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
            VALID_SERVICES+=("$service")
            print_info "✅ OpenAI服务 '$service' 验证成功"
        else
            INVALID_SERVICES+=("$service")
            print_error "❌ OpenAI服务 '$service' 未找到"
        fi
    done

    if [ ${#INVALID_SERVICES[@]} -gt 0 ]; then
        print_error "以下OpenAI服务验证失败："
        for service in "${INVALID_SERVICES[@]}"; do
            echo "  - $service"
        done
        print_info "请检查："
        echo "  1. 服务名称是否正确"
        echo "  2. 服务是否在指定的资源组中"
        echo "  3. 是否有访问权限"
        echo ""

        read -p "是否继续部署有效的服务？(y/N): " continue_anyway
        if [[ $continue_anyway != "y" && $continue_anyway != "Y" ]]; then
            print_error "部署已取消"
            exit 1
        fi

        # 更新服务列表为有效的服务
        OPENAI_SERVICES=$(IFS=','; echo "${VALID_SERVICES[*]}")
        print_info "将部署监控服务：$OPENAI_SERVICES"
    fi
}

# 验证Function App
validate_function_app() {
    print_info "检查Function App..."

    source .env

    if az functionapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        print_warning "⚠️ Function App '$APP_NAME' 已存在"

        echo ""
        print_info "现有Function App信息："
        az functionapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query "{name:name, state:state, location:location, runtime:runtime}" -o tsv
        echo ""

        while true; do
            echo "请选择操作："
            echo "  1. 重新部署代码（覆盖）"
            echo "  2. 更新配置"
            echo "  3. 取消部署"
            read -p "请输入选择 (1-3): " choice

            case $choice in
                1)
                    print_info "将重新部署代码到现有Function App"
                    EXISTING_APP="redeploy"
                    break
                    ;;
                2)
                    print_info "将仅更新现有Function App配置"
                    EXISTING_APP="update_config"
                    break
                    ;;
                3)
                    print_error "部署已取消"
                    exit 1
                    ;;
                *)
                    print_warning "无效选择，请输入 1、2 或 3"
                    ;;
            esac
        done
    else
        print_info "✅ 将创建新的Function App: $APP_NAME"
        EXISTING_APP="new"
    fi
}

# 部署Azure Functions
deploy_functions() {
    print_info "部署Azure Functions..."

    source .env

    # 根据验证结果处理资源组（已验证存在，不再创建）
    print_info "使用资源组: $RESOURCE_GROUP (位置: $RESOURCE_GROUP_LOCATION)"

    # 根据Function App验证结果进行处理
    if [[ "$EXISTING_APP" == "new" ]]; then
        print_info "创建新的Function App..."
        # 创建Function App
        az functionapp create \
            --resource-group "$RESOURCE_GROUP" \
            --consumption-plan-location "$RESOURCE_GROUP_LOCATION" \
            --runtime python \
            --runtime-version 3.9 \
            --functions-version 4 \
            --name "$APP_NAME" \
            --storage-account "${APP_NAME}storage"

        print_info "✅ 新Function App创建完成"
    else
        print_info "使用现有Function App: $APP_NAME"
    fi

    # 生成部署参数（使用验证过的位置）
    cat > deployment/parameters.json << EOF
{
    "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "functionAppName": {
            "value": "$APP_NAME"
        },
        "location": {
            "value": "$RESOURCE_GROUP_LOCATION"
        }
    }
}
EOF

    print_info "✅ Azure Functions基础架构配置完成"
}

# 部署代码
deploy_code() {
    source .env

    # 根据验证结果决定部署方式
    case "$EXISTING_APP" in
        "new"|"redeploy")
            print_info "部署函数代码到Function App..."
            # 发布函数代码
            func azure functionapp publish "$APP_NAME"
            print_info "✅ 代码部署完成"
            ;;
        "update_config")
            print_info "跳过代码部署，仅更新配置..."
            print_info "ℹ️ 如需重新部署代码，请选择选项1"
            ;;
        *)
            print_error "未知的部署状态: $EXISTING_APP"
            exit 1
            ;;
    esac
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

        # 新增验证步骤
        validate_resource_group
        validate_openai_services
        validate_function_app

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
        # 加载现有配置并验证
        setup_environment
        validate_resource_group
        validate_openai_services
        validate_function_app
        deploy_code
        verify_deployment
    fi
}

# 执行主函数
main "$@"