import unittest
import asyncio
import json
from datetime import datetime, timedelta
from unittest.mock import Mock, AsyncMock, patch
from monitor.core.enhanced_key_manager import EnhancedKeyManager, APIKeyInfo, KeyStatus
from monitor.core.protected_monitor_service import ProtectedAzureOpenAIMonitor
from monitor.config.settings import ConfigurationManager, AzureServiceConfig, MonitoringConfig

class TestEnhancedKeyManager(unittest.TestCase):
    def setUp(self):
        # 创建模拟配置
        self.config = Mock()
        self.config.monitoring = MonitoringConfig(
            check_interval_seconds=5,
            threshold_429_per_minute=10,
            key_disable_duration_minutes=1
        )

        # 创建模拟的metrics客户端
        self.mock_metrics_client = Mock()

        # 初始化Key管理器
        self.key_manager = EnhancedKeyManager(self.mock_metrics_client, self.config)

        # 创建测试服务配置
        self.test_service = AzureServiceConfig(
            name="test-openai-service",
            resource_group="test-rg",
            subscription_id="test-subscription-id"
        )

        # 创建测试Key信息
        self.test_key = APIKeyInfo(
            key_id="test-key-id",
            key_name="key1",
            key_value="test-key-value"
        )

    def test_key_info_creation(self):
        """测试API Key信息创建"""
        self.assertEqual(self.test_key.key_id, "test-key-id")
        self.assertEqual(self.test_key.key_name, "key1")
        self.assertEqual(self.test_key.status, KeyStatus.ACTIVE)
        self.assertEqual(self.test_key.disable_count, 0)

    def test_generate_key_id(self):
        """测试Key ID生成"""
        key_id = self.key_manager._generate_key_id(self.test_service, "key1")
        self.assertEqual(len(key_id), 16)  # MD5 hash truncated to 16 chars
        self.assertTrue(key_id.isalnum())

    def test_can_disable_key_cooldown(self):
        """测试Key禁用冷却时间"""
        # 首次禁用应该允许
        self.assertTrue(self.key_manager._can_disable_key(self.test_key))

        # 添加到最近禁用记录
        self.key_manager.recent_disables[self.test_key.key_id] = datetime.now()

        # 冷却期内应该不允许禁用
        self.assertFalse(self.key_manager._can_disable_key(self.test_key))

        # 模拟冷却时间过去
        self.key_manager.recent_disables[self.test_key.key_id] = datetime.now() - timedelta(minutes=3)

        # 冷却时间过后应该允许禁用
        self.assertTrue(self.key_manager._can_disable_key(self.test_key))

    def test_record_key_status_change(self):
        """测试Key状态变更记录"""
        reason = "test disable"
        initial_history_length = len(self.key_manager.key_status_history)

        # 记录状态变更
        self.key_manager._record_key_status_change(self.test_key, reason)

        # 验证历史记录增加
        self.assertEqual(len(self.key_manager.key_status_history), initial_history_length + 1)

        # 验证记录内容
        latest_record = self.key_manager.key_status_history[-1]
        self.assertEqual(latest_record['key_id'], self.test_key.key_id)
        self.assertEqual(latest_record['key_name'], self.test_key.key_name)
        self.assertEqual(latest_record['reason'], reason)

    def test_parse_keys_response(self):
        """测试解析Azure Keys响应"""
        response_data = {
            "key1": "test-key-1-value",
            "key2": "test-key-2-value"
        }

        keys = self.key_manager._parse_keys_response(response_data, self.test_service)

        self.assertEqual(len(keys), 2)
        self.assertEqual(keys[0].key_name, "key1")
        self.assertEqual(keys[0].key_value, "test-key-1-value")
        self.assertEqual(keys[1].key_name, "key2")
        self.assertEqual(keys[1].key_value, "test-key-2-value")

    def test_select_key_to_disable(self):
        """测试选择禁用Key的策略"""
        # 创建多个Key
        key1 = APIKeyInfo("id1", "key1")
        key1.disable_count = 2

        key2 = APIKeyInfo("id2", "key2")
        key2.disable_count = 0

        key3 = APIKeyInfo("id3", "key3")
        key3.disable_count = 1

        active_keys = [key1, key2, key3]

        # 选择禁用次数最少的Key
        selected = self.key_manager._select_key_to_disable(active_keys)
        self.assertEqual(selected.key_name, "key2")  # 禁用次数最少

    def test_get_key_status_summary(self):
        """测试获取Key状态摘要"""
        # 添加一些状态历史记录
        self.key_manager._record_key_status_change(self.test_key, "test")

        # 模拟一个禁用的Key
        disabled_key = APIKeyInfo("disabled-id", "key2")
        disabled_key.status = KeyStatus.DISABLED
        self.key_manager._record_key_status_change(disabled_key, "disabled for test")

        summary = self.key_manager.get_key_status_summary()

        self.assertIn('total_monitored_keys', summary)
        self.assertIn('currently_disabled_keys', summary)
        self.assertIn('protection_status', summary)
        self.assertEqual(summary['disable_cooldown_minutes'], 2)

    @patch('aiohttp.ClientSession.post')
    async def test_disable_api_key_temporarily_success(self, mock_post):
        """测试成功临时禁用API Key"""
        # 模拟成功响应
        mock_response = AsyncMock()
        mock_response.status = 200
        mock_response.json.return_value = {
            "key1": "new-regenerated-key-value"
        }

        mock_post.return_value.__aenter__.return_value = mock_response

        # 模拟获取访问令牌
        self.mock_metrics_client.get_access_token = AsyncMock(return_value="test-token")

        result = await self.key_manager.disable_api_key_temporarily(
            self.test_service,
            self.test_key,
            "test disable",
            1
        )

        self.assertTrue(result)
        self.assertEqual(self.test_key.status, KeyStatus.DISABLED)
        self.assertIsNotNone(self.test_key.disabled_at)
        self.assertIsNotNone(self.test_key.will_reenable_at)

    @patch('aiohttp.ClientSession.post')
    async def test_disable_api_key_temporarily_failure(self, mock_post):
        """测试禁用API Key失败"""
        # 模拟失败响应
        mock_response = AsyncMock()
        mock_response.status = 400
        mock_response.text.return_value = "Bad request"

        mock_post.return_value.__aenter__.return_value = mock_response

        # 模拟获取访问令牌
        self.mock_metrics_client.get_access_token = AsyncMock(return_value="test-token")

        result = await self.key_manager.disable_api_key_temporarily(
            self.test_service,
            self.test_key,
            "test disable"
        )

        self.assertFalse(result)
        self.assertEqual(self.test_key.status, KeyStatus.ACTIVE)

