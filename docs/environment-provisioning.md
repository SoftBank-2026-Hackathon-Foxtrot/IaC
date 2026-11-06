# 앱 환경 프로비저닝 — 첫 배포부터 IaC로

이 저장소는 **유저 앱 환경 하나를 처음부터 끝까지** 만듭니다. 대상은 네트워크, 데이터 저장소, 그리고 레지스트리 이미지로 실제로 실행 중인 앱입니다. 환경은 플랫폼 리소스(관리 VPC의 control-plane, 이전 서버, PgBouncer, Redis 프록시)와 **다른 VPC**에 생깁니다. 플랫폼 쪽 배포는 이 문서의 범위 밖입니다.

- 1차 목표: 치이카와 공구앱 환경 (`chiikawa-groupbuy`)
- 2차 목표: org와 클라우드 종류를 요청 본문으로 받아 그 클라우드에 맞는 환경을 만드는 API (`provisioner/`)
- 전제: 앱 Docker 이미지는 이미 각 클라우드 레지스트리(ECR, Artifact Registry)에 있습니다.

## 만들어지는 것

| 역할 | AWS (`environments/aws`) | GCP (`environments/gcp`) |
|---|---|---|
| 네트워크 | 전용 VPC `10.10.0.0/16`, public 앱 subnet, private 데이터 subnet 2개 | 전용 VPC, 앱 subnet `10.20.0.0/24`, 관리형 서비스 대역 `10.21.0.0/16` |
| 앱 | EC2. 부팅 때 ECR에서 이미지를 받아 API(uvicorn)·큐 worker·(선택) cloudflared 실행 | GCE. 부팅마다 Artifact Registry에서 받아 같은 구성 실행 |
| DB | RDS PostgreSQL 17, `rds.logical_replication=1` | Cloud SQL PostgreSQL 17, `cloudsql.logical_decoding=on` |
| Redis | ElastiCache 7.1, keyspace 알림·noeviction | Memorystore 7.0, 같은 설정 |
| 영수증 버킷 | S3 | GCS (앱은 HMAC 키로 S3 호환 API 사용) |
| 비밀값 | Secrets Manager (앱 DB 비밀번호, RDS 관리 master) | Secret Manager (앱 DB·관리자 비밀번호, HMAC secret) |

대역은 팀 트래픽 계층 설계(traffic 레포)를 따릅니다: AWS 앱 10.10, GCP 앱 10.20, Cloud SQL·Memorystore 10.21, 관리 VPC 10.30, Tailscale 100.64/10.

## 팀 레포와 맞춘 것

| 팀 레포 | 맞춘 내용 |
|---|---|
| db-migration-adaptor (`postgres-managed-logical-pgbouncer-v1`) | 양쪽 PostgreSQL 17. 원본 RDS 논리 복제, 대상 Cloud SQL 독립 인스턴스, `cloudsqlsuperuser` 관리자(`platformadmin`). 클라우드 간 복제가 필요하면 `replication_cidrs`(AWS, Cloud SQL의 나가는 IP)와 `db_authorized_networks`(GCP, DB 에이전트 주소)로 공인 경로를 엽니다. 기본은 둘 다 닫힘 |
| redis-migrator | 프록시가 TLS·백엔드 AUTH를 지원하지 않으므로 Redis TLS·AUTH는 **선택, 기본 꺼짐**. 접근은 SG·VPC로만 제한. keyspace 알림·noeviction 유지 |
| demo (치이카와 앱) | 앱 env(`DATABASE_URL`, `REDIS_URL`, `S3_*`, `SERVED_BY`), API `--workers`, worker `--reconciler`, `/seed`. `app.env`로 `CONTROL_PLANE_URL`, `WORKLOAD_ACTOR`, `OBJECT_MIGRATION_SERVER` 등을 넣으면 플랫폼 연동이 켜집니다 |
| control-plane | 시드의 `actors` 프로세스 수 = `app.api_workers` + `app.worker_count`. heartbeat 토큰은 `app.secret_env.WORKLOAD_TOKEN`으로 비밀 저장소에서 읽습니다 |
| traffic | `/readyz`를 그대로 쓰고, `app.tunnel_secret`이 있으면 cloudflared를 같은 VM에서 실행 |

## 앱 부팅 순서 (`modules/app_runtime`)

1. Docker 설치, 레지스트리 로그인(ECR: 인스턴스 역할 / AR: VM 서비스 계정 토큰), 이미지 pull
2. 비밀 저장소에서 앱 DB 비밀번호, DB 관리자 자격, (GCP) HMAC secret을 읽어 `/etc/foxtrot/*.env`(root 600)에 기록. **Terraform user data·metadata에는 비밀값이 없습니다**
3. 앱 이미지로 일회성 컨테이너를 띄워 관리자 권한으로 앱 role `app` 생성·권한 부여, 앱 role로 앱의 `init_schema` 실행. 테이블은 앱 role 소유로 두 클라우드에서 같은 schema가 됩니다
4. `app-api`, `app-worker-1..N` 컨테이너 실행 (`--restart unless-stopped`, host network, 포트 80)
5. DB가 비어 있고 `seed_demo_data=true`이면 `/seed` 한 번 호출. 이전 대상 환경은 `seed_demo_data=false`로 둡니다
6. 로그: VM의 `/var/log/foxtrot-app.log`

