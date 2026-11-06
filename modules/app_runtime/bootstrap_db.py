"""Prepare the app's database on first boot: the app role, its grants, and the app's own schema.

Runs inside the app image (psycopg is there), as the database admin. The app role creates the
tables itself through the app's init_schema, so the schema is the app's and identical on every
cloud this environment is built on. Prints EMPTY when there is no group-buy yet, so the boot
script knows whether demo data may be seeded."""

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

os.environ["DATABASE_URL"] = (f"postgresql://{role}:{password}@{env['DB_HOST']}:{env['DB_PORT']}/{env['DB_NAME']}"
                              "?sslmode=require")
from app.db import connect, init_schema  # noqa: E402  (reads DATABASE_URL on import)

db = connect()
init_schema(db)
count = db.execute("SELECT count(*) FROM groupbuys").fetchone()[0]
print("EMPTY" if count == 0 else f"HAS_DATA {count}", flush=True)
