# 앱 환경 프로비저닝 — 첫 배포부터 IaC로

이 저장소는 **유저 앱 환경 하나를 처음부터 끝까지** 만듭니다. 대상은 네트워크, 데이터 저장소, 그리고 레지스트리 이미지로 실제로 실행 중인 앱입니다. 환경은 플랫폼 리소스(관리 VPC의 control-plane, 이전 서버, PgBouncer, Redis 프록시)와 **다른 VPC**에 생깁니다. 플랫폼 쪽 배포는 이 문서의 범위 밖입니다.

[main 통합: 호환성·앱 준비 확인·공유 라우터 연결](release-integration.md)을 먼저 확인하세요.

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

## 미리 올려 둔 리소스 (`environments/foundation/*`)

클라우드마다 한 번만 만드는 유저 앱 공용 자원입니다. VPC부터 앱까지 나머지는 환경을 만들 때 생깁니다.

| 리소스 | AWS (`foundation/aws`) | GCP (`foundation/gcp`) |
|---|---|---|
| 이미지 저장소 | ECR `chiikawa-groupbuy` (최근 10개 유지, push 시 스캔) | Artifact Registry `apps` (asia-northeast3, 최근 10개 유지) |
| 앱 이미지 | `chiikawa-groupbuy:20cf750`, `latest` (demo `20cf750`, linux/amd64) | 같음 |
| provisioner state | S3 `foxtrot-provisioner-state-<계정>` (버전 관리, 암호화, 공개 차단) | (AWS 버킷 공용) |
| Tailscale 인증 키 자리 | Secrets Manager `foxtrot/tailscale-authkey-aws` (값은 트래픽 파트가 입력) | Secret Manager `foxtrot-tailscale-authkey-gcp` |
| Cloudflare 터널 토큰 | 아직 없음 | traffic 팀의 `foxtrot-traffic-gcp-tunnel-token` 사용 |

foundation의 Terraform state는 실행한 위치의 로컬 파일입니다. 잃어버려도 `terraform import`로 되살릴 수 있는 자원만 둡니다.

## 앱 부팅 순서 (`modules/app_runtime`)

1. Docker 설치, 레지스트리 로그인(ECR: 인스턴스 역할 / AR: VM 서비스 계정 토큰), 이미지 pull
2. 비밀 저장소에서 앱 DB 비밀번호, DB 관리자 자격, (GCP) HMAC secret을 읽어 `/etc/foxtrot/*.env`(root 600)에 기록. **Terraform user data·metadata에는 비밀값이 없습니다**
3. 앱 이미지로 일회성 컨테이너를 띄워 관리자 권한으로 앱 role `app` 생성·권한 부여까지만 수행. 스키마·테이블·데이터는 사용자 앱이 시작할 때 준비합니다
4. `app-api`, `app-worker-1..N` 컨테이너 실행 (`--restart unless-stopped`, host network, 포트 80)
5. IaC는 `/seed`를 호출하지 않습니다. 별도 CHECK_APP 작업이 사설 `/readyz` 응답을 확인합니다
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
| `GET /v1/environments/{id}` | 상태(`PLANNING`→`APPLYING`→`INFRA_READY`→`VERIFYING_APP`→`READY`/`APP_NOT_READY`, `FAILED`, `NEEDS_RECONCILIATION`, `DESTROYED`), 앱 URL, handoff |
| `POST /v1/environments/{id}/check-app` | Terraform 재실행 없이 앱 준비 확인 |
| `DELETE /v1/environments/{id}` | 환경이 만든 자원 전부 삭제 |
| `GET /v1/jobs/{id}` | 작업 상태와 Terraform 로그 끝부분 |

요청이 정할 수 있는 것은 org, 클라우드, 앱 템플릿과 앱 env, 허용 범위 안의 사양(`catalog/sizing-policy.json`), 허용된 계정·프로젝트·리전, 이전용 접근 경로뿐입니다. 네트워크 대역, 이미지 저장소, 보안 기본값은 서버 설정(`provisioner/config.json`)에서 옵니다. 같은 org·클라우드·앱의 활성 환경은 하나만 둡니다(409 `ENVIRONMENT_EXISTS`).

- 환경마다 작업 디렉터리(`workRoot/<environmentId>`)에 코드 사본·입력·로그·state를 둡니다. `stateBackend`(S3 버킷)를 설정하면 state는 `provisioner/<environmentId>.tfstate` 키로 저장합니다.
- 작업은 한 번에 하나씩 실행합니다. 실행 중 프로세스가 멈추면 그 환경은 `NEEDS_RECONCILIATION`이 되고 자동으로 다시 실행하지 않습니다.
- API로 만든 환경은 `deletion_protection=false`, `force_destroy_storage=true`가 기본입니다(서버 설정). PoC 정리를 위해서이며 운영 환경에는 쓰지 않습니다.

### 컨트롤 플레인 보고 (서버 설정 `workload`)