## 바로 띄우기 (CLI)

```bash
cp provisioner/config.example.json provisioner/config.json   # 계정·프로젝트·이미지 주소를 실제 값으로
```

```bash
AWS_PROFILE=foxtrot python -m provisioner up --org chiikawa --cloud aws
```

GCP는 ADC(`gcloud auth application-default login`)로 실행합니다.

```bash
python -m provisioner up --org chiikawa --cloud gcp
```

`--plan-only`는 계획까지만 만듭니다. `render`는 클라우드를 건드리지 않고 Terraform 입력만 출력합니다. 지우기는 `python -m provisioner down <environmentId>`입니다.

## API (`python -m provisioner serve`)

```http
POST /v1/environments
Authorization: Bearer <PROVISIONER_TOKEN>
Idempotency-Key: <키>

{"org": {"id": "chiikawa", "name": "치이카와"}, "cloud": "gcp",
 "app": {"template": "chiikawa-groupbuy", "seedDemoData": false},
 "access": {"dbAuthorizedNetworks": {"db-agent": "203.0.113.7/32"}}}
```

| 호출 | 결과 |
|---|---|
| `POST /v1/environments` | 202 `{environmentId, jobId, deploymentId}`. `mode: "plan"`이면 계획까지만 |
| `POST /v1/environments/{id}/apply` | PLANNED 환경의 저장된 계획 실행 |
| `GET /v1/environments/{id}` | 상태(`PLANNING`→`APPLYING`→`READY`, `FAILED`, `NEEDS_RECONCILIATION`, `DESTROYED`), 앱 URL, handoff |
| `DELETE /v1/environments/{id}` | 환경이 만든 자원 전부 삭제 |
| `GET /v1/jobs/{id}` | 작업 상태와 Terraform 로그 끝부분 |

요청이 정할 수 있는 것은 org, 클라우드, 앱 템플릿과 앱 env, 허용 범위 안의 사양(`catalog/sizing-policy.json`), 허용된 계정·프로젝트·리전, 이전용 접근 경로뿐입니다. 네트워크 대역, 이미지 저장소, 보안 기본값은 서버 설정(`provisioner/config.json`)에서 옵니다. 같은 org·클라우드·앱의 활성 환경은 하나만 둡니다(409 `ENVIRONMENT_EXISTS`).

- 환경마다 작업 디렉터리(`workRoot/<environmentId>`)에 코드 사본·입력·로그·state를 둡니다. `stateBackend`(S3 버킷)를 설정하면 state는 `provisioner/<environmentId>.tfstate` 키로 저장합니다.
- 작업은 한 번에 하나씩 실행합니다. 실행 중 프로세스가 멈추면 그 환경은 `NEEDS_RECONCILIATION`이 되고 자동으로 다시 실행하지 않습니다.
- API로 만든 환경은 `deletion_protection=false`, `force_destroy_storage=true`가 기본입니다(서버 설정). PoC 정리를 위해서이며 운영 환경에는 쓰지 않습니다.

## 검증

- `terraform validate`, `terraform test`(mock provider): AWS 14개, GCP 10개. 부팅 스크립트의 레지스트리 로그인, 비밀값 부재, PG17·논리 복제, Redis 기본값을 검사합니다.
- `python -m unittest discover -s tests`: 입력 규칙, 작업 수명주기, HTTP 경로.
- API가 만든 입력을 mock provider로 두 클라우드 모두 plan·apply했습니다.
- **실제 클라우드 배포는 아직 하지 않았습니다.** 실제 이미지 pull, DB 부트스트랩, 앱 기동은 첫 실배포에서 확인합니다.

## 남은 것

- DB 이전 에이전트는 "앱 writer가 table 소유권을 갖지 않는다"를 요구하지만, 현재 앱은 시작할 때 `CREATE TABLE/INDEX IF NOT EXISTS`를 실행하므로 앱 role이 테이블을 소유해야 합니다. 앱의 schema 생성을 분리할지 DB 담당과 정해야 합니다.
- 플랫폼 관리 VPC와의 사설 경로(Tailscale 서브넷 라우터, peering)는 이 환경이 만들지 않습니다. `proxy_cidrs`, `migration_source_cidrs`로 방화벽만 엽니다.
- 기존 `contracts/provisioning.openapi.yaml`(관리 중인 환경의 사양 조정 API)은 그대로 두었습니다. 새 `/v1/environments`와 합칠지는 정해야 합니다.
