import aiohttp
import asyncio
import logging
from datetime import datetime, timedelta
from typing import Dict, Any, List, Optional
from enum import Enum

class KeyStatus(Enum):
    ACTIVE = "active"
    DISABLED = "disabled"
    PENDING_REENABLE = "pending_reenable"

class APIKey:
    def __init__(self, key_id: str, key_name: str, status: KeyStatus = KeyStatus.ACTIVE):
        self.key_id = key_id
        self.key_name = key_name
        self.status = status
        self.disabled_at = None
        self.will_reenable_at = None

class AzureKeyManager:
    def __init__(self, metrics_client):
        self.metrics_client = metrics_client
        self.logger = logging.getLogger(__name__)
        self.key_status_cache = {}  # 缓存Key状态

    async def get_service_keys(self, service_config) -> List[APIKey]:
        """获取服务的所有API Key"""
        try:
            subscription_id = service_config.subscription_id or self.metrics_client.get_default_subscription()
            resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{service_config.resource_group}/providers/Microsoft.CognitiveServices/accounts/{service_config.name}"

            token = await self.metrics_client.get_access_token()

            url = f"https://management.azure.com{resource_id}/listKeys?api-version=2022-12-01"
            headers = {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json'
            }

            async with aiohttp.ClientSession() as session:
                async with session.post(url, headers=headers) as response:
                    if response.status == 200:
                        data = await response.json()
                        return self._parse_keys_response(data)
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Failed to get keys for {service_config.name}: {response.status} - {error_text}")
                        return []

        except Exception as e:
            self.logger.error(f"Error getting keys for {service_config.name}: {e}")
            return []

    def _parse_keys_response(self, data: Dict[str, Any]) -> List[APIKey]:
        """解析Azure返回的Key数据"""
        keys = []

        # 通常Azure返回的Key结构
        if 'key1' in data:
            keys.append(APIKey(data['key1'], 'key1'))
        if 'key2' in data:
            keys.append(APIKey(data['key2'], 'key2'))

        return keys

    async def handle_429_response(self, service_config, error_count: int):
        """处理429响应逻辑"""
        self.logger.warning(f"Detected {error_count} 429 errors for {service_config.name}")

        # 注意：Azure OpenAI 可能不支持直接禁用API Key
        # 这里主要是记录和告警，实际的Key管理需要根据具体API实现

        # 发送告警
        await self.send_429_alert(service_config, error_count)

        # 如果支持Key轮换，这里可以实现切换逻辑
        # 目前主要是告警通知管理员手动处理

    async def send_429_alert(self, service_config, error_count: int):
        """发送429错误告警"""
        # 这里集成告警系统
        try:
            alert_message = f"""
检测到429错误

服务: {service_config.name}
资源组: {service_config.resource_group}
429错误次数: {error_count}
检测时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

请检查服务调用频率和配置。如支持自动Key管理，系统将自动处理。
"""

            # 发送告警（这里可以集成邮件、Webhook等）
            self.logger.warning(alert_message)

            # 如果配置了邮件告警
            from ..alerts.email_alert import EmailAlert
            await EmailAlert.send_alert("429错误告警", alert_message)

            # 如果配置了Webhook告警
            from ..alerts.webhook_alert import WebhookAlert
            await WebhookAlert.send_alert({
                "event": "429_detected",
                "service": service_config.name,
                "resource_group": service_config.resource_group,
                "error_count": error_count,
                "timestamp": datetime.now().isoformat()
            })

        except Exception as e:
            self.logger.error(f"Failed to send 429 alert: {e}")