서버 설정에 `workload`가 있으면 앱의 모든 프로세스가 컨트롤 플레인에 주기적으로 보고하고, RUN/HOLD 지시와 객체 이전 경로를 따르도록 env를 넣습니다. 앱 쪽 동작은 데모 앱 `app/workload.py`를 따릅니다. 요청에 같은 이름의 값이 있으면 요청 값이 우선합니다.

```json
{"workload": {"controlPlaneUrl": "http://control-plane.internal:8000",
              "tokenSecrets": {"aws": "<Secrets Manager ARN>", "gcp": "projects/<p>/secrets/<name>"}}}
```

| env | 값 | 넣는 곳 |
|---|---|---|
| `CONTROL_PLANE_URL` | `controlPlaneUrl` | 모든 프로세스 |
| `WORKLOAD_SCOPE` | `scope:<org>` | 모든 프로세스 |
| `OBJECT_MIGRATION_ID_FILE` | `/tmp/object-migration-id` (보고 스레드가 받은 객체 이전 ID를 쓰고 objroute가 읽음) | 모든 프로세스 |
| `WORKLOAD_ACTOR` | API `<org>-<cloud>-api`, 워커 `<org>-<cloud>-worker` | 프로세스별 |
| `WORKLOAD_TOKEN` | 클라우드별 시크릿 (`tokenSecrets.<cloud>`) | 부팅 때 비밀 저장소에서 읽음 |

컨트롤 플레인 시드의 `scope`와 `environments.*.actors`는 이 이름과 같아야 합니다(예: org `chiikawa` → `chiikawa-aws-api`). 플랫폼 root는 AWS 토큰(`foxtrot/platform/workload-token`)과 같은 값을 GCP Secret Manager `foxtrot-platform-workload-token`에도 두고 이 설정을 연결합니다.

## 검증

- `terraform validate`, `terraform test`(mock provider): AWS 14개, GCP 10개. 부팅 스크립트의 레지스트리 로그인, 비밀값 부재, PG17·논리 복제, Redis 기본값을 검사합니다.
- `python -m unittest discover -s tests`: 입력 규칙, 작업 수명주기, HTTP 경로.
- API가 만든 입력을 mock provider로 두 클라우드 모두 plan·apply했습니다.
- **2026-11-06 첫 실배포 (AWS, 플랫폼의 provisioner 서비스로):** `POST /v1/environments` `{org: chiikawa, cloud: aws}` → 리소스 44개, 약 11분. 앱 VM이 ECR 이미지를 받아 DB 계정·schema를 만들고 API·worker를 띄우고 데모 데이터를 넣음 (`http://<고정 IP>/` 200, `X-Served-By: aws`).
- **터널 연결 (A안):** `POST /v1/environments/{id}/update` `{app: {port: 8000, tunnelSecret: <foxtrot/app/cloudflare-tunnel-aws>}}`로 트래픽 팀의 `foxtrot-traffic-aws` 터널을 새 앱 VM이 넘겨받음. 터널 토큰이 있으면 provisioner가 7844 송신을 엶. 테스트 EC2 `foxtrot-traffic-test-a`는 중지(삭제 아님). `https://aws.foxtrot.live`, `https://app.foxtrot.live` 모두 치이카와 앱 응답.
- **채팅 WebSocket (2026-11-07):** 앱은 WebSocket의 Origin과 Host가 같아야 받는데, LB pool이 Host를 `aws.foxtrot.live`로 바꿔 보내서 `app.foxtrot.live`에서 403이었음. aws·gcp 터널에 `app.foxtrot.live → 127.0.0.1:8000` 경로를 추가하고, 두 pool의 엔드포인트 Host 헤더를 `app.foxtrot.live`로 바꿈(앱은 수정하지 않음). 이후 화면·API·DB/Redis·채팅(`history`, `ready`) 점검 모두 통과. 모니터는 `aws.`/`gcp.` 경로로 그대로 동작.

## 앱·DB 어댑터와의 계약

- 테이블 생성은 사용자 앱 책임입니다. DB 이전 에이전트는 "앱 writer가 table 소유권을 갖지 않는다"를 요구하지만, 현재 앱은 시작할 때 `CREATE TABLE/INDEX IF NOT EXISTS`를 실행하므로 앱 role이 테이블을 소유해야 합니다. 마이그레이션에 필요한 owner/writer 분리는 앱과 DB 어댑터에서 결정합니다.
- 사설 경로는 별도 공유 Tailscale 라우터 root가 관리합니다. 앱 환경의 `router_inputs`를 연결합니다.
- 기존 `contracts/provisioning.openapi.yaml`(관리 중인 환경의 사양 조정 API)은 그대로 두었습니다. 새 `/v1/environments`와 합칠지는 정해야 합니다.


## 온프렘 앱 배포

`cloud: onprem`은 등록된 Docker 노드에 API와 worker 컨테이너만 배포한다.
AWS/GCP 요청은 기존 EC2/GCE Terraform 경로를 유지한다. 이 변경은 Fargate/Cloud Run 전환을 포함하지 않는다.

