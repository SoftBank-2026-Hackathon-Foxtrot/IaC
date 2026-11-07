variables {
  cloud     = "aws"
  region    = "ap-northeast-2"
  app       = { image = "example/app:checked", port = 8000 }
  redis_url = "redis://redis.internal:6379"
  database = {
    host                = "db.internal", port = 5432, name = "app", app_user = "app",
    app_password_secret = "app-password", admin_secret = "db-admin", admin_secret_format = "rds-json"
  }
  storage = { bucket = "app-bucket", region = "ap-northeast-2" }
}
run "isolated_app_network" {
  command = plan
  assert {
    condition     = strcontains(output.script, "--network foxtrot-app") && strcontains(output.script, "ports=(-p \"8000:8000\")")
    error_message = "App containers need isolated network counters and a reachable API port."
  }
  assert {
    condition     = strcontains(output.script, "-e OTEL_APP_ROLE=\"$role\"") && !strcontains(output.script, "/:/hostfs")
    error_message = "Keep the app role and do not collect the host filesystem."
  }
}
