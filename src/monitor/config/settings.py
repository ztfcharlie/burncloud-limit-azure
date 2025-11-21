import os
from typing import List, Dict, Any
from dataclasses import dataclass

@dataclass
class MonitoringConfig:
    check_interval_seconds: int = 5
    threshold_429_per_minute: int = 10
    key_disable_duration_minutes: int = 1
    max_consecutive_checks: int = 100

@dataclass
class AzureServiceConfig:
    name: str
    resource_group: str
    subscription_id: str = None
    location: str = "eastus"
    api_keys: List[str] = None
    current_key_index: int = 0

@dataclass
class AlertConfig:
    enable_email: bool = True
    email_recipients: List[str] = None
    enable_webhook: bool = False
    webhook_url: str = None
    enable_teams: bool = False
    teams_webhook_url: str = None

class ConfigurationManager:
    def __init__(self):
        self.monitoring = self._load_monitoring_config()
        self.services = self._load_service_configs()
        self.alerts = self._load_alert_config()

    def _load_monitoring_config(self) -> MonitoringConfig:
        return MonitoringConfig(
            check_interval_seconds=int(os.getenv('MONITOR_CHECK_INTERVAL', '5')),
            threshold_429_per_minute=int(os.getenv('MONITOR_429_THRESHOLD', '10')),
            key_disable_duration_minutes=int(os.getenv('MONITOR_KEY_DISABLE_DURATION', '1'))
        )

    def _load_service_configs(self) -> List[AzureServiceConfig]:
        services_json = os.getenv('MONITOR_SERVICES_JSON', '[]')
        if services_json == '[]':
            # 从环境变量加载单个服务
            return [AzureServiceConfig(
                name=os.getenv('SERVICE_NAME', ''),
                resource_group=os.getenv('SERVICE_RESOURCE_GROUP', ''),
                subscription_id=os.getenv('SERVICE_SUBSCRIPTION_ID'),
                location=os.getenv('SERVICE_LOCATION', 'eastus')
            )]

        import json
        services_data = json.loads(services_json)
        return [AzureServiceConfig(**service) for service in services_data]

    def _load_alert_config(self) -> AlertConfig:
        return AlertConfig(
            enable_email=os.getenv('ALERT_EMAIL_ENABLED', 'true').lower() == 'true',
            email_recipients=os.getenv('ALERT_EMAIL_RECIPIENTS', '').split(',') if os.getenv('ALERT_EMAIL_RECIPIENTS') else [],
            enable_webhook=os.getenv('ALERT_WEBHOOK_ENABLED', 'false').lower() == 'true',
            webhook_url=os.getenv('ALERT_WEBHOOK_URL', '')
        )

    def validate(self) -> bool:
        """验证配置是否完整"""
        if not self.services:
            raise ValueError("至少需要配置一个要监控的服务")

        for service in self.services:
            if not service.name or not service.resource_group:
                raise ValueError(f"服务 {service.name} 配置不完整")

        return True