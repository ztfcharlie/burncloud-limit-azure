import asyncio
import logging
import os
from datetime import datetime, timedelta
from typing import List
from .metrics_client import AzureMetricsClient
from .key_manager import AzureKeyManager
from ..config.settings import ConfigurationManager, AzureServiceConfig

class AzureOpenAIMonitor:
    def __init__(self, config_manager: ConfigurationManager):
        self.config = config_manager
        self.logger = logging.getLogger(__name__)

        # 初始化客户端
        self.metrics_client = AzureMetricsClient(
            tenant_id=os.getenv('AZURE_TENANT_ID'),
            client_id=os.getenv('AZURE_CLIENT_ID'),
            client_secret=os.getenv('AZURE_CLIENT_SECRET')
        )

        self.key_manager = AzureKeyManager(self.metrics_client)

        # 监控统计
        self.stats = {
            'total_checks': 0,
            'total_429_detected': 0,
            'total_keys_disabled': 0,
            'last_check_time': None
        }

    async def check_all_accounts(self) -> dict:
        """检查所有配置的Azure账户"""
        start_time = datetime.now()
        results = {
            'timestamp': start_time.isoformat(),
            'services_checked': 0,
            'services_with_429': 0,
            'keys_disabled': 0,
            'errors': []
        }

        try:
            self.logger.info(f"Starting monitoring check for {len(self.config.services)} services")

            # 并行检查所有服务
            tasks = []
            for service_config in self.config.services:
                task = asyncio.create_task(self.check_single_service(service_config))
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
                    if result.get('keys_disabled', 0) > 0:
                        results['keys_disabled'] += result['keys_disabled']

            # 更新统计
            self.stats['total_checks'] += 1
            self.stats['last_check_time'] = start_time
            if results['services_with_429'] > 0:
                self.stats['total_429_detected'] += results['services_with_429']

            duration = (datetime.now() - start_time).total_seconds()
            self.logger.info(f"Monitoring check completed in {duration:.2f}s: {results}")

            return results

        except Exception as e:
            error_msg = f"Critical error in monitoring check: {e}"
            self.logger.error(error_msg)
            results['errors'].append(error_msg)
            return results

    async def check_single_service(self, service_config: AzureServiceConfig) -> dict:
        """检查单个服务的状态"""
        result = {
            'service_name': service_config.name,
            'has_429': False,
            'error_count': 0,
            'keys_disabled': 0,
            'timestamp': datetime.now().isoformat()
        }

        try:
            # 获取429错误计数
            error_count = await self.metrics_client.get_429_metrics(service_config)
            result['error_count'] = error_count

            if error_count >= self.config.monitoring.threshold_429_per_minute:
                result['has_429'] = True
                self.logger.warning(f"Service {service_config.name}: {error_count} 429 errors detected")

                # 处理429响应（禁用Key）
                await self.key_manager.handle_429_response(service_config, error_count)
                result['keys_disabled'] = 1
                self.stats['total_keys_disabled'] += 1

            else:
                self.logger.debug(f"Service {service_config.name}: {error_count} 429 errors (below threshold)")

            return result

        except Exception as e:
            self.logger.error(f"Error checking service {service_config.name}: {e}")
            result['error'] = str(e)
            return result

    async def test_connection(self) -> bool:
        """测试与Azure的连接"""
        try:
            self.logger.info("Testing Azure connection...")

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
        """获取监控统计信息"""
        return {
            **self.stats,
            'configured_services': len(self.config.services),
            'monitoring_interval': self.config.monitoring.check_interval_seconds,
            'threshold_429': self.config.monitoring.threshold_429_per_minute,
            'key_disable_duration': self.config.monitoring.key_disable_duration_minutes
        }

    async def run_continuous_monitoring(self, duration_minutes: int = 55):
        """运行持续监控（用于Azure Functions内部循环）"""
        end_time = datetime.now() + timedelta(minutes=duration_minutes)
        check_count = 0

        self.logger.info(f"Starting continuous monitoring for {duration_minutes} minutes")

        while datetime.now() < end_time:
            start_time = datetime.now()

            try:
                # 执行检查
                await self.check_all_accounts()
                check_count += 1

                # 计算下次检查的等待时间
                execution_time = (datetime.now() - start_time).total_seconds()
                sleep_time = max(0, self.config.monitoring.check_interval_seconds - execution_time)

                if sleep_time > 0:
                    await asyncio.sleep(sleep_time)
                else:
                    self.logger.warning(f"Check took {execution_time:.2f}s, exceeding interval of {self.config.monitoring.check_interval_seconds}s")

            except Exception as e:
                self.logger.error(f"Error in monitoring loop: {e}")
                await asyncio.sleep(self.config.monitoring.check_interval_seconds)

        self.logger.info(f"Continuous monitoring completed. Total checks: {check_count}")
        return check_count