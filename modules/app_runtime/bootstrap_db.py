"""Create/rotate the app login and grant access. User apps own tables and data.

Runs once inside the image for its psycopg dependency; never imports application code.
"""

import os
import time

import psycopg
from psycopg import sql

env = os.environ
admin_args = dict(host=env["DB_HOST"], port=env["DB_PORT"], dbname=env["DB_NAME"], user=env["DB_ADMIN_USER"],
                  password=env["DB_ADMIN_PASSWORD"], sslmode="require", connect_timeout=10, autocommit=True)

deadline = time.time() + 900
while True:
    try:
        admin = psycopg.connect(**admin_args)
        break
    except psycopg.OperationalError as exc:
        if time.time() > deadline:
            raise
        print(f"database not reachable yet: {exc}".splitlines()[0], flush=True)
        time.sleep(10)

role, password = env["APP_DB_USER"], env["APP_DB_PASSWORD"]
exists = admin.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone()
verb = "ALTER" if exists else "CREATE"
admin.execute(sql.SQL(verb + " ROLE {} LOGIN PASSWORD {}").format(sql.Identifier(role), sql.Literal(password)))
admin.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(env["DB_NAME"]), sql.Identifier(role)))
admin.execute(sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(sql.Identifier(role)))
admin.close()

print("DB_ROLE_READY", flush=True)
