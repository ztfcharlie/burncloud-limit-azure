# 详细部署指南

本指南详细说明如何部署和配置 Azure OpenAI 监控服务。

## 前置条件

### 1. 安装必要工具

#### 安装 Azure CLI
```bash
# Windows (使用 PowerShell)
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'

# 或者使用 Chocolatey
choco install azure-cli

# 验证安装
az --version
```

#### 安装 Azure Functions Core Tools
```bash
# Windows
npm install -g azure-functions-core-tools@4 --unsafe-perm true

# 验证安装
func --version
```

### 2. 准备 Azure 环境

确保你有以下权限：
- 创建和管理 Azure AD 应用
- 创建和管理资源组
- 创建和管理 Function App
- 访问 Azure Monitor 和 Cognitive Services

## 部署步骤

### 步骤 1: 登录 Azure

```bash
az login
```

### 步骤 2: 准备项目文件

确保项目文件结构完整：

```
D:\www\burncloud-api-azure-limit\
├── src\
│   ├── __init__.py
│   ├── function.json
│   ├── host.json
│   ├── requirements.txt
│   ├── local.settings.json
│   └── monitor\
├── deployment\
│   ├── deploy.sh
│   ├── arm-template.json
│   └── parameters.json
└── docs\
```

### 步骤 3: 执行部署脚本

```bash
# 在项目根目录执行
bash deployment/deploy.sh
```

部署脚本会逐步引导你完成：

#### 3.1 创建 Azure AD 应用

脚本会自动创建：
- Azure AD 应用程序
- 服务主体
- 客户端密钥

#### 3.2 配置权限

自动分配的权限：
- `Monitoring Reader`: 读取监控数据
- `Cognitive Services Contributor`: 管理认知服务

#### 3.3 配置监控参数

需要提供的信息：
- Azure 订阅ID
- 资源组名称
- OpenAI 服务名称
- 监控阈值和间隔

#### 3.4 部署基础设施

创建的 Azure 资源：
- Function App
- 存储账户
- 应用服务计划

#### 3.5 部署和配置代码

- 上传函数代码
- 配置应用设置
- 启动监控服务

### 步骤 4: 验证部署

#### 4.1 检查部署状态

```bash
# 检查 Function App 状态
az functionapp show --resource-group <rg-name> --name <app-name>

# 检查应用设置
az functionapp config appsettings list --resource-group <rg-name> --name <app-name>
```

#### 4.2 测试健康检查端点

```bash
# 获取 Function App URL
FUNCTION_URL=$(az functionapp function list --resource-group <rg-name> --name <app-name> --query [0].invokeUrlTemplate -o tsv)

# 测试健康检查
curl "${FUNCTION_URL/azure_openai_monitor/health_check}"
```

#### 4.3 查看日志

在 Azure Portal 中：
1. 导航到 Function App
2. 点击 "Log Stream"
3. 观察监控日志输出

## 配置详解

### 监控配置参数

| 参数 | 说明 | 默认值 | 建议 |
|------|------|--------|------|
| `MONITOR_CHECK_INTERVAL` | 检查间隔（秒） | 5 | 高频监控使用5秒 |
| `MONITOR_429_THRESHOLD` | 429错误阈值 | 10 | 根据业务量调整 |
| `MONITOR_KEY_DISABLE_DURATION` | Key禁用时长（分钟） | 1 | 通常1分钟足够 |

### 邮件告警配置

#### Gmail 配置示例
```bash
SMTP_SERVER=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password  # 使用应用专用密码
FROM_EMAIL=your-email@gmail.com
ALERT_EMAIL_RECIPIENTS=admin@company.com,ops@company.com
```

#### Outlook/Exchange 配置示例
```bash
SMTP_SERVER=smtp-mail.outlook.com
SMTP_PORT=587
SMTP_USERNAME=your-email@outlook.com
SMTP_PASSWORD=your-password
```

### Webhook 告警配置

#### Teams Webhook
```bash
ALERT_WEBHOOK_URL=https://outlook.office.com/webhook/YOUR-TEAMS-WEBHOOK-URL
```

#### Slack Webhook
```bash
ALERT_WEBHOOK_URL=https://your-slack-workspace.slack.com/services/YOUR/WEBHOOK/URL
```

