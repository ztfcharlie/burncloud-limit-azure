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

# 检查现有的Azure AD应用
check_existing_apps() {
    local search_term="openai-monitor"
    print_info "🔍 搜索现有的Azure AD应用..."

    # 搜索相关的应用程序
    local apps=$(az ad app list --filter "contains(displayName,'${search_term}') or contains(displayName,'monitor')" --output json 2>/dev/null)

    if [ -z "$apps" ] || [ "$apps" == "[]" ]; then
        print_info "❌ 未找到相关的Azure AD应用"
        return 1
    fi

    # 解析并显示应用程序
    local app_count=$(echo "$apps" | jq '. | length')
    print_info "✅ 找到 ${app_count} 个相关的Azure AD应用："
    echo ""

    # 创建临时文件存储应用信息
    echo "$apps" > /tmp/existing_apps.json

    local index=1
    echo "$apps" | jq -r '.[] | [.displayName, .appId, .createdDateTime] | @tsv' | while IFS=$'\t' read -r name app_id created_date; do
        echo "[$index] $name"
        echo "    🆔 App ID: $app_id"
        echo "    📅 创建时间: ${created_date:0:10}"
        echo ""

        # 获取凭据信息
        local creds=$(az ad app credential list --id "$app_id" --output json 2>/dev/null)
        local cred_count=0
        if [ "$creds" != "[]" ] && [ -n "$creds" ]; then
            cred_count=$(echo "$creds" | jq '. | length')
        fi
        echo "    🔑 现有凭据: $cred_count 个"
        echo ""
        ((index++))
    done

    return 0
}

