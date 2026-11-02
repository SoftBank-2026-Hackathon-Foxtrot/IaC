# 플랫폼 입출력과 시각화 계약

UI·백엔드·실행 조정기 사이의 호출/상태/승인 계약은 [프로비저닝 인터페이스 v0.1](provisioning-interface.md)과 [OpenAPI](../contracts/provisioning.openapi.yaml)를 참고합니다. 이 문서는 Terraform 입력과 메타데이터의 의미를 설명합니다.

## 입력을 둘로 분리

**사람/플랫폼:** 계정·프로젝트, 리전/AZ, 네트워크 CIDR, 웹/관리 접근 범위, image/엔진 버전, bucket 이름, 삭제 보호, 메타데이터.

**AI 추천 가능:** `catalog/sizing-policy.json`에 등록된 `sizing` 필드만. 서버 사양·디스크, DB 사양·디스크·HA, 캐시 사양·HA. 이것은 초기 검토 후보 목록이며 실시간 추천 모델이나 가격표가 아닙니다.

```text
human baseline ─┐
                ├─ allowlist/형식/범위/CIDR 검사 → proposal.tfvars.json
AI proposal ────┘                                  ↓
                                               plan + diff
                                                   ↓
                                          사람이 검토한 saved plan
```

`render_inputs.py`는 Terraform 코드나 shell 명령을 받지 않으며 실행하지 않습니다. 알 수 없는 키, 다른 cloud, 타입 불일치, 과도한 용량, 설명 없는 제안은 거부합니다. 부분 추천은 기존 sizing에 병합하므로 다른 필드가 기본값으로 초기화되지 않습니다. 입력 baseline에는 모든 sizing 필드를 명시합니다.

새 인스턴스 타입은 AI가 임의로 사용하지 못합니다. 담당자가 카탈로그와 Terraform validation을 함께 수정하고 테스트해야 합니다. AI가 빈약한 근거로 HA를 끄거나 사양을 줄이는 제안을 해도 자동 승인하지 않습니다. 승인 화면은 변경 전후와 rationale를 표시해야 합니다.

플랫폼의 실행 경로는 검토된 Git revision의 root 모듈만 실행해야 합니다. 이 Python 도구는 입력 경계 예제이지 우회 불가능한 IAM/정책 엔진이 아닙니다. Terraform을 직접 실행할 권한이 있는 사람은 별도 검토/권한 통제를 받습니다.

## 공통 메타데이터

모든 값은 GCP label 제약에 맞춘 소문자 영문·숫자·`_`·`-`, 최대 63자입니다. owner는 이메일 대신 팀 slug를 사용합니다.

| 필드 | 의미 | 집계/시각화 용도 |
|---|---|---|
| project | 서비스/프로젝트 | 프로젝트 비용 |
| environment | poc/dev | 환경별 비용·노출 범위 |
| owner | 담당 팀 | 운영 책임·알림 라우팅 |
| cost_center | 비용 귀속 | 청구 집계 |
| workload | 앱/업무 단위 | 앱별 자원 맵 |
| migration_id | 같은 이전 작업의 공통 ID | 원본·대상 비용/진행 상태 연결 |
| deployment_id | 클라우드별 고유 배포 ID | 개별 배포의 자원 연결 |
| component | compute/database/cache/storage/network/identity | 계층별 비용·문제 분류 |
| data_class | public/internal/confidential | 데이터 분류 |
| expires_on | YYYY-MM-DD | PoC 정리 알림. 자동 삭제 아님 |
| managed_by | terraform | 자원 관리 출처 |
| template_version | v0-1 | 생성 기준 추적 |
| security_profile | public-app-private-data-v1 | 의도한 보안 구성. 검사 통과 결과 아님 |

AWS는 지원 자원에 tags 및 provider default_tags를 사용하고, snapshot/root disk에도 추적 정보를 설정합니다. GCP는 지원 자원에 labels를 설정합니다. GCP VPC/subnet/firewall 및 IAM처럼 labels가 없는 자원은 description/name 및 state 자원 주소로 연결합니다. description은 billing label이 아닙니다.

GCP network tags, labels, Resource Manager tags는 서로 다른 기능입니다. 이번 구현은 비용/분류용 labels이며 조직 정책용 tag binding은 만들지 않습니다.

## 비용·보안 상태는 별도 데이터

AWS 비용 할당 태그는 Billing에서 활성화해야 하며, GCP도 Billing export 등 수집 경로를 별도로 준비해야 합니다. 지원하지 않는 청구 항목·공유 비용까지 모든 비용이 자동 귀속되는 것은 아닙니다.

보안 상태는 태그의 `secure=true` 같은 주장으로 표현하지 않습니다. 이후 점검기가 다음 형태의 결과를 자원 ID에 연결하도록 권장합니다.

```json
{
  "deployment_id": "fox-aws-poc01",
  "resource_id": "cloud-native-resource-id",
  "rule_id": "database-no-public-endpoint",
  "status": "pass",
  "observed_at": "2026-11-02T00:00:00Z",
  "evidence_ref": "scanner-result-reference"
}
```

위 JSON은 제안 계약이며 점검기가 구현되었다는 뜻이 아닙니다. 실제 점검 시각과 증거를 필수로 남기고, IaC plan의 의도와 클라우드 실제 상태를 구분합니다.

## 출력

각 root는 `terraform output -json handoff`로 schema_version 1 객체를 제공합니다.

- 공통: cloud, deployment_id, metadata, compute/database/cache/storage/network, pending_checks.
- AWS DB: master secret **ARN 참조**. 비밀 문자열을 출력하지 않습니다.
- GCP DB: private IP, connection name, IAM DB 사용자. IAM 로그인·SQL GRANT는 앱 bootstrap에서 연결합니다.
- Redis: endpoint/port/TLS 여부와 AUTH 공급 방식. 인증 문자열은 인계 JSON에 포함하지 않습니다.
- 네트워크: cloud-native ID. 복제 경로가 자동 준비됐다는 의미가 아닙니다.

플랫폼은 구성 파일 hash, Git revision, provider lock hash, 승인자·시각, saved plan hash, 실행 ID를 별도로 기록해야 합니다. 이 저장소가 그 승인/감사 저장소까지 구현하지는 않습니다.

## 근거

- [AWS 비용 할당 태그 활성화](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html)
- [GCP labels](https://docs.cloud.google.com/resource-manager/docs/labels-overview)
- [GCP tags와 labels 차이](https://docs.cloud.google.com/resource-manager/docs/tags/tags-overview)
