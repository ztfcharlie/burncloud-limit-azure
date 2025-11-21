# Azure OpenAI 监控服务

这是一个用于监控 Azure OpenAI 服务 API 调用状态的自动化监控服务，能够检测 429 错误（Too Many Requests）并**自动保护Azure账号安全**。

## 🛡️ 关键保护功能

当检测到 429 错误时，系统会：
- ✅ **自动禁用API Key** 1分钟（防止账号被Azure限制）
- ✅ **发送紧急告警** 通知管理员
- ✅ **自动重新启用** Key（1分钟后自动恢复）
- ✅ **智能Key轮换** 保护服务连续性

## 功能特性

- **实时监控**: 每5秒检查一次 Azure OpenAI 服务的 429 错误
- **自动保护**: 检测到429错误时自动禁用Key保护Azure账号
- **智能恢复**: 1分钟后自动重新启用Key，恢复服务
- **多服务支持**: 可同时监控多个 Azure OpenAI 服务
- **可扩展**: 支持跨订阅、跨资源组的监控
- **多级告警**: 支持邮件、Webhook和紧急保护告警
- **健康检查**: 内置健康检查和状态端点
- **安全防护**: 防止Azure订阅因限流被暂停（blended）

## 项目结构

```
azure-openai-monitor/
├── src/                         # 源代码
│   ├── __init__.py             # Azure Functions 主入口
│   ├── function.json           # Function 配置
│   ├── host.json               # Host 配置
│   ├── requirements.txt        # Python 依赖
│   ├── local.settings.json     # 本地开发配置
│   └── monitor/                # 监控模块
│       ├── config/             # 配置管理
│       ├── core/               # 核心监控逻辑
│       └── alerts/             # 告警系统
├── deployment/                 # 部署脚本和模板
│   ├── deploy.sh              # 一键部署脚本
│   ├── arm-template.json       # Azure 资源模板
│   └── parameters.json         # 部署参数
├── docs/                      # 文档
└── scripts/                   # 辅助脚本
```

## 快速开始

### 1. 环境要求

- Azure CLI
- Azure Functions Core Tools
- Python 3.9+

### 2. 一键部署

```bash
# 克隆或下载项目到本地
cd D:\www\burncloud-api-azure-limit

# 执行一键部署脚本
bash deployment/deploy.sh
```

部署脚本会自动：
- 创建 Azure AD 应用
- 分配必要权限
- 部署 Azure Functions
- 配置应用设置
- 部署监控代码

### 3. 配置监控服务

部署过程中需要提供以下信息：

- **Azure 订阅ID**: 要监控的订阅
- **资源组名称**: OpenAI 服务所在的资源组
- **OpenAI 服务名称**: 要监控的服务列表（逗号分隔）
- **429错误阈值**: 触发告警的429错误次数（默认10次）
- **检查间隔**: 监控检查间隔秒数（默认5秒）

### 4. 验证部署

部署完成后，可以通过以下方式验证：

1. **健康检查**: 访问 `https://<function-app-name>.azurewebsites.net/api/health`
2. **查看统计**: 访问 `https://<function-app-name>.azurewebsites.net/api/stats`
3. **查看日志**: 在 Azure Portal 中查看 Function App 的日志

## 配置说明

### 环境变量配置

| 变量名 | 必需 | 说明 |
|--------|------|------|
| `AZURE_TENANT_ID` | 是 | Azure 租户ID |
| `AZURE_CLIENT_ID` | 是 | Azure AD 应用客户端ID |
| `AZURE_CLIENT_SECRET` | 是 | Azure AD 应用客户端密钥 |
| `AZURE_SUBSCRIPTION_ID` | 是 | Azure 订阅ID |
| `MONITOR_SERVICES_JSON` | 是 | 要监控的服务配置（JSON格式） |
| `MONITOR_429_THRESHOLD` | 否 | 429错误阈值，默认10 |
| `MONITOR_CHECK_INTERVAL` | 否 | 检查间隔秒数，默认5 |
| `ALERT_EMAIL_ENABLED` | 否 | 是否启用邮件告警，默认true |
| `ALERT_EMAIL_RECIPIENTS` | 否 | 邮件接收者列表 |

### 监控服务配置示例

```json
{
  "name": "my-openai-service",
  "resource_group": "my-resource-group",
  "subscription_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "location": "eastus"
}
```

## 规模化部署

### 复制到新环境

使用生成的扩展部署脚本：

```bash
./scripts/scale-deployment.sh "新资源组名称" "service1,service2,service3"
```

### 配置多个服务

更新 `MONITOR_SERVICES_JSON` 环境变量：

```json
[
  {
    "name": "openai-service-1",
    "resource_group": "rg-1",
    "subscription_id": "sub-1"
  },
  {
    "name": "openai-service-2",
    "resource_group": "rg-2",
    "subscription_id": "sub-2"
  }
]
```

## 告警配置

### 邮件告警

在应用设置中配置 SMTP 相关参数：

```bash
SMTP_SERVER=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password
ALERT_EMAIL_RECIPIENTS=admin@company.com,ops@company.com
```

### Webhook 告警

配置 Webhook URL：

```bash
ALERT_WEBHOOK_URL=https://your-webhook-endpoint.com/alerts
```

## 故障排除

### 常见问题

1. **连接失败**: 检查 Azure AD 应用权限
2. **Metrics API 错误**: 确认服务名称和资源组正确
3. **告警不工作**: 检查 SMTP 或 Webhook 配置

### 日志查看

在 Azure Portal 中：
1. 导航到 Function App
2. 点击 "Log Stream"
3. 查看实时日志输出

### 调试模式

启用连接测试：

```bash
az functionapp config appsettings set \
  --resource-group <resource-group> \
  --name <function-app-name> \
  --settings "RUN_CONNECTION_TEST=true"
```

## API 端点

### 健康检查
```
GET /api/health
```

### 获取统计信息
```
GET /api/stats
```

### 获取保护状态报告
```
GET /api/protection
```
返回详细的账号保护状态和Key管理信息。

## 安全注意事项

1. **保护凭据**: 妥善保存 Azure AD 应用凭据
2. **最小权限**: 只授予必要的权限
3. **网络安全**: 启用 HTTPS 和网络限制
4. **日志安全**: 避免在日志中记录敏感信息

## 许可证

本项目采用 MIT 许可证。

## 支持

如有问题或建议，请创建 Issue 或联系技术支持。