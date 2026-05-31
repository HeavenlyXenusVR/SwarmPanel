import asyncio
import logging
import smtplib
import ssl
from email.message import EmailMessage

from .config import Settings


logger = logging.getLogger("swarm_panel.email")


def smtp_configured(settings: Settings) -> bool:
    return bool(settings.smtp_host and settings.smtp_from_email)


def _send_email_sync(settings: Settings, to_email: str, subject: str, body: str) -> bool:
    if not smtp_configured(settings):
        logger.warning("SMTP is not configured; could not send email to %s", to_email)
        return False

    if not to_email or "@" not in to_email:
        logger.warning("SMTP: refusing to send to invalid recipient address")
        return False

    message = EmailMessage()
    message["From"] = settings.smtp_from_email
    message["To"] = to_email
    message["Subject"] = subject[:998]  # RFC 5321 max subject line
    message.set_content(body)

    try:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=20) as smtp:
            if settings.smtp_use_tls:
                smtp.starttls(context=ssl.create_default_context())
            if settings.smtp_username and settings.smtp_password:
                smtp.login(settings.smtp_username, settings.smtp_password)
            smtp.send_message(message)
        return True
    except smtplib.SMTPRecipientsRefused as exc:
        logger.warning("SMTP rejected recipient %s: %s", to_email, exc)
        return False
    except smtplib.SMTPAuthenticationError as exc:
        logger.error("SMTP authentication failed: %s", exc)
        return False
    except Exception:
        logger.exception("Could not send email to %s", to_email)
        return False


async def send_email(settings: Settings, to_email: str, subject: str, body: str) -> bool:
    return await asyncio.to_thread(_send_email_sync, settings, to_email, subject, body)


async def send_verification_email(settings: Settings, to_email: str, verify_url: str, code: str) -> bool:
    return await send_email(
        settings,
        to_email,
        "Verify your SwarmPanel email",
        "Welcome to SwarmPanel.\n\n"
        f"Your verification code is:\n\n{code}\n\n"
        "Enter this code in SwarmPanel to verify your email address.\n\n"
        "You can also verify by opening the link below:\n\n"
        f"{verify_url}\n\n"
        "This verification code and link expire automatically.\n\n"
        "If you did not create this account, you can ignore this message.",
    )


async def send_image_gallery_verification_email(settings: Settings, to_email: str, verify_url: str, code: str) -> bool:
    return await send_email(
        settings,
        to_email,
        "Verify your Image Gallery email",
        "Welcome to Image Gallery.\n\n"
        f"Your verification code is:\n\n{code}\n\n"
        "Enter this code in Image Gallery to verify your email address.\n\n"
        "You can also verify by opening the link below:\n\n"
        f"{verify_url}\n\n"
        "If you did not create this account, you can ignore this message.",
    )
