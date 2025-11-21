import unittest
import asyncio
import os
from unittest.mock import Mock, AsyncMock, patch
from monitor.core.metrics_client import AzureMetricsClient
from monitor.config.settings import AzureServiceConfig

class TestAzureMetricsClient(unittest.TestCase):
    def setUp(self):
        self.client = AzureMetricsClient(
            tenant_id="test-tenant-id",
            client_id="test-client-id",
            client_secret="test-client-secret"
        )

        self.test_service = AzureServiceConfig(
            name="test-openai-service",
            resource_group="test-rg",
            subscription_id="test-subscription-id"
        )

    @patch('aiohttp.ClientSession.post')
    async def test_get_access_token_success(self, mock_post):
        """测试成功获取访问令牌"""
        # Mock response
        mock_response = AsyncMock()
        mock_response.status = 200
        mock_response.json.return_value = {
            'access_token': 'test-token',
            'expires_in': 3600
        }

        mock_session = AsyncMock()
        mock_session.post.return_value.__aenter__.return_value = mock_response

        with patch('aiohttp.ClientSession', return_value=mock_session):
            token = await self.client.get_access_token()

        self.assertEqual(token, 'test-token')
        self.assertEqual(self.client.access_token, 'test-token')

    @patch('aiohttp.ClientSession.get')
    async def test_get_429_metrics_success(self, mock_get):
        """测试成功获取429错误计数"""
        # 先设置access token
        self.client.access_token = "test-token"

        # Mock response
        mock_response = AsyncMock()
        mock_response.status = 200
        mock_response.json.return_value = {
            'value': [
                {
                    'name': {'value': 'TotalRequests'},
                    'timeseries': [
                        {
                            'data': [
                                {'count': 5, 'timeStamp': '2024-01-01T12:00:00Z'}
                            ]
                        }
                    ]
                }
            ]
        }

        mock_session = AsyncMock()
        mock_session.get.return_value.__aenter__.return_value = mock_response

        with patch('aiohttp.ClientSession', return_value=mock_session):
            count = await self.client.get_429_metrics(self.test_service)

        self.assertEqual(count, 5)

    def test_extract_429_count_valid_data(self):
        """测试从有效响应中提取429计数"""
        data = {
            'value': [
                {
                    'name': {'value': 'TotalRequests'},
                    'timeseries': [
                        {
                            'data': [
                                {'count': 8, 'timeStamp': '2024-01-01T12:00:00Z'},
                                {'count': 12, 'timeStamp': '2024-01-01T12:01:00Z'}
                            ]
                        }
                    ]
                }
            ]
        }

        count = self.client._extract_429_count(data)
        self.assertEqual(count, 12)  # 应该返回最新的数据点

    def test_extract_429_count_empty_data(self):
        """测试从空响应中提取429计数"""
        data = {'value': []}
        count = self.client._extract_429_count(data)
        self.assertEqual(count, 0)

    def test_extract_429_count_invalid_data(self):
        """测试从无效响应中提取429计数"""
        data = {'invalid': 'data'}
        count = self.client._extract_429_count(data)
        self.assertEqual(count, 0)

    def test_get_default_subscription(self):
        """测试获取默认订阅ID"""
        with patch.dict(os.environ, {'AZURE_SUBSCRIPTION_ID': 'test-sub-id'}):
            sub_id = self.client.get_default_subscription()
            self.assertEqual(sub_id, 'test-sub-id')

        with patch.dict(os.environ, {}, clear=True):
            sub_id = self.client.get_default_subscription()
            self.assertEqual(sub_id, '')

    @patch('monitor.core.metrics_client.AzureMetricsClient.get_access_token')
    async def test_test_connection_success(self, mock_get_token):
        """测试连接测试成功"""
        mock_get_token.return_value = 'test-token'

        result = await self.client.test_connection()
        self.assertTrue(result)

    @patch('monitor.core.metrics_client.AzureMetricsClient.get_access_token')
    async def test_test_connection_failure(self, mock_get_token):
        """测试连接测试失败"""
        mock_get_token.side_effect = Exception("Authentication failed")

        result = await self.client.test_connection()
        self.assertFalse(result)

if __name__ == '__main__':
    unittest.main()