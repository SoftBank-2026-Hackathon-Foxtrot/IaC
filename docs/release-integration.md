# release/1 통합과 배포 준비 상태

2026-11-07. `release/1`의 앱·플랫폼 배포, `codex/cloud-tailscale-routers`의 공유 라우터,
`codex/migration-observability`의 준비 관측을 main 기준으로 통합합니다.

## 입력과 출력 호환성

- 기존 Terraform baseline처럼 `app`을 생략하거나 null로 주면 인프라만 생성합니다. 입력 변환기도 이를 허용합니다.
- 앱을 지정할 때만 `app.image`가 필수입니다. ECR/Artifact Registry 검증은 유지합니다.
- 앱이 없는 기존 구성의 기본 PostgreSQL은 16, Redis는 TLS/AUTH입니다. 새 앱 구성의 기본은 PG17과 plain RESP입니다. 명시한 버전·암호화 설정은 유지합니다. 기존 환경에 앱을 추가할 때는 PG 버전과 Redis 설정도 명시하고 실제 plan을 확인하세요.
- GCP의 기존 `database.app_db_user`는 IAM 사용자이며 그 계정도 계속 생성합니다. `app_user`와 `app_secret_ref`는 새 앱의 비밀번호 계정입니다. `auth_mode`는 기본 앱 접속 방식입니다. 기존 `cache.auth_source`, `server_ca_certs`도 유지합니다.
- `handoff.schema_version=1`과 기존 compute/database/cache/storage/network 필드는 유지하고 `app`, `router_inputs`를 추가합니다. 앱이 없을 때 `app`은 null입니다.
- 기존 managed-environment OpenAPI는 유지합니다. 새 `/v1/environments`는 별도의 실행 API이며 기존 API를 구현했다고 표시하지 않습니다.

## 인프라 완료와 앱 기동 확인

`GET /v1/environments/{id}`의 `readiness`에 두 결과가 따로 저장됩니다.

```json
{
  "status": "APP_NOT_READY",
  "readiness": {
    "infrastructure": {"status": "READY", "observedAt": "2026-11-07T04:00:00+00:00", "jobId": "job-example"},
    "application": {"status": "NOT_READY", "observedAt": "2026-11-07T04:03:00+00:00", "httpStatus": 503,
      "scope": "APP_HTTP_READINESS", "attempts": 36}
  }
}
```

위 값은 설명용 예시입니다. 실제 apply 성공 후 `INFRA_READY`가 되고, 별도 `CHECK_APP` 작업이 VM의 사설 IP와 앱 포트의 `/readyz`를 확인합니다. 공용 LB는 아직 원본 VM을 가리킬 수 있으므로 사용하지 않습니다. HTTP 200일 때만 전체 `READY`, 응답 실패는 `APP_NOT_READY`, 검사 정보 부족은 `INFRA_READY`와 앱 `UNKNOWN`입니다. 리다이렉트는 성공으로 인정하지 않습니다.

`app.healthPath`(Terraform: `health_path`)로 앱의 준비 경로를 바꿀 수 있습니다. 이 검사는 해당 HTTP 경로의 준비 결과이며 모든 worker·업무 기능 검사나 지속 가용성 측정을 대신하지 않습니다. 화면에는 관측 시각을 함께 표시합니다.

서버 설정 `readiness`의 기본값은 `deadlineSeconds=180`, `intervalSeconds=5`, `requestTimeoutSeconds=3`입니다. API는 검사 중에도 조회할 수 있습니다. 사설 경로가 준비되거나 앱이 복구된 뒤 `POST /v1/environments/{id}/check-app`으로 Terraform 재실행 없이 확인합니다. 기존 SQLite의 `READY`는 앱 검사 근거가 없으므로 `INFRA_READY`로 이관합니다. 검사 중 재시작도 완료된 apply를 실패로 바꾸지 않습니다.

## DB와 앱의 책임

