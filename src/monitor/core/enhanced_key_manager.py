import aiohttp
import asyncio
import logging
import json
from datetime import datetime, timedelta
from typing import Dict, Any, List, Optional, Tuple
from enum import Enum
import hashlib

class KeyStatus(Enum):
    ACTIVE = "active"
    DISABLED = "disabled"
    PENDING_REENABLE = "pending_reenable"
    PERMANENTLY_DISABLED = "permanently_disabled"

class APIKeyInfo:
    def __init__(self, key_id: str, key_name: str, key_value: str = None):
        self.key_id = key_id  # Key的唯一标识符
        self.key_name = key_name  # Key的名称 (key1, key2, etc.)
        self.key_value = key_value  # Key的实际值（敏感信息）
        self.status = KeyStatus.ACTIVE
        self.disabled_at = None
        self.will_reenable_at = None
        self.disable_count = 0  # 累计禁用次数
        self.last_disable_reason = None
        self.usage_metrics = {
            'total_requests': 0,
            'error_429_count': 0,
            'last_used': None
        }

class EnhancedKeyManager:
    """增强的API Key管理器 - 支持临时禁用和自动恢复"""

    def __init__(self, metrics_client, config):
        self.metrics_client = metrics_client
        self.config = config
        self.logger = logging.getLogger(__name__)

        # Key状态缓存
        self.key_cache = {}
        self.key_status_history = []  # 记录Key状态变更历史

        # 防止频繁禁用的保护机制
        self.recent_disables = {}  # 记录最近的禁用时间
        self.disable_cooldown_minutes = 2  # 同一个Key在2分钟内只能被禁用一次

    async def get_service_keys(self, service_config) -> List[APIKeyInfo]:
        """获取服务的所有API Key信息"""
        cache_key = f"{service_config.subscription_id}:{service_config.resource_group}:{service_config.name}"

        # 检查缓存
        if cache_key in self.key_cache:
            cached_time = self.key_cache[cache_key].get('timestamp')
            if cached_time and (datetime.now() - cached_time).total_seconds() < 300:  # 5分钟缓存
                return self.key_cache[cache_key]['keys']

        try:
            subscription_id = service_config.subscription_id or self.metrics_client.get_default_subscription()
            resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{service_config.resource_group}/providers/Microsoft.CognitiveServices/accounts/{service_config.name}"

            token = await self.metrics_client.get_access_token()

            # 获取现有Keys
            list_url = f"https://management.azure.com{resource_id}/listKeys?api-version=2023-05-01"
            headers = {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json'
            }

            async with aiohttp.ClientSession() as session:
                async with session.post(list_url, headers=headers) as response:
                    if response.status == 200:
                        data = await response.json()
                        keys = self._parse_keys_response(data, service_config)

                        # 缓存结果
                        self.key_cache[cache_key] = {
                            'keys': keys,
                            'timestamp': datetime.now()
                        }

                        return keys
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Failed to get keys for {service_config.name}: {response.status} - {error_text}")
                        return []

        except Exception as e:
            self.logger.error(f"Error getting keys for {service_config.name}: {e}")
            return []

    def _parse_keys_response(self, data: Dict[str, Any], service_config) -> List[APIKeyInfo]:
        """解析Azure返回的Key数据"""
        keys = []

        # Azure OpenAI通常返回key1, key2
        for key_name in ['key1', 'key2']:
            if key_name in data and data[key_name]:
                # 生成唯一的Key ID（基于服务配置和key名称）
                key_id = self._generate_key_id(service_config, key_name)

                key_info = APIKeyInfo(
                    key_id=key_id,
                    key_name=key_name,
                    key_value=data[key_name]
                )

                # 从缓存中恢复状态（如果存在）
                if key_id in self.key_status_history:
                    cached_status = next((h for h in self.key_status_history if h['key_id'] == key_id), None)
                    if cached_status:
                        key_info.status = cached_status.get('status', KeyStatus.ACTIVE)
                        key_info.disabled_at = cached_status.get('disabled_at')
                        key_info.will_reenable_at = cached_status.get('will_reenable_at')
                        key_info.disable_count = cached_status.get('disable_count', 0)

                keys.append(key_info)

        return keys

    def _generate_key_id(self, service_config, key_name: str) -> str:
        """生成Key的唯一标识符"""
        key_data = f"{service_config.subscription_id}:{service_config.resource_group}:{service_config.name}:{key_name}"
        return hashlib.md5(key_data.encode()).hexdigest()[:16]

    async def disable_api_key_temporarily(self, service_config, key_info: APIKeyInfo, reason: str = "429 rate limit exceeded", duration_minutes: int = None) -> bool:
        """临时禁用API Key"""
        try:
            # 检查冷却时间
            if not self._can_disable_key(key_info):
                self.logger.warning(f"Key {key_info.key_name} is in cooldown period, skipping disable")
                return False

            duration = duration_minutes or self.config.monitoring.key_disable_duration_minutes

            subscription_id = service_config.subscription_id or self.metrics_client.get_default_subscription()
            resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{service_config.resource_group}/providers/Microsoft.CognitiveServices/accounts/{service_config.name}"

            token = await self.metrics_client.get_access_token()

            # 注意：Azure OpenAI可能不支持直接禁用Key
            # 我们使用重新生成Key的方式（这会使旧的Key失效）
            regenerate_url = f"https://management.azure.com{resource_id}/regenerateKey?api-version=2023-05-01"

            payload = {
                "keyName": key_info.key_name
            }

            headers = {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json'
            }

            async with aiohttp.ClientSession() as session:
                async with session.post(regenerate_url, json=payload, headers=headers) as response:
                    if response.status == 200:
                        data = await response.json()

                        # 更新Key信息
                        old_key_value = key_info.key_value
                        key_info.key_value = data.get(key_info.key_name)
                        key_info.status = KeyStatus.DISABLED
                        key_info.disabled_at = datetime.now()
                        key_info.will_reenable_at = datetime.now() + timedelta(minutes=duration)
                        key_info.disable_count += 1
                        key_info.last_disable_reason = reason

                        # 记录状态变更历史
                        self._record_key_status_change(key_info, reason)

                        # 更新最近禁用记录
                        self.recent_disables[key_info.key_id] = datetime.now()

                        self.logger.warning(
                            f"Key {key_info.key_name} disabled for service {service_config.name} "
                            f"due to: {reason}. Will reenable at {key_info.will_reenable_at}"
                        )

                        # 安排重新启用任务
                        asyncio.create_task(self.schedule_reenable_key(service_config, key_info))

                        # 发送Key禁用告警
                        await self._send_key_disable_alert(service_config, key_info, reason, old_key_value)

                        return True
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Failed to disable key {key_info.key_name}: {response.status} - {error_text}")
                        return False

        except Exception as e:
            self.logger.error(f"Error disabling key {key_info.key_name}: {e}")
            return False

    def _can_disable_key(self, key_info: APIKeyInfo) -> bool:
        """检查是否可以禁用Key（冷却时间保护）"""
        if key_info.key_id not in self.recent_disables:
            return True

        last_disable_time = self.recent_disables[key_info.key_id]
        cooldown_end = last_disable_time + timedelta(minutes=self.disable_cooldown_minutes)

        return datetime.now() >= cooldown_end

    def _record_key_status_change(self, key_info: APIKeyInfo, reason: str):
        """记录Key状态变更历史"""
        history_entry = {
            'key_id': key_info.key_id,
            'key_name': key_info.key_name,
            'status': key_info.status,
            'disabled_at': key_info.disabled_at,
            'will_reenable_at': key_info.will_reenable_at,
            'disable_count': key_info.disable_count,
            'reason': reason,
            'timestamp': datetime.now()
        }

        # 移除旧的该Key历史记录（保留最新10条）
        self.key_status_history = [h for h in self.key_status_history if h['key_id'] != key_info.key_id][-9:]
        self.key_status_history.append(history_entry)

    async def schedule_reenable_key(self, service_config, key_info: APIKeyInfo):
        """安排重新启用Key"""
        wait_seconds = int((key_info.will_reenable_at - datetime.now()).total_seconds())

        if wait_seconds > 0:
            self.logger.info(f"Scheduling reenable of key {key_info.key_name} in {wait_seconds} seconds")
            await asyncio.sleep(wait_seconds)

        await self.reenable_api_key(service_config, key_info)

    async def reenable_api_key(self, service_config, key_info: APIKeyInfo) -> bool:
        """重新启用API Key"""
        try:
            subscription_id = service_config.subscription_id or self.metrics_client.get_default_subscription()
            resource_id = f"/subscriptions/{subscription_id}/resourceGroups/{service_config.resource_group}/providers/Microsoft.CognitiveServices/accounts/{service_config.name}"

            token = await self.metrics_client.get_access_token()

            # 重新生成Key来启用它
            regenerate_url = f"https://management.azure.com{resource_id}/regenerateKey?api-version=2023-05-01"

            payload = {
                "keyName": key_info.key_name
            }

            headers = {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json'
            }

            async with aiohttp.ClientSession() as session:
                async with session.post(regenerate_url, json=payload, headers=headers) as response:
                    if response.status == 200:
                        data = await response.json()

                        # 更新Key信息
                        key_info.key_value = data.get(key_info.key_name)
                        key_info.status = KeyStatus.ACTIVE
                        key_info.disabled_at = None
                        key_info.will_reenable_at = None

                        # 记录状态变更
                        self._record_key_status_change(key_info, "automatic_reenable")

                        self.logger.info(f"Key {key_info.key_name} reenabled for service {service_config.name}")

                        # 发送Key重新启用通知
                        await self._send_key_reenable_alert(service_config, key_info)

                        return True
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Failed to reenable key {key_info.key_name}: {response.status} - {error_text}")
                        return False

        except Exception as e:
            self.logger.error(f"Error reenabling key {key_info.key_name}: {e}")
            return False

    async def handle_429_response(self, service_config, error_count: int, duration_minutes: int = None):
        """处理429响应 - 实现Key临时禁用"""
        self.logger.warning(f"Handling 429 response for {service_config.name}: {error_count} errors detected")

        # 获取当前服务的所有Keys
        all_keys = await self.get_service_keys(service_config)

        if not all_keys:
            self.logger.error(f"No keys found for service {service_config.name}")
            return

        # 找到当前活跃的Keys
        active_keys = [k for k in all_keys if k.status == KeyStatus.ACTIVE]

        if not active_keys:
            self.logger.warning(f"No active keys found for {service_config.name}. All keys may be disabled.")
            return

        # 选择一个Key进行禁用（选择最近最少使用的Key）
        key_to_disable = self._select_key_to_disable(active_keys)

        if key_to_disable:
            reason = f"429 rate limit exceeded: {error_count} errors in 1 minute"
            success = await self.disable_api_key_temporarily(
                service_config,
                key_to_disable,
                reason,
                duration_minutes or self.config.monitoring.key_disable_duration_minutes
            )

            if success:
                self.logger.info(f"Successfully disabled key {key_to_disable.key_name} for {service_config.name}")
            else:
                self.logger.error(f"Failed to disable key {key_to_disable.key_name} for {service_config.name}")

    def _select_key_to_disable(self, active_keys: List[APIKeyInfo]) -> Optional[APIKeyInfo]:
        """选择要禁用的Key策略"""
        if not active_keys:
            return None

        # 策略1：选择禁用次数最少的Key
        key_with_min_disables = min(active_keys, key=lambda k: k.disable_count)

        # 策略2：如果有多个Key禁用次数相同，选择最近使用时间最早的
        keys_with_same_disables = [k for k in active_keys if k.disable_count == key_with_min_disables.disable_count]

        if len(keys_with_same_disables) == 1:
            return key_with_min_disables

        # 选择最近使用时间最早的Key
        key_with_oldest_use = min(keys_with_same_disables,
                                key=lambda k: k.usage_metrics.get('last_used', datetime.min))

        return key_with_oldest_use

    async def _send_key_disable_alert(self, service_config, key_info: APIKeyInfo, reason: str, old_key_value: str = None):
        """发送Key禁用告警"""
        try:
            alert_message = f"""
🚨 API Key 自动禁用告警 🚨

服务信息:
- 服务名称: {service_config.name}
- 资源组: {service_config.resource_group}
- 订阅ID: {service_config.subscription_id}

Key信息:
- Key名称: {key_info.key_name}
- Key ID: {key_info.key_id}
- 禁用时间: {key_info.disabled_at.strftime('%Y-%m-%d %H:%M:%S')}
- 预计重新启用: {key_info.will_reenable_at.strftime('%Y-%m-%d %H:%M:%S')}
- 累计禁用次数: {key_info.disable_count}

禁用原因: {reason}

⚠️ 重要提醒:
1. 这是保护Azure账号安全的自动响应机制
2. 1分钟后Key将自动重新启用
3. 请检查API调用频率和实现适当的限流机制
4. 如果频繁触发，建议增加更多API Key或优化调用策略

状态监控: https://<your-function-app>.azurewebsites.net/api/stats
"""

            # 发送邮件告警
            from ..alerts.email_alert import EmailAlert
            await EmailAlert.send_alert(f"[🚨 关键] API Key自动禁用 - {service_config.name}", alert_message)

            # 发送Webhook告警
            from ..alerts.webhook_alert import WebhookAlert
            await WebhookAlert.send_alert({
                "event": "key_auto_disabled",
                "severity": "critical",
                "service_name": service_config.name,
                "resource_group": service_config.resource_group,
                "key_name": key_info.key_name,
                "disable_reason": reason,
                "disabled_at": key_info.disabled_at.isoformat(),
                "will_reenable_at": key_info.will_reenable_at.isoformat(),
                "disable_count": key_info.disable_count,
                "protection_action": "Account protection - Preventing Azure subscription suspension"
            })

        except Exception as e:
            self.logger.error(f"Failed to send key disable alert: {e}")

    async def _send_key_reenable_alert(self, service_config, key_info: APIKeyInfo):
        """发送Key重新启用通知"""
        try:
            reenable_message = f"""
✅ API Key 自动重新启用通知

服务信息:
- 服务名称: {service_config.name}
- 资源组: {service_config.resource_group}

Key信息:
- Key名称: {key_info.key_name}
- 重新启用时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
- 累计禁用次数: {key_info.disable_count}

状态: API Key已恢复正常使用
建议: 请监控API调用频率，避免再次触发限流保护
"""

            from ..alerts.email_alert import EmailAlert
            await EmailAlert.send_alert(f"[✅ 恢复] API Key重新启用 - {service_config.name}", reenable_message)

            from ..alerts.webhook_alert import WebhookAlert
            await WebhookAlert.send_alert({
                "event": "key_auto_reenabled",
                "severity": "info",
                "service_name": service_config.name,
                "resource_group": service_config.resource_group,
                "key_name": key_info.key_name,
                "reenabled_at": datetime.now().isoformat(),
                "disable_count": key_info.disable_count,
                "status": "service_restored"
            })

        except Exception as e:
            self.logger.error(f"Failed to send key reenable alert: {e}")

    def get_key_status_summary(self) -> Dict[str, Any]:
        """获取Key状态摘要"""
        total_keys = len(self.key_status_history)
        disabled_keys = len([k for k in self.key_status_history if k.get('status') == KeyStatus.DISABLED])
        recently_disabled = len([k for k in self.key_status_history
                               if k.get('disabled_at') and
                               (datetime.now() - k['disabled_at']).total_seconds() < 3600])  # 1小时内

        return {
            'total_monitored_keys': total_keys,
            'currently_disabled_keys': disabled_keys,
            'recently_disabled_keys': recently_disabled,
            'key_disable_cooldown_minutes': self.disable_cooldown_minutes,
            'protection_status': 'active' if disabled_keys == 0 else 'keys_disabled_for_protection'
        }