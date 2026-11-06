# 실행과 검증

## 환경 최초 준비 — 플랫폼 관리자의 사전 작업

이 절차는 플랫폼에 아직 관리 설정이 없는 환경을 최초로 준비하는 경우입니다. 마이그레이션 UI/API는 원본·대상 코드, baseline, state, 인증 연결이 이미 준비되었다고 가정하며 사용자에게 아래 설정을 반복 입력받지 않습니다.

1. 대상 AWS 계정/GCP 프로젝트와 billing, 리전 가용성·quota를 확인합니다. 이 코드가 계정·프로젝트를 만들지 않습니다.
2. 예시를 복사해 실제 설정을 작성합니다. bucket 이름은 전역 고유, 배포 ID는 환경별 고유하게 지정합니다. `expires_on`도 실제 계획에 맞춰 수정합니다.
3. `render_inputs.py validate`로 baseline을 검사하고 필요하면 AI 추천을 `render`로 별도 파일에 병합합니다.
4. state backend와 자격 증명을 준비합니다. mock 검사 이후 실제 backend 사용 시 다시 `terraform init`합니다.
5. 실제 plan에서 계정·리전·사양·생성/교체/삭제 목록·비용 영향을 검토합니다. 승인한 saved plan을 실행하는 것은 플랫폼 실행기 담당입니다.

## 관리 중인 환경에서의 마이그레이션

기존 migration_id로 대상 root·baseline·backend를 조회하고, 허용된 sizing 변경값만 병합해 plan합니다. 이미 있는 대상 자원에 빈 state를 연결하지 않으며 원본 state에는 apply하지 않습니다. 사용자 확인 후 같은 saved plan을 실행하고 성공한 설정을 대상 baseline에 반영합니다. 출력과 후속 작업은 [인터페이스 v0.3](provisioning-interface.md)를 따릅니다. 현재 저장소에는 이 실행기나 baseline 저장소가 구현되어 있지 않습니다.

## 인증과 권한

AWS는 SSO/assume-role/단기 credentials, GCP는 ADC 또는 Workload Identity를 사용합니다. access key, service-account key, DB 비밀번호를 Git이나 AI 입력에 넣지 않습니다.

AWS 실행 주체에는 이 root가 관리하는 EC2/VPC/SG/EIP, RDS, ElastiCache, S3, IAM role/profile/policy 및 제한된 `iam:PassRole` 관련 권한이 필요합니다. RDS 관리 secret·서비스 연결 역할 생성도 계정 초기 상태에 따라 필요합니다. 계정 admin을 앱 role에 부여해 해결하지 않습니다.

GCP 실행 주체에는 필요한 API 활성화, compute/network/PSA, SQL/Redis/storage 생성, 전용 SA 생성·사용 및 해당 IAM binding을 변경할 권한이 필요합니다. Cloud SQL service agent 등 서비스 identity가 준비되는 과정도 확인합니다. 조직 정책에 따른 최소 custom role은 아직 검증되지 않았으며 실제 실행 계정에 맞춰 별도 확정합니다.

AWS Redis token은 비밀 저장소에서 `TF_VAR_redis_auth_token`으로 주입합니다. 16~128자 영숫자/허용 기호를 사용하며 명령어·CI 로그에 출력하지 않습니다. 테스트 fixture의 token은 모의 테스트용 공개 문자열이고 실제 계정에서 사용하지 않습니다.

## state와 plan

이 초안은 로컬 검사 편의를 위해 backend를 하드코딩하지 않습니다. 공유 환경에서 실제 실행하기 전에 암호화·접근 통제·버전 관리·locking을 제공하는 backend를 구성합니다. `examples/backends`의 파일은 선택적으로 root의 `backend.tf`로 복사해 환경별 값으로 채웁니다. state 저장소는 workload bucket과 별도로 준비합니다.

**sensitive 표시만으로 state가 암호화되지 않습니다.** AWS Redis token과 GCP provider가 반환한 Redis AUTH 값은 state에 포함될 수 있습니다. saved plan/전체 state JSON도 비밀 자료로 취급하고 일반 CI artifact로 업로드하지 않습니다. UI에는 제한된 `handoff`만 전달합니다.

두 클라우드와 각 배포마다 state key/prefix를 분리합니다. 실패 후 state 파일을 삭제해서 재실행하지 말고 실제 자원·state를 대조합니다. 동시에 같은 배포를 실행하지 않습니다.

provider 버전을 갱신하면 각 root에서 `terraform providers lock -platform=windows_amd64 -platform=linux_amd64`를 실행해 로컬 Windows와 Linux CI의 체크섬을 함께 기록합니다. CI의 `-lockfile=readonly` 검증은 유지합니다.

## 검사·계획 명령