#### 自定义 Webhook
```bash
ALERT_WEBHOOK_URL=https://your-api.com/webhooks/azure-alerts
```

## 高级配置

### 多订阅监控

配置跨订阅监控：

```json
[
  {
    "name": "openai-service-sub1",
    "resource_group": "rg-sub1",
    "subscription_id": "sub1-uuid"
  },
  {
    "name": "openai-service-sub2",
    "resource_group": "rg-sub2",
    "subscription_id": "sub2-uuid"
  }
]
```

### 自定义监控逻辑

修改 `src/monitor/core/monitor_service.py` 中的监控逻辑：

```python
async def custom_monitoring_logic(self, service_config):
    # 自定义监控逻辑
    error_count = await self.metrics_client.get_429_metrics(service_config)

    # 自定义阈值
    custom_threshold = self.get_custom_threshold(service_config)

    if error_count >= custom_threshold:
        # 自定义响应逻辑
        await self.custom_response_handler(service_config, error_count)
```

## 性能优化

### 函数应用配置

在 Azure Portal 中优化 Function App：

1. **内存配置**: 根据监控服务数量调整内存
2. **超时设置**: 设置适当的函数超时时间
3. **并发控制**: 配置并发执行数量

### 监控频率调优

根据业务需求调整监控频率：

- **高频监控**: 5秒间隔，适用于关键业务
- **常规监控**: 30秒间隔，适用于一般业务
- **低频监控**: 1分钟间隔，适用于非关键业务

## 故障排除

### 常见错误和解决方案

#### 1. 认证失败
```
Error: Failed to get access token: 401
```

**解决方案**:
- 检查 Azure AD 应用凭据
- 确认权限分配正确
- 验证租户ID和订阅ID

#### 2. Metrics API 访问失败
```
Error: Metrics API error: 403 - Forbidden
```

**解决方案**:
- 确认 Monitoring Reader 权限
- 检查资源ID格式
- 验证服务名称拼写

#### 3. 部署失败
```
Error: Deployment failed: Invalid template
```

**解决方案**:
- 检查 ARM 模板语法
- 确认资源组存在
- 验证参数格式

### 调试技巧

#### 启用详细日志
```bash
az functionapp config appsettings set \
  --resource-group <rg-name> \
  --name <app-name> \
  --settings "LOGGING_LEVEL=DEBUG"
```

#### 本地调试
```bash
# 在本地运行
func start

# 使用本地设置
cp src/local.settings.json.template src/local.settings.json
# 编辑 local.settings.json 添加配置
```

## 维护和更新

### 更新监控代码

```bash
# 部署新版本
func azure functionapp publish <app-name>

# 验证更新
curl "https://<app-name>.azurewebsites.net/api/health"
```

### 备份配置

定期备份重要配置：

```bash
# 备份应用设置
az functionapp config appsettings list --resource-group <rg-name> --name <app-name> > app-settings-backup.json

# 备份 Function App 配置
az functionapp show --resource-group <rg-name> --name <app-name> > function-app-backup.json
```

## 扩展和集成

### 集成 Application Insights

```bash
# 启用 Application Insights
az monitor app-insights component create \
  --app <app-insights-name> \
  --location <location> \
  --resource-group <rg-name>

# 连接到 Function App
az functionapp config appsettings set \
  --resource-group <rg-name> \
  --name <app-name> \
  --settings "APPINSIGHTS_INSTRUMENTATIONKEY=<instrumentation-key>"
```

### 集成 Azure Monitor 警报

```bash
# 创建 Metric 警告规则
az monitor metrics alert create \
  --name "High-429-Errors" \
  --resource-group <rg-name> \
  --scopes <resource-id> \
  --condition "max TotalRequests > 10" \
  --window-size 1m \
  --evaluation-frequency 1m \
  --action-group <action-group-name>
```

## 最佳实践

1. **安全性**
   - 定期轮换 Azure AD 应用密钥
   - 使用最小权限原则
   - 启用网络访问限制

2. **可靠性**
   - 配置多个告警渠道
   - 设置健康检查监控
   - 定期测试故障恢复

3. **性能**
   - 根据业务量调整监控频率
   - 监控函数执行时间和成本
   - 优化代码并发性能

4. **运维**
   - 建立日志分析流程
   - 定期备份配置
   - 制定故障响应计划