# 获取应用详细信息
get_app_details() {
    local app_id="$1"
    print_info "📊 获取应用详细信息: $app_id"

    local app_details=$(az ad app show --id "$app_id" --output json 2>/dev/null)
    if [ -z "$app_details" ]; then
        print_error "❌ 无法获取应用信息"
        return 1
    fi

    echo ""
    echo "📋 应用详细信息:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🏷️  显示名称: $(echo "$app_details" | jq -r '.displayName')"
    echo "🆔 应用程序ID: $(echo "$app_details" | jq -r '.appId')"
    echo "📅 创建时间: $(echo "$app_details" | jq -r '.createdDateTime')"
    echo "🌐 登录受众: $(echo "$app_details" | jq -r '.signInAudience')"
    echo "🔗 标识URI: $(echo "$app_details" | jq -r '.identifierUris[0] // "未设置"')"

    # 获取凭据信息
    local creds=$(az ad app credential list --id "$app_id" --output json 2>/dev/null)
    local cred_count=0
    if [ "$creds" != "[]" ] && [ -n "$creds" ]; then
        cred_count=$(echo "$creds" | jq '. | length')
    fi
    echo "🔑 现有凭据: $cred_count 个"

    # 检查服务主体
    local sp_info=$(az ad sp show --id "$app_id" --output json 2>/dev/null)
    if [ -n "$sp_info" ]; then
        echo "🎭 服务主体: ✅ 已创建"
        echo "📅 SP创建时间: $(echo "$sp_info" | jq -r '.createdDateTime')"
    else
        echo "🎭 服务主体: ❌ 未创建"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# 为现有应用创建新的客户端密钥
create_new_secret_for_existing_app() {
    local app_id="$1"
    local app_name="$2"

    print_info "🔑 为现有应用创建新的客户端密钥..."
    print_warning "⚠️  新密钥创建后，旧密钥仍然有效直到过期"

    # 创建新的客户端密钥
    local new_secret=$(az ad app credential reset --id "$app_id" --append --years 2 --output json 2>/dev/null)
    if [ -z "$new_secret" ]; then
        print_error "❌ 创建客户端密钥失败"
        return 1
    fi

    local client_secret=$(echo "$new_secret" | jq -r '.password')
    local tenant_id=$(az account show --query tenantId -o tsv)

    print_info "✅ 新的客户端密钥已创建"
    echo ""
    echo "🔐 认证信息（请妥善保存）:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🏷️  应用名称: $app_name"
    echo "🆔 Client ID: $app_id"
    echo "🔑 Client Secret: $client_secret"
    echo "🏢 Tenant ID: $tenant_id"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "⚠️  请立即保存以上信息，客户端密钥不会再次显示！"

    # 保存到.env文件
    cat > .env << EOF
AZURE_TENANT_ID=$tenant_id
AZURE_CLIENT_ID=$app_id
AZURE_CLIENT_SECRET=$client_secret
APP_NAME=$app_name
EXISTING_APP=true
EOF

    return 0
}

# 选择现有的Azure AD应用
select_existing_app() {
    print_info "🎯 选择要使用的现有Azure AD应用"

    # 重新列出应用供选择
    local apps=$(az ad app list --filter "contains(displayName,'openai') or contains(displayName,'monitor')" --output json 2>/dev/null)

    if [ -z "$apps" ] || [ "$apps" == "[]" ]; then
        print_error "❌ 未找到可用的应用"
        return 1
    fi

    # 显示应用列表供选择
    echo "可用的应用程序："
    local index=1
    local app_ids=()

    echo "$apps" | jq -r '.[] | [.displayName, .appId] | @tsv' | while IFS=$'\t' read -r name app_id; do
        echo "[$index] $name (ID: $app_id)"
        app_ids+=("$app_id")
        ((index++))
    done

    echo ""
    while true; do
        read -p "请输入要使用的应用编号 (1-$((index-1)))，或输入 'q' 返回: " choice

        if [[ $choice == "q" || $choice == "Q" ]]; then
            return 1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$index" ]; then
            local selected_app=$(echo "$apps" | jq -r ".[$((choice-1))]")
            local selected_app_id=$(echo "$selected_app" | jq -r '.appId')
            local selected_app_name=$(echo "$selected_app" | jq -r '.displayName')

            print_info "✅ 已选择应用: $selected_app_name"

            # 确保服务主体存在
            if ! az ad sp show --id "$selected_app_id" &> /dev/null; then
                print_info "🎭 创建服务主体..."
                az ad sp create --id "$selected_app_id" &> /dev/null
                print_info "✅ 服务主体创建完成"
            fi

            # 询问是否创建新的客户端密钥
            echo ""
            read -p "是否为此应用创建新的客户端密钥？(y/N): " create_new_secret

            if [[ $create_new_secret == "y" || $create_new_secret == "Y" ]]; then
                create_new_secret_for_existing_app "$selected_app_id" "$selected_app_name"
            else
                # 使用现有凭据
                local tenant_id=$(az account show --query tenantId -o tsv)
                cat > .env << EOF
AZURE_TENANT_ID=$tenant_id
AZURE_CLIENT_ID=$selected_app_id
# AZURE_CLIENT_SECRET=请手动设置现有的客户端密钥
APP_NAME=$selected_app_name
EXISTING_APP=true
EOF
                print_warning "⚠️  请在.env文件中手动设置现有的AZURE_CLIENT_SECRET"
            fi

            return 0
        else
            print_warning "⚠️  无效选择，请输入 1-$((index-1)) 之间的数字"
        fi
    done
}

# 创建新的Azure AD应用
create_new_azure_ad_app() {
    local app_name="$1"
    print_info "🆕 创建新的Azure AD应用: $app_name"

    # 创建Azure AD应用
    local app_info=$(az ad app create --display-name "$app_name" --sign-in-audience AzureADMyOrg --output json)
    local app_id=$(echo "$app_info" | jq -r '.appId')

    if [ -z "$app_id" ] || [ "$app_id" == "null" ]; then
        print_error "❌ Azure AD应用创建失败"
        return 1
    fi

    print_info "✅ Azure AD应用已创建，App ID: $app_id"

    # 创建服务主体
    print_info "🎭 创建服务主体..."
    az ad sp create --id "$app_id" &> /dev/null
    print_info "✅ 服务主体创建完成"

    # 创建客户端密钥
    print_info "🔑 创建客户端密钥..."
    local secret_info=$(az ad app credential reset --id "$app_id" --years 2 --output json)
    local client_secret=$(echo "$secret_info" | jq -r '.password')

    if [ -z "$client_secret" ] || [ "$client_secret" == "null" ]; then
        print_error "❌ 客户端密钥创建失败"
        return 1
    fi

    # 获取租户ID
    local tenant_id=$(az account show --query tenantId -o tsv)

    # 保存配置信息
    cat > .env << EOF
AZURE_TENANT_ID=$tenant_id
AZURE_CLIENT_ID=$app_id
AZURE_CLIENT_SECRET=$client_secret
APP_NAME=$app_name
EXISTING_APP=false
EOF

    print_info "✅ Azure AD应用配置完成"
    echo ""
    echo "🔐 认证信息（请妥善保存）:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🏷️  应用名称: $app_name"
    echo "🆔 Client ID: $app_id"
    echo "🔑 Client Secret: $client_secret"
    echo "🏢 Tenant ID: $tenant_id"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "⚠️  请立即保存以上信息，客户端密钥不会再次显示！"

    # 分配权限
    print_info "🔐 分配权限..."

    # 等待应用创建完成
    print_info "⏳ 等待应用传播..."
    sleep 20

    # 分配权限
    local subscription_id=$(az account show --query id -o tsv)

    # 分配Monitor Reader权限
    az role assignment create --assignee "$app_id" --role "Monitoring Reader" --scope "/subscriptions/$subscription_id" &> /dev/null

    # 分配Cognitive Services Contributor权限到资源组（如果资源组已知）
    if [ -n "$RESOURCE_GROUP" ]; then
        az role assignment create --assignee "$app_id" --role "Cognitive Services Contributor" --scope "/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP" &> /dev/null
    fi

    print_info "✅ 权限分配完成"

    # 保存全局变量
    APP_NAME="$app_name"
    APP_ID="$app_id"
    CLIENT_SECRET="$client_secret"
    TENANT_ID="$tenant_id"

    return 0
}

# 查看特定应用的详细信息
view_app_details_interactive() {
    print_info "🔍 查看应用详细信息"

    local apps=$(az ad app list --filter "contains(displayName,'openai') or contains(displayName,'monitor')" --output json 2>/dev/null)

    if [ -z "$apps" ] || [ "$apps" == "[]" ]; then
        print_error "❌ 未找到可用的应用"
        return 1
    fi

    # 显示应用列表供选择
    echo "可用的应用程序："
    local index=1

    echo "$apps" | jq -r '.[] | [.displayName, .appId] | @tsv' | while IFS=$'\t' read -r name app_id; do
        echo "[$index] $name"
        ((index++))
    done

    echo ""
    while true; do
        read -p "请输入要查看的应用编号 (1-$((index-1)))，或输入 'q' 返回: " choice

        if [[ $choice == "q" || $choice == "Q" ]]; then
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$index" ]; then
            local selected_app=$(echo "$apps" | jq -r ".[$((choice-1))]")
            local selected_app_id=$(echo "$selected_app" | jq -r '.appId')

            get_app_details "$selected_app_id"
            return 0
        else
            print_warning "⚠️  无效选择，请输入 1-$((index-1)) 之间的数字"
        fi
    done
}

# 设置Azure AD应用（主函数）
setup_azure_ad_app() {
    print_info "🚀 Azure AD应用智能管理"
    echo ""

    # 首先检查是否有现有的相关应用
    if check_existing_apps; then
        # 有现有应用，显示菜单
        echo "请选择操作："
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1️⃣  使用现有的Azure AD应用"
        echo "2️⃣  查看现有应用详细信息"
        echo "3️⃣  创建新的Azure AD应用"
        echo "4️⃣  为现有应用创建新的客户端密钥"
        echo "5️⃣  退出"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        while true; do
            read -p "请输入您的选择 (1-5): " choice

            case $choice in
                1)
                    if select_existing_app; then
                        print_info "✅ 已选择现有应用"
                        return 0
                    else
                        print_warning "⚠️  选择应用失败，请重试"
                    fi
                    ;;
                2)
                    view_app_details_interactive
                    echo ""
                    echo "请选择操作："
                    echo "1️⃣  使用现有的Azure AD应用"
                    echo "3️⃣  创建新的Azure AD应用"
                    echo "5️⃣  退出"
                    ;;
                3)
                    local new_app_name="openai-monitor-$(whoami)-$(date +%Y%m%d-%H%M%S)"
                    if create_new_azure_ad_app "$new_app_name"; then
                        print_info "✅ 新Azure AD应用创建完成"
                        return 0
                    else
                        print_error "❌ 创建新应用失败"
                    fi
                    ;;
                4)
                    # 为现有应用创建新密钥
                    print_info "🔑 选择要创建新密钥的应用"
                    if select_existing_app; then
                        # select_existing_app 已经创建了新密钥
                        print_info "✅ 新密钥创建完成"
                        return 0
                    else
                        print_warning "⚠️  选择应用失败，请重试"
                    fi
                    ;;
                5)
                    print_info "👋 退出Azure AD应用设置"
                    exit 0
                    ;;
                *)
                    print_warning "⚠️  无效选择，请输入 1-5 之间的数字"
                    ;;
            esac
        done
    else
        # 没有现有应用，直接创建新的
        print_info "❌ 未找到相关应用，将创建新的Azure AD应用"
        echo ""
        local new_app_name="openai-monitor-$(whoami)-$(date +%Y%m%d-%H%M%S)"
        create_new_azure_ad_app "$new_app_name"
        return $?
    fi
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

    # 显示资源组位置信息
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        RG_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
        print_info "✅ 资源组 '$RESOURCE_GROUP' 位置: $RG_LOCATION"
        echo ""
        print_info "💡 监控架构说明："
        echo "   - Function App 将部署在: $RG_LOCATION"
        echo "   - 存储账户 将创建在: $RG_LOCATION"
        echo "   - 建议监控的OpenAI服务也在此区域以获得最佳性能"
        echo ""
        read -p "是否继续在此区域部署？(Y/n): " confirm_location

        if [[ $confirm_location == "n" || $confirm_location == "N" ]]; then
            print_error "❌ 部署已取消"
            print_info "💡 如需在其他区域部署，请选择对应区域的资源组"
            exit 1
        fi
    else
        print_warning "⚠️  资源组 '$RESOURCE_GROUP' 不存在，请先创建"
        exit 1
    fi

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
        RESOURCE_GROUP_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
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
            # 获取服务详细信息
            SERVICE_INFO=$(az cognitiveservices account show --name "$service" --resource-group "$RESOURCE_GROUP" --query "{name:name, location:location, kind:kind}" -o tsv)
            SERVICE_LOCATION=$(echo "$SERVICE_INFO" | cut -f2)

            VALID_SERVICES+=("$service")
            print_info "✅ OpenAI服务 '$service' 验证成功 (位置: $SERVICE_LOCATION)"

            # 检查区域匹配
            if [[ "$SERVICE_LOCATION" == "$RESOURCE_GROUP_LOCATION" ]]; then
                print_info "🎯 位置匹配，性能最优"
            else
                print_warning "⚠️  位置不匹配: 服务在 $SERVICE_LOCATION，Function App将在 $RESOURCE_GROUP_LOCATION"
                print_info "   跨区域监控可能会有额外延迟"
            fi
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

    # 保存状态到文件供其他函数使用
    echo "$EXISTING_APP" > /tmp/function_app_status.txt
}

