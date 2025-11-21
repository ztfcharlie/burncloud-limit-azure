import logging
import os
import json
import aiohttp
from typing import Dict, Any

class WebhookAlert:
    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.webhook_url = os.getenv('ALERT_WEBHOOK_URL', '')
        self.timeout = int(os.getenv('WEBHOOK_TIMEOUT', '30'))

    @classmethod
    async def send_alert(cls, alert_data: Dict[str, Any]):
        """发送Webhook告警"""
        self = cls()  # 创建实例
        await self._send_webhook(alert_data)

    async def _send_webhook(self, alert_data: Dict[str, Any]):
        """内部Webhook发送方法"""
        if not self.webhook_url:
            self.logger.warning("No webhook URL configured")
            return

        try:
            # 构建告警消息
            payload = {
                "alert_type": "azure_openai_monitor",
                "timestamp": alert_data.get("timestamp", ""),
                "event": alert_data.get("event", "unknown"),
                "service": alert_data.get("service", ""),
                "resource_group": alert_data.get("resource_group", ""),
                "details": alert_data
            }

            headers = {
                'Content-Type': 'application/json',
                'User-Agent': 'Azure-OpenAI-Monitor/1.0'
            }

            timeout = aiohttp.ClientTimeout(total=self.timeout)

            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(
                    self.webhook_url,
                    json=payload,
                    headers=headers
                ) as response:
                    if response.status == 200:
                        self.logger.info(f"Webhook alert sent successfully: {alert_data.get('event')}")
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Webhook alert failed: {response.status} - {error_text}")

        except aiohttp.ClientError as e:
            self.logger.error(f"Webhook network error: {e}")
        except Exception as e:
            self.logger.error(f"Failed to send webhook alert: {e}")

    def is_configured(self) -> bool:
        """检查Webhook告警是否已正确配置"""
        return bool(self.webhook_url)

    async def test_webhook(self) -> bool:
        """测试Webhook连接"""
        if not self.is_configured():
            return False

        test_data = {
            "event": "test",
            "service": "test-service",
            "timestamp": "2024-01-01T00:00:00Z",
            "test": True
        }

        try:
            await self._send_webhook(test_data)
            return True
        except Exception:
            return False