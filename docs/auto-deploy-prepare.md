
● 🚀 Azure Cloud Shell 完整使用指南

  📋 步骤1：打开Azure Cloud Shell

  访问方式

  1. 浏览器直接访问：https://shell.azure.com
  2. 通过Azure Portal：
    - 登录 https://portal.azure.com
    - 点击顶部菜单栏的 Cloud Shell 图标（>_符号）

  首次使用设置

  1. 选择 Bash 环境（不是PowerShell）
  2. 选择创建存储账户（免费5GB）
  3. 等待环境初始化（约1-2分钟）
  4. 注册Microsoft.CloudShell服务，这是Cloud Shell的必需服务。

    方法1：通过Azure Portal注册（推荐）

    1. 访问Azure Portal：https://portal.azure.com
    2. **搜索"订阅"**或直接访问：https://portal.azure.com/#blade/HubsExtension/BrowseResourceGroups/resourceType/Microsoft.Subscription%2Fsubscriptions
    3. 选择你的订阅：12345678-1234-1234-1234-123456789012
    4. 点击左侧菜单"资源提供程序"
    5. 搜索"CloudShell"
    6.  找到"Microsoft.CloudShell"
    7.  点击它，然后点击"注册"
    8.  等待注册完成（通常1-2分钟）

    方法2：通过Azure CLI注册

    # 登录Azure
    az login

    # 设置订阅
    az account set --subscription 12345678-1234-1234-1234-123456789012

    # 注册CloudShell服务提供程序
    az provider register --namespace Microsoft.CloudShell

    # 检查注册状态
    az provider show --namespace Microsoft.CloudShell

  📁 步骤2：上传你的项目文件

  方法1：使用上传功能（推荐）

  1. 点击Cloud Shell工具栏的上传图标 📤
  2. 选择项目文件：
  上传这些文件/文件夹：
  - deployment/deploy.sh
  - deployment/arm-template.json
  - deployment/parameters.json
  - src/ 整个文件夹
  - docs/ 整个文件夹（可选）
  1. 文件会上传到当前目录：~/clouddrive/

  方法2：直接在Cloud Shell中创建文件

  # 创建项目目录
  mkdir -p ~/burncloud-limit-azure
  cd ~/burncloud-limit-azure

  # 创建部署脚本
  cat > deployment/deploy.sh << 'EOF'
  #!/bin/bash
  # 这里复制你的deploy.sh完整内容
  EOF

  🛠️ 步骤3：验证环境和工具

  检查工具是否可用

  # 检查Azure CLI
  az --version

  # 检查Functions Core Tools
  func --version

  # 检查Python版本
  python3 --version

  # 检查jq（JSON处理工具）
  jq --version

  如果某个工具不存在，手动安装：
  # 安装Functions Core Tools
  curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
  sudo mv microsoft.gpg /etc/apt/trusted.gpg.d/microsoft.gpg
  sudo sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-focal-prod focal main" > /etc/apt/sources.list.d/msprod.list'
  sudo apt-get update
  sudo apt-get install azure-functions-core-tools-4

  🔐 步骤4：登录Azure

  # 登录Azure账号
  az login

  系统会显示一个设备登录码，同时在浏览器打开登录页面，输入代码完成登录。

  🚀 步骤5：运行部署脚本

  # 进入项目目录
  cd ~/burncloud-limit-azure

  # 确保脚本有执行权限
  chmod +x deployment/deploy.sh

  # 运行部署脚本
  bash deployment/deploy.sh

  📝 脚本运行时的交互

  脚本会依次询问以下信息：

  === Azure OpenAI 监控服务部署脚本 ===

  [INFO] 检查依赖...

  请输入Azure订阅ID [当前: 12345678-1234-1234-1234-123456789012]:
  请输入资源组名称: your-resource-group
  请输入要监控的OpenAI服务名称 (多个用逗号分隔): OpenAICreate-20251121110008
  请输入429错误阈值 (默认10):
  请输入检查间隔秒数 (默认5):
  请输入Key禁用时长分钟数 (默认1):

  🎯 Cloud Shell的优势

  预装工具

  - ✅ Azure CLI
  - ✅ Python 3.x
  - ✅ Node.js
  - ✅ git
  - ✅ 大部分常用工具

  持久化存储

  - 文件保存在 ~/clouddrive/ 目录
  - 5GB免费存储空间
  - 下次登录文件仍在

  网络权限

  - 直接访问Azure服务
  - 无需配置防火墙

  💡 实用技巧

  文件管理

  # 查看上传的文件
  ls -la ~/clouddrive/

  # 创建新目录
  mkdir ~/projects

  # 复制文件到工作目录
  cp -r ~/clouddrive/burncloud-limit-azure ~/projects/

  保存重要信息

  # 部署完成后保存配置
  cp .env ~/clouddrive/backup/

  常用命令

  # 查看当前目录
  pwd

  # 查看文件内容
  cat deployment/deploy.sh

  # 编辑文件
  nano deployment/deploy.sh  # 或使用 vim

  ⚠️ 注意事项

  1. 会话超时：20分钟无操作会自动断开，但文件不会丢失
  2. 网络连接：需要稳定的网络连接
  3. 权限问题：确保Azure账号有足够权限
  4. 文件大小：上传的文件有大小限制（单个文件最大5GB）

  🎉 完成后

  部署完成后，你可以在Cloud Shell中：
  - 查看部署日志
  - 测试健康检查端点
  - 监控函数执行状态

  使用Azure Cloud Shell完全不占用你的电脑空间，而且环境预配置完整，是最理想的解决方案！

