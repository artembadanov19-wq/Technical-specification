# =====================================================================
# Oracle Database 23ai Free + тестовая схема из задания.
# Образ gvenzl/oracle-free — де-факто стандарт для локального Oracle
# (amd64 и arm64/Apple Silicon).
#
# Сборка из КОРНЯ решения (нужны папки data/ и A_SQL/):
#   docker build -f docker/Dockerfile -t oracle-test .
# Проще — через docker compose (см. docker/README.md).
# =====================================================================
FROM gvenzl/oracle-free:23-slim

# SYS/SYSTEM пароль и пользователь приложения (создаётся в FREEPDB1).
# Только для локальной проверки!
ENV ORACLE_PASSWORD=oracle \
    APP_USER=test \
    APP_USER_PASSWORD=test \
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8

USER root
# исходные данные и решения
COPY data/schema_setup.sql  /opt/solution/data/schema_setup.sql
COPY A_SQL/                 /opt/solution/A_SQL/
COPY docker/scripts/        /opt/solution/scripts/
# скрипты инициализации выполняются один раз при первом старте БД
COPY docker/init/           /container-entrypoint-initdb.d/
# убираем CRLF на случай, если файлы правились в Windows
RUN sed -i 's/\r$//' /container-entrypoint-initdb.d/*.sh /opt/solution/scripts/*.sh \
 && chmod -R a+rX /opt/solution /container-entrypoint-initdb.d \
 && chmod a+x /container-entrypoint-initdb.d/*.sh /opt/solution/scripts/*.sh
USER oracle

EXPOSE 1521