IaC는 DB 인스턴스, DB 계정과 CONNECT/스키마 접근 권한을 준비합니다. 앱의 `init_schema`를 호출하거나 테이블을 조회·생성하지 않습니다. `/seed`도 호출하지 않습니다. 이전 `seedDemoData`, `seed_demo_data`, `seed_close_in_s` 입력은 호환 목적으로 받지만 IaC에서는 사용하지 않습니다. 사용자 앱이 시작할 때 테이블과 데이터를 준비합니다. DB 마이그레이션 프로필의 writer/owner 조건은 앱과 DB 어댑터 사이의 계약입니다.

## 공유 Tailscale 라우터 연결

앱 VM은 라우터가 아닙니다. 앱 업데이트로 VM이 바뀌어도 별도 `environments/tailscale/aws`, `environments/tailscale/gcp`의 라우터는 유지됩니다. 릴리스의 `tailscale.auth_key_secret` 입력은 공유 라우터 입력으로 전달되며 앱 VM에 키 읽기 권한을 주지 않습니다.

1. 앱 환경을 생성하고 `terraform output -json router_inputs` 또는 API `handoff.router_inputs`를 가져옵니다.
2. AWS에는 검토한 Ubuntu 24.04 AMI의 `ami_id`, 양쪽 모두 상대 앱/데이터 대역과 관리 VPC를 포함한 `remote_cidrs`를 추가합니다. 인증 secret 참조가 null이면 기존 foundation secret 참조를 지정합니다. 값 자체를 넣지 않습니다.
3. GCP의 `private_services_import_custom_routes`는 기존 PSA peering 값을 확인해 명시합니다. Cloud SQL/Redis의 반환 경로가 필요합니다. Memorystore producer 측 custom route import는 별도로 확인합니다.
4. 각 공유 라우터 root에서 기존 state에 대해 plan을 검토·적용합니다. 이미 같은 라우트/peering을 다른 state가 관리한다면 중복 생성하지 말고 해당 state로 연결합니다.
5. `app_ports`는 실제 앱 준비 확인 포트, `service_ports`는 필요한 플랫폼 프록시/어댑터 포트입니다. 라우터 경유와 앱 ingress를 `remote_cidrs`에 한정합니다. DB SG에는 PostgreSQL 포트만 엽니다.
6. 관리 gateway는 원본 사설 IP를 보존하고, ECS task SG는 해당 앱 대역의 필요한 서비스 포트를 허용합니다. 확인 후 `/check-app`을 호출합니다.

라우터는 네트워크마다 하나씩 사용합니다. 서로 연결할 VPC CIDR은 겹치면 안 됩니다. 플랫폼의 `.internal` 이름은 관리 VPC 내부 DNS입니다. 외부 앱에는 도달 가능한 프록시 주소와 해당 클라우드의 DNS 구성을 제공해야 하며, 공유 라우터 생성 자체를 DNS 설정 완료로 해석하지 않습니다.

## 관측 연결

생성 요청의 `workflowId` 또는 CLI `--workflow-id`를 CP workflow와 일치시킵니다. 이미 배포한 환경은 `POST /v1/environments/{id}/workflow`로 연결할 수 있습니다. 프로세스에 OTEL endpoint와 module ingest headers를 주입하면 별도 observer가 INFRA 상태를 발행합니다. 기존 `observations.controlPlaneUrl/tokenEnv`와 preparation POST는 사용하지 않습니다.

상세 설정은 [OTEL 수집 stack과 배포 연결](migration-observability.md)을 따릅니다. `QUEUED_OTEL`은 비동기 큐 접수이며 최종 수신 확인은 CP 화면에서 합니다. 인프라/app 준비 상태와 각 원 시각, COMPUTE의 별도 작업 근거를 보존합니다. 전송 장애가 성공한 배포를 실패로 바꾸지 않습니다.

## 실행 범위

이 통합의 검증은 Python 테스트, Terraform validate와 mock 테스트입니다. 실제 클라우드 apply·DB 이전·Cloudflare 전환을 자동으로 실행하지 않습니다. Provisioner의 기존 PoC 생성/삭제 기본값은 유지합니다. `mode: plan`으로 계획까지만 만들거나 서버의 `deletionProtection`, `forceDestroyStorage`로 변경할 수 있습니다.