> Mount storage account
Azure Cloud Shell requires a storage account with Azure file share to persist files. Select an option below to mount a storage account. Learn more 这个选哪一项？ 

● 💾 Azure Cloud Shell 存储账户配置选择

  🎯 推荐选择：第一个选项 "Show advanced settings"

  📋 各选项说明

  选项1：Show advanced settings（推荐）

  - ✅ 可以指定资源组和位置
  - ✅ 避免创建不必要的资源
  - ✅ 完全控制存储配置
  - ✅ 可以复用现有存储（如果有）

  选项2：Create new storage

  - 自动创建新的存储账户
  - 使用随机名称和默认位置
  - 适合完全新用户

  选项3：Use existing storage

  - 选择已存在的存储账户
  - 需要你已经有配置好的存储

  🚀 推荐操作步骤

  选择 "Show advanced settings" 后的配置

  1. Resource Group：
    - 选择你OpenAI服务所在的资源组
    - 或创建新的资源组：cloud-shell-rg
  2. Storage account：
    - 自动生成名称，如 csxxxxxxxxxxxxxxxx
    - 直接使用默认即可
  3. File share：
    - 自动生成名称，如 cs-xxxxxxxxxxxxxxxx
    - 直接使用默认即可
  4. Location：
    - 选择与你OpenAI服务相同的区域
    - 或选择就近的区域

  💡 为什么选择 "Show advanced settings"？

  好处

  1. 成本控制：可以复用现有资源组
  2. 管理方便：所有资源在同一个资源组
  3. 网络优化：选择就近区域减少延迟
  4. 清晰命名：可以自定义有意义的名称

  示例配置

  Resource Group: your-existing-rg (或新建 cloud-shell-rg)
  Storage account: cloud-shell-storage (或使用默认)
  File share: cloud-shell-files (或使用默认)
  Location: East US (或与你OpenAI服务相同区域)

  ⚠️ 注意事项

  1. 首次设置：只有在第一次使用Cloud Shell时需要设置
  2. 永久保存：设置一次后，以后使用都是这个配置
  3. 免费额度：5GB免费存储，足够部署使用
  4. 清理：如果不用了，可以在Azure Portal删除对应资源

  选择 "Show advanced settings" 让你完全控制存储配置，是最佳选择！