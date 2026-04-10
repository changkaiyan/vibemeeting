import os
from datetime import timedelta
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent
_ARTIFACT_FLUTTER_APP_BUILD_DIR = BASE_DIR / "artifacts" / "flutter_app_web"
_APP_STATIC_FLUTTER_APP_BUILD_DIR = BASE_DIR / "app" / "static" / "flutter_app"
FLUTTER_APP_BUILD_DIR = (
    _ARTIFACT_FLUTTER_APP_BUILD_DIR
    if _ARTIFACT_FLUTTER_APP_BUILD_DIR.exists()
    else _APP_STATIC_FLUTTER_APP_BUILD_DIR
)


def _csv_env(name: str, default: str = "") -> list[str]:
    return [item.strip() for item in os.getenv(name, default).split(",") if item.strip()]


SECRET_KEY = os.getenv("SECRET_KEY", "replace-this-with-a-secure-secret")
DEBUG = os.getenv("DEBUG", "1") == "1"
ALLOWED_HOSTS = _csv_env("ALLOWED_HOSTS", "127.0.0.1,localhost,testserver,*")

INSTALLED_APPS = [
    "unfold",
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "conference",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "smart_meeting.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "app" / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    }
]

WSGI_APPLICATION = "smart_meeting.wsgi.application"
ASGI_APPLICATION = "smart_meeting.asgi.application"

DATABASE_URL = os.getenv("DATABASE_URL", "")
if DATABASE_URL.startswith("sqlite:///"):
    db_name = DATABASE_URL.replace("sqlite:///", "", 1)
    DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": BASE_DIR / db_name}}
else:
    DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": BASE_DIR / "smart_meeting.db"}}

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = "zh-hans"
TIME_ZONE = os.getenv("TIME_ZONE", "Asia/Shanghai")
USE_I18N = True
USE_TZ = False

STATIC_URL = "/static/"
STATICFILES_DIRS = []
if (
    FLUTTER_APP_BUILD_DIR.exists()
    and FLUTTER_APP_BUILD_DIR != _APP_STATIC_FLUTTER_APP_BUILD_DIR
):
    # Put generated Flutter assets ahead of app/static so /static/flutter_app/*
    # resolves to the latest build instead of the checked-in fallback bundle.
    STATICFILES_DIRS.append(("flutter_app", FLUTTER_APP_BUILD_DIR))
STATICFILES_DIRS.append(BASE_DIR / "app" / "static")
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
APPEND_SLASH = False
LOGIN_URL = "/accounts/login"
LOGIN_REDIRECT_URL = "/dashboard"
LOGOUT_REDIRECT_URL = "/"
CSRF_TRUSTED_ORIGINS = _csv_env("CSRF_TRUSTED_ORIGINS")

HTTPS_TEST = os.getenv("HTTPS_TEST", "0") == "1"
if HTTPS_TEST:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": (
        "rest_framework.permissions.IsAuthenticated",
    ),
}

access_minutes = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "480"))
SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=access_minutes),
    "AUTH_HEADER_TYPES": ("Bearer",),
}

LIVEKIT_URL = os.getenv("LIVEKIT_URL", "ws://localhost:7880")
LIVEKIT_PUBLIC_URL = os.getenv("LIVEKIT_PUBLIC_URL", "").strip()
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "secret")
LIVEKIT_MEET_URL = os.getenv("LIVEKIT_MEET_URL", "https://meet.livekit.io")
LIVEKIT_EGRESS_OUTPUT_ROOT = os.getenv("LIVEKIT_EGRESS_OUTPUT_ROOT", "").strip()
MEETING_AGENT_BRIDGE_URL = os.getenv("MEETING_AGENT_BRIDGE_URL", "").strip()
MEETING_AGENT_BRIDGE_MODE = os.getenv("MEETING_AGENT_BRIDGE_MODE", "").strip().lower() or (
    "http" if MEETING_AGENT_BRIDGE_URL else "disabled"
)
MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS = float(os.getenv("MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS", "20"))
MEETING_STT_PROVIDER = os.getenv("MEETING_STT_PROVIDER", "").strip().lower()
MEETING_REALTIME_STT_WORKER_URL = os.getenv("MEETING_REALTIME_STT_WORKER_URL", "").strip()

TECHCLOUD_OAUTH_CLIENT_ID = os.getenv("TECHCLOUD_OAUTH_CLIENT_ID", "").strip()
TECHCLOUD_OAUTH_CLIENT_SECRET = os.getenv("TECHCLOUD_OAUTH_CLIENT_SECRET", "").strip()
TECHCLOUD_OAUTH_REDIRECT_URI = os.getenv("TECHCLOUD_OAUTH_REDIRECT_URI", "").strip()
TECHCLOUD_OAUTH_AUTHORIZE_URL = os.getenv(
    "TECHCLOUD_OAUTH_AUTHORIZE_URL",
    "https://passport.escience.cn/oauth2/authorize",
).strip()
TECHCLOUD_OAUTH_TOKEN_URL = os.getenv(
    "TECHCLOUD_OAUTH_TOKEN_URL",
    "https://passport.escience.cn/oauth2/token",
).strip()
TECHCLOUD_OAUTH_SCOPE = os.getenv("TECHCLOUD_OAUTH_SCOPE", "").strip()
TECHCLOUD_OAUTH_THEME = os.getenv("TECHCLOUD_OAUTH_THEME", "full").strip() or "full"
TECHCLOUD_OAUTH_LOGOUT_URL = os.getenv(
    "TECHCLOUD_OAUTH_LOGOUT_URL",
    "https://passport.escience.cn/logout",
).strip()
TECHCLOUD_OAUTH_LOGOUT_REDIRECT_PARAM = (
    os.getenv("TECHCLOUD_OAUTH_LOGOUT_REDIRECT_PARAM", "WebServerURL").strip()
    or "WebServerURL"
)
