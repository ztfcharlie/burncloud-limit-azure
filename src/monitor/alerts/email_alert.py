import logging
import os
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from typing import List

class EmailAlert:
    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.smtp_server = os.getenv('SMTP_SERVER', 'smtp.gmail.com')
        self.smtp_port = int(os.getenv('SMTP_PORT', '587'))
        self.smtp_username = os.getenv('SMTP_USERNAME', '')
        self.smtp_password = os.getenv('SMTP_PASSWORD', '')
        self.from_email = os.getenv('FROM_EMAIL', self.smtp_username)

    @classmethod
    async def send_alert(cls, subject: str, message: str):
        """发送邮件告警"""
        self = cls()  # 创建实例
        await self._send_email(subject, message)

    async def _send_email(self, subject: str, message: str):
        """内部邮件发送方法"""
        try:
            # 获取收件人列表
            recipients_str = os.getenv('ALERT_EMAIL_RECIPIENTS', '')
            if not recipients_str:
                self.logger.warning("No email recipients configured")
                return

            recipients = [email.strip() for email in recipients_str.split(',') if email.strip()]

            if not recipients:
                self.logger.warning("No valid email recipients found")
                return

            # 创建邮件
            msg = MIMEMultipart()
            msg['From'] = self.from_email
            msg['To'] = ', '.join(recipients)
            msg['Subject'] = f"[Azure OpenAI Monitor] {subject}"

            # 添加邮件正文
            body = MIMEText(message, 'plain', 'utf-8')
            msg.attach(body)

            # 发送邮件
            server = smtplib.SMTP(self.smtp_server, self.smtp_port)
            server.starttls()
            server.login(self.smtp_username, self.smtp_password)
            server.send_message(msg)
            server.quit()

            self.logger.info(f"Alert email sent successfully to {len(recipients)} recipients")

        except Exception as e:
            self.logger.error(f"Failed to send alert email: {e}")

    def is_configured(self) -> bool:
        """检查邮件告警是否已正确配置"""
        return all([
            self.smtp_server,
            self.smtp_username,
            self.smtp_password,
            os.getenv('ALERT_EMAIL_RECIPIENTS')
        ])