저장소 root에서 실행합니다. AWS secret은 아래 명령 전에 외부에서 주입되어 있어야 합니다.

```bash
python tools/render_inputs.py validate --cloud aws --base environments/aws/deployment.tfvars.json
terraform -chdir=environments/aws init
terraform -chdir=environments/aws plan -input=false -var-file=deployment.tfvars.json -out=reviewed.tfplan
```

GCP도 동일하며 `--cloud gcp`, `environments/gcp`를 사용합니다. 이미 승인한 입력을 바꾸면 새로운 plan을 만들고 다시 검토합니다. AI의 rationale는 근거 후보이지 성능·비용 보장이 아닙니다.

실제 실행은 검토된 `reviewed.tfplan`을 사용합니다. CI는 mock provider로 plan을 검사합니다. 실제 EC2·GCE 배포는 별도 리허설 state에서 검증했습니다.

## 생성 후 확인

- 공인 IP에서 허용한 앱 포트만 접근되는지 확인합니다. 현재 코드는 앱/웹서버/인증서를 설치하지 않으므로 웹 응답이 곧바로 생기지 않습니다.
- AWS SSM 연결과 GCP 운영자의 OS Login 권한을 확인합니다. GCP는 SSH CIDR을 열어도 OS Login IAM 권한 없이는 로그인할 수 없습니다.
- 앱 실행 위치에서 DB TLS 연결, Redis TLS/AUTH 연결, 자기 bucket 객체 CRUD를 확인합니다. Redis CA 신뢰 설정을 생략하지 않습니다.
- 허용하지 않은 위치에서 DB/cache 접속이 실패하는지 확인합니다. GCP VPC에 다른 워크로드가 있으면 추가 격리 검토가 필요합니다.
- 앱용 SQL GRANT, RDS 앱 계정, Cloud SQL IAM connector, 확장·스키마 준비를 DB 담당과 확인합니다.
- 복제 runner 경로·계정·DB replication 설정은 아직 준비하지 않았으므로 별도 확인합니다.
- public IP, VM/DB/cache, 디스크, backup/versioned 객체, 로그, 이전 트래픽 비용을 확인합니다. 기본값을 무료 구성으로 간주하지 않습니다.

## 수정·삭제

VM 사양 변경은 재시작을 일으킬 수 있습니다. DB·cache 변경은 유지보수 창에 적용되거나 교체를 요구할 수 있습니다. 이 Terraform root는 무중단 변경을 보장하지 않습니다.

RDS는 삭제 보호를 해제한 plan/apply 이후 고유 final snapshot 이름으로 정리합니다. Cloud SQL은 Terraform/API 삭제 보호를 함께 해제하는 변경을 먼저 적용해야 합니다. Cloud SQL 인스턴스 삭제 전 별도 export/backup의 보존·복구 가능성을 검증합니다. 이 코드에 최종 export 자동화는 없습니다.

두 bucket은 `force_destroy=false`입니다. 현재 객체와 이전 버전이 남아 있으면 삭제가 차단되며 보존 정책에 따라 사람이 처리해야 합니다. GCP PSA 연결은 연결된 모든 관리형 서비스가 정리되기 전 삭제하면 실패할 수 있습니다. `expires_on`은 정리 검토 알림용입니다.

## 수행한 검증과 남은 검증

- Terraform fmt/validate: AWS/GCP root와 참조 모듈.
- mock-provider plan tests: root 연결, 공개 SSH/DB 포트/미허용 사양 거부, DB/스토리지/Redis 보안 기본값.
- Python tests: 추천 allowlist·타입·범위·설명, 기존 설정 보존, 다른 cloud·중복 JSON 키·CIDR 중복·비밀값 거부.
- EC2·GCE 모듈의 실제 plan/apply/destroy 및 데모 앱 검증은 [클라우드 리허설 기록](compute-cloud-rehearsal.md)에 있습니다.
- 남은 검증은 관리형 서비스를 포함한 전체 환경 배포, 리전별 용량·가격·quota, 관리형 서비스의 TLS·SQL 권한·복제·앱 연결, backup 복구, 비용·보안 수집입니다.

## 공식 참고

- [RDS 관리형 master secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance)
- [Cloud SQL IAM 사용자](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_user)
- [Cloud SQL connector의 443/3307 연결](https://docs.cloud.google.com/sql/docs/postgres/sql-proxy)
- [Memorystore TLS 연결과 CA](https://docs.cloud.google.com/memorystore/docs/redis/manage-in-transit-encryption)
- [PSA 예약 범위 사용](https://docs.cloud.google.com/memorystore/docs/redis/create-manage-instances)
- [Terraform S3 backend locking](https://developer.hashicorp.com/terraform/language/backend/s3)
