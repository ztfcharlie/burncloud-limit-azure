#!/bin/bash
# 部署测试脚本

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

# 测试函数
test_function_exists() {
    local resource_group=$1
    local function_app_name=$2

    print_info "检查Function App是否存在..."

    if az functionapp show --resource-group "$resource_group" --name "$function_app_name" > /dev/null 2>&1; then
        print_info "Function App存在: $function_app_name"
        return 0
    else
        print_error "Function App不存在: $function_app_name"
        return 1
    fi
}

# 测试健康检查端点
test_health_endpoint() {
    local function_app_name=$1
    local timeout=${2:-30}

    print_info "测试健康检查端点..."

    # 获取Function App URL
    local function_url=$(az functionapp function list \
        --resource-group "$resource_group" \
        --name "$function_app_name" \
        --query "[0].invokeUrlTemplate" \
        -o tsv 2>/dev/null || echo "")

    if [ -z "$function_url" ]; then
        print_error "无法获取Function URL"
        return 1
    fi

    # 构建健康检查URL
    local health_url="${function_url/azure_openai_monitor/health_check}"

    print_info "健康检查URL: $health_url"

    # 测试连接
    local start_time=$(date +%s)
    local http_code="000"

    while [ $(( $(date +%s) - start_time )) -lt $timeout ]; do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            print_info "健康检查成功 (HTTP $http_code)"
            return 0
        elif [ "$http_code" = "503" ]; then
            print_warning "服务正在启动中 (HTTP $http_code)"
        else
            print_warning "收到响应: HTTP $http_code"
        fi

        sleep 5
    done

    print_error "健康检查失败 (最终HTTP状态: $http_code)"
    return 1
}

# 测试统计端点
test_stats_endpoint() {
    local function_app_name=$1
    local resource_group=$2

    print_info "测试统计端点..."

    # 获取Function App URL
    local function_url=$(az functionapp function list \
        --resource-group "$resource_group" \
        --name "$function_app_name" \
        --query "[0].invokeUrlTemplate" \
        -o tsv 2>/dev/null || echo "")

    if [ -z "$function_url" ]; then
        print_error "无法获取Function URL"
        return 1
    fi

    # 构建统计URL
    local stats_url="${function_url/azure_openai_monitor/stats}"

    # 测试连接
    local response=$(curl -s "$stats_url" 2>/dev/null || echo "")

    if [ -n "$response" ]; then
        print_info "统计端点测试成功"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 0
    else
        print_error "统计端点无响应"
        return 1
    fi
}

# 测试应用设置
test_app_settings() {
    local resource_group=$1
    local function_app_name=$2

    print_info "检查应用设置..."

    local required_settings=(
        "AZURE_TENANT_ID"
        "AZURE_CLIENT_ID"
        "AZURE_CLIENT_SECRET"
        "AZURE_SUBSCRIPTION_ID"
        "MONITOR_SERVICES_JSON"
    )

    local missing_settings=()

    for setting in "${required_settings[@]}"; do
        local value=$(az functionapp config appsettings list \
            --resource-group "$resource_group" \
            --name "$function_app_name" \
            --query "[?name=='$setting'].value | [0]" \
            -o tsv 2>/dev/null || echo "")

        if [ -z "$value" ] || [ "$value" = "null" ]; then
            missing_settings+=("$setting")
        fi
    done

    if [ ${#missing_settings[@]} -eq 0 ]; then
        print_info "所有必需的设置都已配置"
        return 0
    else
        print_error "缺少以下设置:"
        printf '  %s\n' "${missing_settings[@]}"
        return 1
    fi
}

# 测试权限配置
test_permissions() {
    local resource_group=$1
    local function_app_name=$2

    print_info "检查权限配置..."

    # 获取应用ID
    local client_id=$(az functionapp config appsettings list \
        --resource-group "$resource_group" \
        --name "$function_app_name" \
        --query "[?name=='AZURE_CLIENT_ID'].value | [0]" \
        -o tsv 2>/dev/null || echo "")

    if [ -z "$client_id" ]; then
        print_error "无法获取客户端ID"
        return 1
    fi

    print_info "检查服务主体权限..."

    # 检查Monitoring Reader权限
    local subscription_id=$(az account show --query id -o tsv)
    local monitoring_role=$(az role assignment list \
        --assignee "$client_id" \
        --scope "/subscriptions/$subscription_id" \
        --query "[?roleDefinitionName=='Monitoring Reader'].roleDefinitionName | [0]" \
        -o tsv 2>/dev/null || echo "")

    if [ "$monitoring_role" = "Monitoring Reader" ]; then
        print_info "Monitoring Reader权限已分配"
    else
        print_warning "Monitoring Reader权限未分配"
    fi

    # 检查Cognitive Services Contributor权限
    local cognitive_role=$(az role assignment list \
        --assignee "$client_id" \
        --resource-group "$resource_group" \
        --query "[?roleDefinitionName=='Cognitive Services Contributor'].roleDefinitionName | [0]" \
        -o tsv 2>/dev/null || echo "")

    if [ "$cognitive_role" = "Cognitive Services Contributor" ]; then
        print_info "Cognitive Services Contributor权限已分配"
    else
        print_warning "Cognitive Services Contributor权限未分配"
    fi

    return 0
}

# 主函数
main() {
    echo "=== Azure OpenAI Monitor 部署测试 ==="
    echo

    if [ $# -ne 2 ]; then
        echo "用法: $0 <resource-group> <function-app-name>"
        exit 1
    fi

    local resource_group=$1
    local function_app_name=$2

    print_info "测试环境:"
    echo "  资源组: $resource_group"
    echo "  Function App: $function_app_name"
    echo

    # 运行测试
    local tests_passed=0
    local tests_total=5

    # 测试1: Function App是否存在
    if test_function_exists "$resource_group" "$function_app_name"; then
        ((tests_passed++))
    fi
    echo

    # 测试2: 应用设置
    if test_app_settings "$resource_group" "$function_app_name"; then
        ((tests_passed++))
    fi
    echo

    # 测试3: 权限配置
    if test_permissions "$resource_group" "$function_app_name"; then
        ((tests_passed++))
    fi
    echo

    # 测试4: 健康检查端点
    if test_health_endpoint "$function_app_name" "$resource_group" 60; then
        ((tests_passed++))
    fi
    echo

    # 测试5: 统计端点
    if test_stats_endpoint "$function_app_name" "$resource_group"; then
        ((tests_passed++))
    fi
    echo

    # 显示测试结果
    print_info "=== 测试结果 ==="
    echo "通过: $tests_passed/$tests_total"

    if [ $tests_passed -eq $tests_total ]; then
        print_info "🎉 所有测试通过！部署成功。"
        exit 0
    else
        print_warning "部分测试失败，请检查配置。"
        exit 1
    fi
}

# 执行主函数
main "$@"