 使用部署脚本需要提供的信息
使用Azure Cloud Shell

  🔐 前置条件

  1. 已登录Azure账号

  # 脚本会自动执行这一步
  az login

  📋 脚本运行时需要你输入的信息

  必填信息

  1. Azure订阅ID
     - 脚本会显示当前登录账号的订阅ID
     - 可以直接回车使用默认值，或输入其他订阅ID
    测试：12345678-1234-1234-1234-123456789012  


  2. 资源组名称
     - 输入OpenAI服务所在的资源组名称
     - 例如：my-production-rg
     - 测试：my-test-resource-group

  3. OpenAI服务名称
     - 输入要监控的OpenAI服务名称
     - 多个服务用逗号分隔，例如：openai-service1,openai-service2
     - 测试：my-openai-service

  可选配置（有默认值）

  1. 429错误阈值
     - 默认：10次
     - 触发保护措施的429错误次数

  2. 检查间隔秒数
     - 默认：5秒
     - 监控检查的频率

  3. Key禁用时长分钟数
     - 默认：1分钟
     - 检测到429错误后禁用API Key的时长

  🎯 具体交互示例

  === Azure OpenAI 监控服务部署脚本 ===

  [INFO] 检查依赖...
  [INFO] 登录Azure...
  # （会弹出浏览器登录）

  [INFO] 设置Azure AD应用...

  [INFO] 配置环境变量...
  请输入Azure订阅ID [当前: 12345678-1234-1234-1234-123456789012]:
  # 直接回车使用当前订阅

  请输入资源组名称: my-openai-rg
  # 输入你的资源组名

  请输入要监控的OpenAI服务名称 (多个用逗号分隔): openai-gpt4,openai-text-davinci
  # 输入服务名称

  请输入429错误阈值 (默认10):
  # 直接回车使用默认值10

  请输入检查间隔秒数 (默认5):
  # 直接回车使用默认值5

  请输入Key禁用时长分钟数 (默认1):
  # 直接回车使用默认值1

  💡 需要提前准备的信息

  必须准备的

  1. Azure订阅ID - 可以从Azure Portal获取
  2. 资源组名称 - OpenAI服务所在的资源组
  3. OpenAI服务名称 - 准确的服务名称列表

  如何获取这些信息？

  方法1：通过Azure Portal
  - 订阅ID：Portal首页 → 订阅
  - 资源组：搜索"资源组" → 找到对应的
  - OpenAI服务：搜索"Azure OpenAI" → 查看服务名称

  方法2：通过Azure CLI
  # 查看所有订阅
  az account list --output table

  # 查看所有资源组
  az group list --output table

  # 查看所有OpenAI服务
  az cognitiveservices account list --query "[?kind=='OpenAI']" --output table

  ⚠️ 注意事项

  1. 权限要求：你的Azure账号需要有创建资源的权限
  2. 名称准确性：OpenAI服务名称必须完全准确
  3. 资源组存在：指定的资源组必须已存在
  4. 网络环境：确保能访问Azure服务

  🚀 最简操作流程

  1. 准备信息：订阅ID、资源组名、OpenAI服务名
  2. 运行脚本：bash deployment/deploy.sh
  3. 按提示输入：依次输入上述信息
  4. 等待完成：脚本自动完成所有部署步骤

  具体这里查看
  https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps

  整个过程大约需要5-10分钟，大部分时间是Azure资源创建。