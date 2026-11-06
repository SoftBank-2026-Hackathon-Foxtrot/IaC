# 플랫폼 배포 (AWS, 관리 VPC 하나)

`environments/platform/aws`가 플랫폼 리소스 전체를 만듭니다. state는 S3 `foxtrot-provisioner-state-<계정>`의 `platform/aws.tfstate`입니다.

## 구성

| 이름 (`*.internal`) | 포트 | 내용 |
|---|---|---|
| `control-plane` | 8000 | 플랫폼 백엔드. 시드는 `environments/platform/aws/seed.yaml` (예시 값, provisioner가 실제 앱으로 교체 예정) |
| `db-proxy` | 6432, 8080 | DB 이전 어댑터 한 태스크: PgBouncer(앱용 6432)와 API(HTTPS 8080, 내부 CA) |
| `object-migration` | 8080 | 오브젝트 이전 |
| `traffic` | 8001 | Cloudflare LB 가중치 서비스 (SQLite는 EFS) |
| `provisioner` | 8070 | 앱 환경 생성 API (Terraform 포함 이미지) |
| `console` | 80 | platform-frontend 정적 파일 + `/api` → control-plane |
| `redis-proxy`, `redis-syncworker`, `redis-migrator` | 6379·7000, 7100, 8090 | `redis_enabled=true`일 때만. 프록시는 시작할 때 원본·대상 Redis에 닿아야 함 |

- 네트워크: VPC 10.30.0.0/16, public 2개(게이트웨이), private 2개(ECS). DynamoDB·S3는 게이트웨이 엔드포인트.
- 게이트웨이 EC2: private subnet의 NAT, Tailscale 서브넷 라우터(10.30.0.0/16 광고, 앱 대역 수락), 플랫폼 cloudflared. 인바운드 포트 없음, SSM으로 관리.
- 서비스는 모두 태스크 1개, `minimumHealthyPercent=0`(단일 기록자).
- 비밀: 서비스 간 토큰은 Terraform이 생성. 외부 값은 `UNSET`으로 자리만 만들고 담당자가 채움.

## Cloudflare (Terraform 관리)

`cloudflare.tf`가 플랫폼 터널 `foxtrot-platform`, 라우팅(`platform.foxtrot.live` → `http://console.internal:80`), DNS CNAME을 만들고 터널 토큰을 Secrets Manager `foxtrot/platform/cloudflare-tunnel-platform`에 넣습니다. 게이트웨이의 `foxtrot-tunnel` 서비스가 그 토큰으로 cloudflared를 실행합니다. Terraform 실행 때 Cloudflare 토큰은 Secrets Manager `foxtrot/platform/cloudflare-iac-token`에서 읽어 `CLOUDFLARE_API_TOKEN`으로 넘깁니다(state에 남기지 않음). LB와 pool, 앱 터널(`foxtrot-traffic-aws`, `foxtrot-traffic-gcp`)은 트래픽 파트가 관리합니다.

## 담당자가 채울 비밀 (Secrets Manager `foxtrot/platform/*`)

| 비밀 | 채우면 |
|---|---|
| `tailscale-authkey-mgmt` | 게이트웨이가 `tag:mgmt`로 tailnet 가입 (1분 안에 자동) |
| `cloudflare-api-token` | 트래픽 서비스가 Cloudflare 호출. `traffic` 변수(zone/account/lb/pool ID)도 함께 설정 후 apply |
| `github-client-secret` | 콘솔 로그인. `github_client_id`, `github_allowed_ids`, `console_url` 변수와 함께 apply 후 control-plane 재시작 |
| `redis-endpoints-proxy`, `redis-endpoints-admin` | 앱 Redis 주소. 채운 뒤 `redis_enabled=true`로 apply |

앱 VM이 `*.internal`을 찾으려면 Tailscale 관리 콘솔에서 split DNS(`internal` → `10.30.0.2`)를 설정합니다.

## 올리기

```bash
AWS_PROFILE=foxtrot environments/platform/build-images.sh        # 이미지 빌드·push (태그: 커밋, latest)
cd environments/platform/aws
terraform init -backend-config="bucket=foxtrot-provisioner-state-<계정>"
TF_VAR_gcp_project_id=foxtrot-513413 terraform plan -out=platform.tfplan && terraform apply platform.tfplan
```

이미지를 바꾼 뒤에는 서비스를 다시 배포합니다: `aws ecs update-service --cluster foxtrot-platform --service <이름> --force-new-deployment`.

## 2026-11-06 배포 확인

- Terraform 관리 리소스 209개. ECS 서비스 6개 RUNNING, 상태 검사 있는 서비스는 모두 HEALTHY. Redis 3개는 꺼 둠.
- 게이트웨이에서 내부 이름으로 확인: control-plane·db-proxy(HTTPS)·traffic·provisioner·console `200`, console `/api/health` → control-plane `200`, object-migration 토큰 없이 `401`, PgBouncer 6432 열림.
- 공개 주소: `https://platform.foxtrot.live` 200, `/api/health` 200, `/api/auth/github/start` → GitHub(우리 Client ID, 콜백) 302, `/api/internal/*` 404.
- 아직 확인 못 함: 브라우저 GitHub 로그인 완료, Tailscale 경유 앱 VM 연결(키 미입력), 트래픽 서비스의 Cloudflare 호출, 실제 이전.