1. 기존 provisioner 설정의 `clouds.onprem`에 [등록 예시](../provisioner/onprem-app.example.json)를 넣고 주소·소유 조직·이미지 허용 목록을 실제 값으로 바꾼다.
2. 노드에 Docker Compose v2와 Python 3가 있어야 한다. SSH 키 파일은 provisioner에서 읽을 수 있는 0600 파일로 두고, 검증한 SSH 호스트 키를 `sshHostKey`에 등록한다. SSH 계정에는 해당 Docker 실행 권한이 필요하다.
3. `network`는 노드에 이미 존재하는 데이터 서비스용 Docker 네트워크다. `bindAddress`는 노드의 사설 주소이며, provisioner에서 접근할 수 있어야 한다. 앱 컨테이너도 Collector와 설정한 프록시에 접근할 수 있어야 한다.
4. 앱 비밀번호·토큰은 등록의 `secretEnv`(provisioner 환경 변수 이름) 또는 `secretFiles`(0600 파일 경로)로 전달한다. 일반 앱 요청에 SSH 정보나 비밀값을 넣지 않는다.

```bash
python -m provisioner up --org chiikawa --cloud onprem \
  --node-id home-pc \
  --image ghcr.io/softbank-2026-hackathon-foxtrot/chiikawa-groupbuy:RELEASE_TAG
```

HTTP에서는 내부 provisioner의 `POST /v1/environments`에 아래 본문을 보낸다.
기존 `Authorization: Bearer <PROVISIONER_TOKEN>`과 재시도용 `Idempotency-Key`를 사용한다.

```json
{
  "org": {"id": "chiikawa"},
  "cloud": "onprem",
  "target": {"nodeId": "home-pc"},
  "app": {
    "image": "ghcr.io/softbank-2026-hackathon-foxtrot/chiikawa-groupbuy:RELEASE_TAG",
    "apiWorkers": 2,
    "workerCount": 2,
    "cpu": 1,
    "memoryMiB": 512
  },
  "mode": "plan"
}
```

`mode: plan`은 사전 점검 후 대기한다. `POST /v1/environments/{id}/apply`로 저장된 plan을 실행한다.
앱 교체는 기존 배포 삭제 후 새 배포로 수행한다. 실행 중 연결이 끊기면 `NEEDS_RECONCILIATION`으로 남으며,
`POST /v1/environments/{id}/reconcile`로 원격 상태를 확인한다. 확인 전에는 노드를 다른 배포에 재사용하지 않는다.
`DELETE /v1/environments/{id}`는 해당 앱 컨테이너만 제거하며 데이터 서비스와 외부 Docker 네트워크를 유지한다.

### IaC에서 데이터 서비스도 준비하는 경우

기존 `onprem.catalogFile`과 `onprem.secretRoot`를 설정하고, 노드 등록에 해당 카탈로그의
`preparation: {target: {...}, profileRef: "..."}`를 지정한다. 먼저 v2 API로 준비를 완료하고,
앱 요청의 `target.preparationId` 또는 CLI의 `--preparation-id`에 준비 환경 ID를 전달한다.
소유 조직·등록 대상·준비 상태가 일치해야 배포된다. 앱이 남아 있는 동안 준비 환경의 변경·정리는 거부된다.

비밀 번들을 쓰는 경우 `<workRoot>/onprem-registration/bundle.json`을 0600으로 배치한다.
형식은 `schemaVersion: 1`, `nodeId`, `node`, `catalog`, `credentials`와 선택 항목 `images`다.
`credentials`의 키는 파일 이름이고 값은 해당 비밀값이다. 번들은 운영자가 관리하며 Git에 커밋하지 않는다.
IaC의 ECS provisioner는 기존 EFS의 `/var/lib/foxtrot-provisioner`를 사용하므로 이 경로 아래에 등록한다.
다른 서비스에 저장한 등록 정보가 이 provisioner로 자동 복사되지는 않는다.

### 앱 시스템 메트릭

`appTelemetry.applicationId`, `appTelemetry.endpoint`, `appTelemetry.headersEnv`로 수집 대상을 설정한다.
`headersEnv`의 기본값은 `OTEL_EXPORTER_OTLP_HEADERS`이며, ECS provisioner는 기존 Collector 설정을 사용한다.
앱에는 `application.id`, 소유 조직 ID, 배포 ID, `deployment.environment.name=onprem`, API/worker 역할이 주입된다.
CPU·메모리·디스크 I/O·네트워크는 사용자 앱 컨테이너 범위다. 호스트 전체 메트릭용 컨테이너나 host mount는 만들지 않는다.
`expectedServedBy`는 HTTP 앱 식별에만 쓰이며 메트릭 환경 이름을 바꾸지 않는다.

반영하려면 새 provisioner 이미지를 배포하고, 시스템 메트릭 기능이 포함된 demo 이미지로 앱을 실행해야 한다.
기존 VM·앱 컨테이너는 저장소 변경만으로 재시작되지 않는다. 컨트롤 플레인의 인증·사용자 API·메트릭 조회는 그대로 두며,
독립 IaC 실행 경로는 위 내부 API를 사용한다.
