output "script" {
  description = "VM 부팅 스크립트. 비밀값은 들어 있지 않고 부팅 때 비밀 저장소에서 읽습니다."
  value = templatefile("${path.module}/boot.sh.tftpl", {
    cloud               = var.cloud
    region              = var.region
    image               = var.app.image
    port                = var.app.port
    api_workers         = var.app.api_workers
    worker_count        = var.app.worker_count
    secret_env          = var.app.secret_env
    tunnel_token_secret = var.app.tunnel_secret
    cloudflared_image   = var.app.cloudflared_image
    db                  = var.database
    storage_secret      = var.storage.secret
    common_env          = local.lines.common
    api_env             = local.lines.api
    worker_env          = local.lines.worker
    bootstrap_py        = file("${path.module}/bootstrap_db.py")
    tailscale           = var.tailscale
  })
}
output "app_env_keys" {
  description = "앱에 들어가는 환경 변수 이름 (값 제외)"
  value       = sort(keys(local.common))
}
