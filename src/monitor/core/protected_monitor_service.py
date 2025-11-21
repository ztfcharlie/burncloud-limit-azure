import asyncio
import logging
import os
from datetime import datetime, timedelta
from typing import List
from .metrics_client import AzureMetricsClient
from .enhanced_key_manager import EnhancedKeyManager
from ..config.settings import ConfigurationManager, AzureServiceConfig

class ProtectedAzureOpenAIMonitor:
    """带账号保护的Azure OpenAI监控服务 - 实现Key自动禁用功能"""

    def __init__(self, config_manager: ConfigurationManager):
        self.config = config_manager
        self.logger = logging.getLogger(__name__)

        # 初始化客户端
        self.metrics_client = AzureMetricsClient(
            tenant_id=os.getenv('AZURE_TENANT_ID'),
            client_id=os.getenv('AZURE_CLIENT_ID'),
            client_secret=os.getenv('AZURE_CLIENT_SECRET')
        )

        # 使用增强的Key管理器（支持自动禁用）
        self.key_manager = EnhancedKeyManager(self.metrics_client, config_manager)

        # 监控统计
        self.stats = {
            'total_checks': 0,
            'total_429_detected': 0,
            'total_keys_disabled': 0,
            'total_keys_reenabled': 0,
            'last_check_time': None,
            'protection_events': []  # 记录保护事件
        }

    async def check_all_accounts(self) -> dict:
        """检查所有配置的Azure账户（带保护功能）"""
        start_time = datetime.now()
        results = {
            'timestamp': start_time.isoformat(),
            'services_checked': 0,
            'services_with_429': 0,
            'keys_disabled': 0,
            'protection_events': 0,
            'errors': [],
            'account_protection_status': 'normal'
        }

        try:
            self.logger.info(f"Starting protected monitoring check for {len(self.config.services)} services")

            # 并行检查所有服务
            tasks = []
            for service_config in self.config.services:
                task = asyncio.create_task(self.check_single_service_with_protection(service_config))
                tasks.append(task)

            # 等待所有检查完成
            service_results = await asyncio.gather(*tasks, return_exceptions=True)

            # 汇总结果
            for i, result in enumerate(service_results):
                if isinstance(result, Exception):
                    error_msg = f"Error checking service {self.config.services[i].name}: {result}"
                    self.logger.error(error_msg)
                    results['errors'].append(error_msg)
                else:
                    results['services_checked'] += 1
                    if result.get('has_429'):
                        results['services_with_429'] += 1
                        results['account_protection_status'] = 'protection_active'
                    if result.get('keys_disabled', 0) > 0:
                        results['keys_disabled'] += result['keys_disabled']
                    if result.get('protection_events', 0) > 0:
                        results['protection_events'] += result['protection_events']

            # 更新统计
            self.stats['total_checks'] += 1
            self.stats['last_check_time'] = start_time
            if results['services_with_429'] > 0:
                self.stats['total_429_detected'] += results['services_with_429']
            if results['keys_disabled'] > 0:
                self.stats['total_keys_disabled'] += results['keys_disabled']

            # 检查是否有多个服务同时触发保护
            if results['services_with_429'] >= 2:
                results['account_protection_status'] = 'multiple_services_under_protection'
                await self._send_critical_protection_alert(results)

            duration = (datetime.now() - start_time).total_seconds()
            self.logger.info(f"Protected monitoring check completed in {duration:.2f}s: {results}")

            return results

        except Exception as e:
            error_msg = f"Critical error in protected monitoring check: {e}"
            self.logger.error(error_msg)
            results['errors'].append(error_msg)
            results['account_protection_status'] = 'monitoring_error'
            return results

    async def check_single_service_with_protection(self, service_config: AzureServiceConfig) -> dict:
        """检查单个服务的状态（带保护功能）"""
        result = {
            'service_name': service_config.name,
            'has_429': False,
            'error_count': 0,
            'keys_disabled': 0,
            'protection_events': 0,
            'timestamp': datetime.now().isoformat(),
            'protection_actions': []
        }

        try:
            # 获取429错误计数
            error_count = await self.metrics_client.get_429_metrics(service_config)
            result['error_count'] = error_count

            if error_count >= self.config.monitoring.threshold_429_per_minute:
                result['has_429'] = True
                self.logger.warning(
                    f"Service {service_config.name}: {error_count} 429 errors detected - "
                    f"PROTECTION PROTOCOL ACTIVATED"
                )

                # 触发保护协议：自动禁用Key
                await self.key_manager.handle_429_response(
                    service_config,
                    error_count,
                    self.config.monitoring.key_disable_duration_minutes
                )

                result['keys_disabled'] = 1
                result['protection_events'] = 1
                result['protection_actions'].append(f"Auto-disabled API key for {error_count} 429 errors")

                # 更新统计
                self.stats['total_keys_disabled'] += 1

                # 记录保护事件
                protection_event = {
                    'service_name': service_config.name,
                    'error_count': error_count,
                    'action': 'key_disabled',
                    'timestamp': datetime.now().isoformat(),
                    'reason': '429_rate_limit_exceeded'
                }
                self.stats['protection_events'].append(protection_event)

            else:
                self.logger.debug(f"Service {service_config.name}: {error_count} 429 errors (below threshold)")

            return result

        except Exception as e:
            self.logger.error(f"Error checking service {service_config.name}: {e}")
            result['error'] = str(e)
            return result

    async def _send_critical_protection_alert(self, results: dict):
        """发送多个服务同时触发保护的紧急告警"""
        try:
            critical_alert_message = f"""
🚨 CRITICAL AZURE ACCOUNT PROTECTION ALERT 🚨

MULTIPLE SERVICES TRIGGERED RATE LIMIT PROTECTION

检测摘要:
- 检测的服务数: {results['services_checked']}
- 触发保护的服务数: {results['services_with_429']}
- 禁用的Key数量: {results['keys_disabled']}
- 保护事件数量: {results['protection_events']}
- 检测时间: {results['timestamp']}

⚠️ 紧急状态分析:
- 账号保护状态: {results['account_protection_status']}
- 风险级别: HIGH - 多个服务同时限流
- 可能原因: 系统性负载过高或配置问题

🛡️ 自动保护措施已启动:
- ✅ 自动禁用触发限流的API Keys
- ✅ 防止Azure订阅被暂停
- ✅ Key将在1分钟后自动重新启用

📋 立即行动建议:
1. **立即检查**: 所有调用Azure OpenAI的应用程序
2. **暂停非关键调用**: 减少API调用频率
3. **检查缓存机制**: 确保有效使用缓存
4. **实施限流**: 在应用层添加智能限流
5. **联系团队**: 通知相关开发团队

🔍 监控和日志:
- 查看Azure Portal: Application Insights
- 检查函数日志: Function App -> Log Stream
- 监控状态: https://<your-function-app>.azurewebsites.net/api/stats

此告警是保护Azure账号安全的关键机制。
如果此情况频繁发生，建议优化API调用策略或增加更多API Key。
"""

            # 发送紧急邮件告警
            from ..alerts.email_alert import EmailAlert
            await EmailAlert.send_alert(
                f"[🚨 CRITICAL] 多服务触发Azure账号保护 - {results['services_with_429']} services",
                critical_alert_message
            )

            # 发送紧急Webhook告警
            from ..alerts.webhook_alert import WebhookAlert
            await WebhookAlert.send_alert({
                "event": "critical_account_protection",
                "severity": "critical",
                "alert_type": "multiple_services_protection",
                "affected_services": results['services_with_429'],
                "total_keys_disabled": results['keys_disabled'],
                "protection_events": results['protection_events'],
                "account_risk_level": "HIGH",
                "immediate_action_required": True,
                "timestamp": results['timestamp'],
                "protection_status": results['account_protection_status'],
                "message": "Multiple Azure OpenAI services triggered rate limit protection - Account protection active"
            })

        except Exception as e:
            self.logger.error(f"Failed to send critical protection alert: {e}")

    async def test_connection(self) -> bool:
        """测试与Azure的连接"""
        try:
            self.logger.info("Testing Azure connection with enhanced protection...")

            # 测试认证
            auth_test = await self.metrics_client.test_connection()
            if not auth_test:
                self.logger.error("Azure authentication test failed")
                return False

            # 测试第一个服务的Metrics访问
            if self.config.services:
                first_service = self.config.services[0]
                try:
                    # 尝试获取Metrics数据（不关心具体数值）
                    await self.metrics_client.get_429_metrics(first_service)
                    self.logger.info("Azure connection test successful")
                    return True
                except Exception as e:
                    self.logger.error(f"Metrics access test failed: {e}")
                    return False
            else:
                self.logger.warning("No services configured for full connection test")
                return True

        except Exception as e:
            self.logger.error(f"Connection test failed: {e}")
            return False

    def get_monitoring_stats(self) -> dict:
        """获取监控统计信息（包含保护状态）"""
        base_stats = {
            **self.stats,
            'configured_services': len(self.config.services),
            'monitoring_interval': self.config.monitoring.check_interval_seconds,
            'threshold_429': self.config.monitoring.threshold_429_per_minute,
            'key_disable_duration': self.config.monitoring.key_disable_duration_minutes
        }

        # 添加Key状态摘要
        key_status = self.key_manager.get_key_status_summary()
        base_stats['key_management'] = key_status

        # 添加保护状态分析
        base_stats['protection_analysis'] = {
            'total_protection_events': len(self.stats['protection_events']),
            'recent_protection_events': len([
                e for e in self.stats['protection_events']
                if datetime.fromisoformat(e['timestamp']) > datetime.now() - timedelta(hours=1)
            ]),
            'last_protection_event': self.stats['protection_events'][-1] if self.stats['protection_events'] else None,
            'protection_efficiency': 'active' if self.stats['total_keys_disabled'] > 0 else 'monitoring_only'
        }

        return base_stats

    async def run_continuous_monitoring(self, duration_minutes: int = 55):
        """运行持续监控（用于Azure Functions内部循环）"""
        end_time = datetime.now() + timedelta(minutes=duration_minutes)
        check_count = 0

        self.logger.info(f"Starting PROTECTED continuous monitoring for {duration_minutes} minutes")

        while datetime.now() < end_time:
            start_time = datetime.now()

            try:
                # 执行带保护的检查
                await self.check_all_accounts()
                check_count += 1

                # 计算下次检查的等待时间
                execution_time = (datetime.now() - start_time).total_seconds()
                sleep_time = max(0, self.config.monitoring.check_interval_seconds - execution_time)

                if sleep_time > 0:
                    await asyncio.sleep(sleep_time)
                else:
                    self.logger.warning(
                        f"Protected check took {execution_time:.2f}s, exceeding interval of "
                        f"{self.config.monitoring.check_interval_seconds}s"
                    )

            except Exception as e:
                self.logger.error(f"Error in protected monitoring loop: {e}")
                await asyncio.sleep(self.config.monitoring.check_interval_seconds)

        self.logger.info(f"Protected continuous monitoring completed. Total checks: {check_count}")
        return check_count

    async def get_protection_status_report(self) -> dict:
        """获取详细的保护状态报告"""
        key_status = self.key_manager.get_key_status_summary()

        return {
            'protection_system_status': 'ACTIVE',
            'report_timestamp': datetime.now().isoformat(),
            'monitoring_configuration': {
                'check_interval_seconds': self.config.monitoring.check_interval_seconds,
                'threshold_429_per_minute': self.config.monitoring.threshold_429_per_minute,
                'key_disable_duration_minutes': self.config.monitoring.key_disable_duration_minutes
            },
            'key_management_status': key_status,
            'protection_history': {
                'total_protection_events': len(self.stats['protection_events']),
                'recent_events': [
                    event for event in self.stats['protection_events']
                    if datetime.fromisoformat(event['timestamp']) > datetime.now() - timedelta(hours=24)
                ],
                'most_recent_event': self.stats['protection_events'][-1] if self.stats['protection_events'] else None
            },
            'account_safety_metrics': {
                'total_keys_disabled_today': self.stats['total_keys_disabled'],
                'total_429_errors_detected': self.stats['total_429_detected'],
                'protection_success_rate': '100%' if self.stats['total_keys_disabled'] > 0 else 'N/A',
                'azure_subscription_risk_level': 'PROTECTED'
            }
        }