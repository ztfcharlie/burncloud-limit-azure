import azure.functions as func
import asyncio
import logging
import os
import json
from datetime import datetime

# 配置日志
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# 导入保护版监控服务
from monitor.core.protected_monitor_service import ProtectedAzureOpenAIMonitor
from monitor.config.settings import ConfigurationManager

app = func.FunctionApp()

@app.function_name(name="azure_openai_monitor")
@app.schedule(schedule="0 */1 * * * *",  # 每分钟触发一次
              arg_name="mytimer",
              run_on_startup=True)
async def timer_trigger(mytimer: func.TimerRequest) -> None:
    if mytimer.past_due:
        logger.info('The timer is late!')

    logger.info(f'Azure OpenAI Monitor started at: {datetime.now()}')

    try:
        # 初始化配置管理器
        config_manager = ConfigurationManager()

        # 验证配置
        config_manager.validate()

        # 初始化保护版监控服务
        monitor_service = ProtectedAzureOpenAIMonitor(config_manager)
        logger.info("🛡️ Protected monitoring service initialized - Key auto-protection enabled")

        # 测试连接（第一次运行时）
        if os.getenv('RUN_CONNECTION_TEST', 'false').lower() == 'true':
            logger.info("Running connection test...")
            connection_ok = await monitor_service.test_connection()
            if not connection_ok:
                logger.error("Connection test failed. Skipping monitoring check.")
                return

        # 运行持续监控55秒，给下次执行留5秒缓冲
        check_count = await monitor_service.run_continuous_monitoring(duration_minutes=55)

        # 记录统计信息
        stats = monitor_service.get_monitoring_stats()
        logger.info(f"Monitoring completed. Stats: {stats}")

    except Exception as e:
        logger.error(f"Critical error in timer trigger: {e}")
        # 可以在这里发送错误告警
        raise

@app.function_name(name="monitor_health_check")
@app.route(route="health", methods=["GET"])
async def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """健康检查端点"""
    try:
        config_manager = ConfigurationManager()
        monitor_service = ProtectedAzureOpenAIMonitor(config_manager)

        # 基础健康检查
        connection_ok = await monitor_service.test_connection()

        health_status = {
            "status": "healthy" if connection_ok else "unhealthy",
            "timestamp": datetime.now().isoformat(),
            "connection_test": connection_ok,
            "configured_services": len(config_manager.services)
        }

        if connection_ok:
            return func.HttpResponse(
                json.dumps(health_status),
                status_code=200,
                mimetype="application/json"
            )
        else:
            return func.HttpResponse(
                json.dumps(health_status),
                status_code=503,
                mimetype="application/json"
            )

    except Exception as e:
        error_response = {
            "status": "error",
            "timestamp": datetime.now().isoformat(),
            "error": str(e)
        }
        return func.HttpResponse(
            json.dumps(error_response),
            status_code=500,
            mimetype="application/json"
        )

@app.function_name(name="monitor_stats")
@app.route(route="stats", methods=["GET"])
async def get_stats(req: func.HttpRequest) -> func.HttpResponse:
    """获取监控统计信息端点"""
    try:
        config_manager = ConfigurationManager()
        monitor_service = ProtectedAzureOpenAIMonitor(config_manager)

        stats = monitor_service.get_monitoring_stats()

        return func.HttpResponse(
            json.dumps(stats, default=str),
            status_code=200,
            mimetype="application/json"
        )

    except Exception as e:
        error_response = {
            "error": str(e),
            "timestamp": datetime.now().isoformat()
        }
        return func.HttpResponse(
            json.dumps(error_response),
            status_code=500,
            mimetype="application/json"
        )

@app.function_name(name="protection_status")
@app.route(route="protection", methods=["GET"])
async def get_protection_status(req: func.HttpRequest) -> func.HttpResponse:
    """获取账号保护状态报告端点"""
    try:
        config_manager = ConfigurationManager()
        monitor_service = ProtectedAzureOpenAIMonitor(config_manager)

        protection_report = await monitor_service.get_protection_status_report()

        return func.HttpResponse(
            json.dumps(protection_report, default=str),
            status_code=200,
            mimetype="application/json"
        )

    except Exception as e:
        error_response = {
            "error": str(e),
            "timestamp": datetime.now().isoformat(),
            "service_type": "azure_openai_protection_monitor"
        }
        return func.HttpResponse(
            json.dumps(error_response),
            status_code=500,
            mimetype="application/json"
        )