class TestProtectedMonitorService(unittest.TestCase):
    def setUp(self):
        # 创建模拟配置管理器
        self.mock_config_manager = Mock()

        # 创建测试服务配置
        self.test_service = AzureServiceConfig(
            name="test-openai-service",
            resource_group="test-rg",
            subscription_id="test-subscription-id"
        )

        # 创建监控配置
        monitoring_config = MonitoringConfig(
            check_interval_seconds=5,
            threshold_429_per_minute=10,
            key_disable_duration_minutes=1
        )

        self.mock_config_manager.monitoring = monitoring_config
        self.mock_config_manager.services = [self.test_service]
        self.mock_config_manager.validate = Mock(return_value=True)

        # 创建监控服务
        with patch.dict('os.environ', {
            'AZURE_TENANT_ID': 'test-tenant',
            'AZURE_CLIENT_ID': 'test-client',
            'AZURE_CLIENT_SECRET': 'test-secret'
        }):
            self.monitor_service = ProtectedAzureOpenAIMonitor(self.mock_config_manager)

    def test_monitor_service_initialization(self):
        """测试监控服务初始化"""
        self.assertIsNotNone(self.monitor_service.metrics_client)
        self.assertIsNotNone(self.monitor_service.key_manager)
        self.assertEqual(len(self.monitor_service.stats), 7)  # 7个统计字段

    async def test_check_single_service_with_protection_no_429(self):
        """测试检查服务但无429错误"""
        # 模拟无429错误
        with patch.object(self.monitor_service.metrics_client, 'get_429_metrics', return_value=5):
            # 模拟没有需要禁用的Key
            with patch.object(self.monitor_service.key_manager, 'handle_429_response') as mock_handle:
                result = await self.monitor_service.check_single_service_with_protection(self.test_service)

                self.assertFalse(result['has_429'])
                self.assertEqual(result['error_count'], 5)
                self.assertEqual(result['keys_disabled'], 0)
                mock_handle.assert_not_called()

    async def test_check_single_service_with_protection_has_429(self):
        """测试检查服务且有429错误需要保护"""
        # 模拟429错误超过阈值
        with patch.object(self.monitor_service.metrics_client, 'get_429_metrics', return_value=15):
            # 模拟Key管理器处理429响应
            with patch.object(self.monitor_service.key_manager, 'handle_429_response') as mock_handle:
                result = await self.monitor_service.check_single_service_with_protection(self.test_service)

                self.assertTrue(result['has_429'])
                self.assertEqual(result['error_count'], 15)
                self.assertEqual(result['keys_disabled'], 1)
                mock_handle.assert_called_once()

    def test_get_monitoring_stats(self):
        """测试获取监控统计"""
        stats = self.monitor_service.get_monitoring_stats()

        self.assertIn('total_checks', stats)
        self.assertIn('configured_services', stats)
        self.assertIn('monitoring_interval', stats)
        self.assertIn('threshold_429', stats)
        self.assertIn('key_management', stats)
        self.assertIn('protection_analysis', stats)

    async def test_get_protection_status_report(self):
        """测试获取保护状态报告"""
        # 模拟Key管理器状态
        with patch.object(self.monitor_service.key_manager, 'get_key_status_summary', return_value={
            'total_monitored_keys': 2,
            'currently_disabled_keys': 0,
            'protection_status': 'active'
        }):
            report = await self.monitor_service.get_protection_status_report()

            self.assertEqual(report['protection_system_status'], 'ACTIVE')
            self.assertIn('monitoring_configuration', report)
            self.assertIn('key_management_status', report)
            self.assertIn('protection_history', report)
            self.assertIn('account_safety_metrics', report)

if __name__ == '__main__':
    # 运行异步测试
    def run_async_test(test_func):
        """运行异步测试的辅助函数"""
        loop = asyncio.new_event_loop()
        try:
            loop.run_until_complete(test_func())
        finally:
            loop.close()

    # 运行异步测试
    suite = unittest.TestSuite()

    # 添加异步测试
    suite.addTest(TestEnhancedKeyManager('test_disable_api_key_temporarily_success'))
    suite.addTest(TestEnhancedKeyManager('test_disable_api_key_temporarily_failure'))
    suite.addTest(TestProtectedMonitorService('test_check_single_service_with_protection_no_429'))
    suite.addTest(TestProtectedMonitorService('test_check_single_service_with_protection_has_429'))
    suite.addTest(TestProtectedMonitorService('test_get_protection_status_report'))

    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    runner.run(suite)