# 部署Azure Functions
deploy_functions() {
    print_info "部署Azure Functions..."

    source .env

    # 根据验证结果处理资源组（已验证存在，不再创建）
    print_info "使用资源组: $RESOURCE_GROUP (位置: $RESOURCE_GROUP_LOCATION)"

    # 读取Function App状态
    if [ -f /tmp/function_app_status.txt ]; then
        EXISTING_APP=$(cat /tmp/function_app_status.txt)
    else
        EXISTING_APP="new"
    fi

    # 根据Function App验证结果进行处理
    if [[ "$EXISTING_APP" == "new" ]] || [[ -z "$EXISTING_APP" ]]; then
        print_info "创建新的Function App..."

        # 创建同区域的存储账户
        STORAGE_ACCOUNT="openaimonitor$(whoami)$(date +%Y%m%d)"
        print_info "创建同区域存储账户: $STORAGE_ACCOUNT (位置: $RESOURCE_GROUP_LOCATION)"

        if az storage account show --name "$STORAGE_ACCOUNT" &> /dev/null; then
            print_info "✅ 存储账户已存在"
        else
            az storage account create \
                --name "$STORAGE_ACCOUNT" \
                --resource-group "$RESOURCE_GROUP" \
                --location "$RESOURCE_GROUP_LOCATION" \
                --sku Standard_LRS \
                --kind StorageV2
            print_info "✅ 存储账户创建完成"
        fi

        # 创建Function App
        print_info "正在创建Function App: $APP_NAME"
        print_info "⏳ Function App创建需要2-3分钟，请耐心等待..."

        if az functionapp create \
            --resource-group "$RESOURCE_GROUP" \
            --consumption-plan-location "$RESOURCE_GROUP_LOCATION" \
            --runtime python \
            --runtime-version 3.9 \
            --functions-version 4 \
            --name "$APP_NAME" \
            --storage-account "$STORAGE_ACCOUNT"; then

            print_info "✅ Function App创建命令已发送"
            print_info "⏳ 等待Azure完成资源传播（最长3分钟）..."

            # 等待并验证创建成功
            local max_attempts=18  # 18次 × 10秒 = 3分钟
            local attempt=1

            while [ $attempt -le $max_attempts ]; do
                print_info "🔍 验证Function App创建状态... (尝试 $attempt/$max_attempts)"

                if az functionapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
                    local app_state=$(az functionapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query state -o tsv)
                    print_info "✅ Function App创建成功 (状态: $app_state)"
                    break
                else
                    if [ $attempt -eq $max_attempts ]; then
                        print_error "❌ Function App创建超时"
                        print_info "💡 请在Azure Portal检查是否创建成功"
                        return 1
                    fi
                    print_info "⏳ 等待10秒后重试..."
                    sleep 10
                    ((attempt++))
                fi
            done
        else
            print_error "❌ Function App创建失败"
            return 1
        fi
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

    # 读取Function App状态
    if [ -f /tmp/function_app_status.txt ]; then
        EXISTING_APP=$(cat /tmp/function_app_status.txt)
    else
        EXISTING_APP="new"
    fi

    # 根据验证结果决定部署方式
    case "$EXISTING_APP" in
        "new"|"redeploy")
            print_info "部署函数代码到Function App..."

            # 确保Function App完全可用后再部署代码
            print_info "🔍 验证Function App是否准备就绪..."
            local max_attempts=12  # 12次 × 5秒 = 1分钟
            local attempt=1

            while [ $attempt -le $max_attempts ]; do
                print_info "⏳ 检查Function App状态... (尝试 $attempt/$max_attempts)"

                local app_state=$(az functionapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query state -o tsv 2>/dev/null)

                if [[ "$app_state" == "Running" ]]; then
                    print_info "✅ Function App已就绪，开始部署代码..."

                    # 发布函数代码
                    print_info "📦 正在部署代码，这可能需要1-2分钟..."
                    if func azure functionapp publish "$APP_NAME"; then
                        print_info "✅ 代码部署完成"
                        break
                    else
                        print_error "❌ 代码部署失败"
                        return 1
                    fi
                elif [[ "$app_state" == "Starting" ]]; then
                    print_info "⏳ Function App正在启动，等待5秒..."
                    sleep 5
                    ((attempt++))
                else
                    print_warning "⚠️ Function App状态异常: $app_state"
                    print_info "⏳ 等待5秒后重试..."
                    sleep 5
                    ((attempt++))
                fi

                if [ $attempt -gt $max_attempts ]; then
                    print_error "❌ Function App未能在预期时间内就绪"
                    print_info "💡 请检查Azure Portal中的Function App状态"
                    return 1
                fi
            done
            ;;
        "update_config")
            print_info "跳过代码部署，仅更新配置..."
            print_info "ℹ️ 如需重新部署代码，请选择选项1"
            ;;
        *)
            print_error "未知的部署状态: $EXISTING_APP"
            print_info "🔍 调试信息：检查 /tmp/function_app_status.txt"
            print_info "🔍 调试信息：$(cat /tmp/function_app_status.txt 2>/dev/null || echo '文件不存在')"
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