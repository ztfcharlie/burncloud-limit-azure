import aiohttp
import asyncio
import logging
import os
from datetime import datetime, timedelta
from typing import Dict, Any, Optional

class AzureMetricsClient:
    def __init__(self, tenant_id: str, client_id: str, client_secret: str):
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.access_token = None
        self.token_expires_at = None
        self.logger = logging.getLogger(__name__)

    async def get_access_token(self) -> str:
        """获取或刷新Azure访问令牌"""
        # 检查token是否仍然有效
        if self.access_token and self.token_expires_at and datetime.now() < self.token_expires_at:
            return self.access_token

        url = f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/token"

        data = {
            'grant_type': 'client_credentials',
            'client_id': self.client_id,
            'client_secret': self.client_secret,
            'resource': 'https://management.azure.com/'
        }

        headers = {
            'Content-Type': 'application/x-www-form-urlencoded'
        }

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(url, data=data, headers=headers) as response:
                    if response.status == 200:
                        result = await response.json()
                        self.access_token = result['access_token']
                        # 设置过期时间（提前5分钟刷新）
                        self.token_expires_at = datetime.now() + timedelta(seconds=result['expires_in'] - 300)
                        self.logger.info("Successfully obtained access token")
                        return self.access_token
                    else:
                        error_text = await response.text()
                        raise Exception(f"Failed to get access token: {response.status} - {error_text}")

        except Exception as e:
            self.logger.error(f"Error getting access token: {e}")
            raise

    async def get_429_metrics(self, service_config) -> int:
        """获取指定服务的429错误计数"""
        try:
            # 构建资源ID
            subscription_id = service_config.subscription_id or self.get_default_subscription()
            resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{service_config.resource_group}/providers/Microsoft.CognitiveServices/accounts/{service_config.name}"

            # 获取访问令牌
            token = await self.get_access_token()

            # 构建Metrics API请求
            url = f"https://management.azure.com{resource_id}/providers/microsoft.insights/metrics"

            params = {
                'api-version': '2021-05-01',
                'metricnames': 'TotalRequests',
                'filter': "ResultCode eq '429'",
                'timespan': 'PT1M',  # 最近1分钟
                'aggregation': 'Count',
                'interval': 'PT1M'   # 1分钟粒度
            }

            headers = {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json'
            }

            async with aiohttp.ClientSession() as session:
                async with session.get(url, params=params, headers=headers, timeout=aiohttp.ClientTimeout(total=30)) as response:
                    if response.status == 200:
                        data = await response.json()
                        return self._extract_429_count(data)
                    elif response.status == 401:
                        # Token可能过期，强制刷新
                        self.access_token = None
                        self.token_expires_at = None
                        return await self.get_429_metrics(service_config)
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Metrics API error: {response.status} - {error_text}")
                        return 0

        except Exception as e:
            self.logger.error(f"Error getting 429 metrics for {service_config.name}: {e}")
            return 0

    def _extract_429_count(self, data: Dict[str, Any]) -> int:
        """从Metrics API响应中提取429错误计数"""
        try:
            if not data.get('value'):
                return 0

            for metric in data['value']:
                if metric.get('name', {}).get('value') == 'TotalRequests':
                    timeseries = metric.get('timeseries', [])
                    if timeseries and timeseries[0].get('data'):
                        # 获取最新的数据点
                        latest_data = timeseries[0]['data'][-1]
                        return latest_data.get('count', 0)

            return 0

        except Exception as e:
            self.logger.error(f"Error extracting 429 count from response: {e}")
            return 0

    def get_default_subscription(self) -> str:
        """获取默认订阅ID"""
        return os.getenv('AZURE_SUBSCRIPTION_ID', '')

    async def test_connection(self) -> bool:
        """测试Azure连接是否正常"""
        try:
            token = await self.get_access_token()
            return bool(token)
        except Exception as e:
            self.logger.error(f"Connection test failed: {e}")
            return False